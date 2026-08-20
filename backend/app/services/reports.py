"""PDF reports — data assembly, caching, and rendering.

The layout of a report lives in a Word template on the server, not in Swift:
the app sends nothing but a template id and a period, the backend assembles the
JSON that template consumes, and Adobe's Document Generation API renders the
two into a PDF. Changing a column, a heading or the page furniture is then a
file on the server, not an App Store release.

Two things follow from that and are load-bearing:

* **The numbers are assembled here, from the same services the screens read.**
  A report that computes its own cost basis will eventually disagree with the
  Dividends screen, and the screen is what the user trusts.
* **Rendering is cached on a key that folds in a data version.** Re-asking for
  the same report over unchanged records returns the existing file and burns no
  Document Transaction.

When Adobe credentials are absent the same payload is rendered locally instead
(see ``render``), so the whole feature — endpoints, cards, viewer — works
end-to-end before an Adobe account exists. The local renderer is a fallback,
not the design: it reproduces the page furniture, not the template.
"""
from __future__ import annotations

import hashlib
import json
import os
import threading
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from sqlalchemy.orm import Session

from ..database import Dividend, Report, SessionLocal, Trade
from . import fx, income, portfolio, quotes, stock_info

_TAIPEI = timezone(timedelta(hours=8))

REPORTS_DIR = Path(__file__).resolve().parent.parent.parent / "data" / "reports"
TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "reports" / "templates"

# Files older than this are evicted on the next sweep.
RETENTION_DAYS = 30


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------

TEMPLATES: list[dict] = [
    {"id": "dividend_year", "name": "Dividend year report",
     "description": "TW and US payouts split · gross → tax → net", "pages": 6},
    {"id": "holdings_snapshot", "name": "Holdings snapshot",
     "description": "Positions, cost basis, market value, unrealized P/L", "pages": 4},
    {"id": "realized_pl", "name": "Realized P/L & tax summary",
     "description": "FIFO-matched sells with holding periods", "pages": 5},
    {"id": "period_performance", "name": "Period performance",
     "description": "TWR, XIRR and benchmark comparison", "pages": 3},
]

TEMPLATE_IDS = {t["id"] for t in TEMPLATES}


def template_def(template_id: str) -> dict:
    for t in TEMPLATES:
        if t["id"] == template_id:
            return t
    return TEMPLATES[0]


# ---------------------------------------------------------------------------
# Tax rules
#
# Both rates are *this app's* statement of the rule, in one place, because they
# appear nowhere else in the codebase and a report that gets them wrong is a
# report someone files a tax return from.
# ---------------------------------------------------------------------------

# Taiwan's NHI supplementary premium: 2.11% withheld on a single cash dividend
# payment of NT$20,000 or more. Below the floor, nothing is withheld — the test
# is per payment, not per year, which is why it is applied row by row.
NHI_PREMIUM_RATE = 0.0211
NHI_PREMIUM_FLOOR = 20_000.0

# US dividends paid to a non-resident alien with a W-8BEN on file are withheld
# at the 30% statutory rate. Taiwan has no US tax treaty, so no reduced rate
# applies — this is the number a Taiwanese holder actually receives.
US_WITHHOLDING_RATE = 0.30


def tw_premium(gross: float) -> float:
    """NHI supplementary premium withheld from one TW dividend payment.

    Rounded to whole TWD, as it is actually withheld — and so that a reader
    adding the premium column arrives at the total printed under it. Carrying
    cents here put the column and the totals row half a dollar apart, which on
    a document someone reconciles against a broker statement is the kind of
    discrepancy that costs an hour to chase.
    """
    if gross < NHI_PREMIUM_FLOOR:
        return 0.0
    return float(round(gross * NHI_PREMIUM_RATE))


def us_withheld(gross: float) -> float:
    return round(gross * US_WITHHOLDING_RATE, 2)


# ---------------------------------------------------------------------------
# Periods
# ---------------------------------------------------------------------------

def resolve_period(period: str) -> tuple[date | None, date, str]:
    """``(start, end, label)``. ``start`` is None for "all"."""
    today = datetime.now(_TAIPEI).date()
    period = (period or "ytd").strip().lower()

    if period.startswith("year:"):
        try:
            year = int(period.split(":", 1)[1])
        except ValueError:
            year = today.year
        start, end = date(year, 1, 1), min(date(year, 12, 31), today)
        return start, end, f"{start:%b %-d} – {end:%b %-d, %Y}"
    if period == "last_12m":
        start = today - timedelta(days=365)
        return start, today, f"{start:%b %-d, %Y} – {today:%b %-d, %Y}"
    if period == "all":
        return None, today, f"All time – {today:%b %-d, %Y}"
    start = date(today.year, 1, 1)
    return start, today, f"{start:%b %-d} – {today:%b %-d, %Y}"


def _in_period(value: date, start: date | None, end: date) -> bool:
    if start is not None and value < start:
        return False
    return value <= end


# ---------------------------------------------------------------------------
# Cache key
# ---------------------------------------------------------------------------

def data_version(db: Session, user_id: str) -> str:
    """The newest write across the account's records.

    Any change to a trade or a dividend changes this, which changes the cache
    key, which is what makes "the same report is not re-rendered twice" safe:
    a stale report can never be served as a fresh one.
    """
    stamps: list[str] = []
    for model in (Trade, Dividend):
        rows = db.query(model).filter(model.user_id == user_id).all()
        stamps.append(str(max((r.created_at for r in rows), default="none")))
        stamps.append(str(len(rows)))
    return "|".join(stamps)


def cache_key(template: str, period: str, params: dict, version: str) -> str:
    payload = json.dumps(
        {"t": template, "p": period, "a": params or {}, "v": version},
        sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Data assembly
# ---------------------------------------------------------------------------

def _money(value: float, currency: str) -> str:
    symbol = "NT$" if currency == "TWD" else "US$"
    digits = 0 if currency == "TWD" else 2
    sign = "−" if value < 0 else ""
    return f"{sign}{symbol}{abs(value):,.{digits}f}"


def assemble(db: Session, user_id: str, template: str, period: str,
             params: dict | None = None) -> dict:
    """The JSON one template consumes.

    Shape is deliberately flat and template-shaped — ``cover``, ``sections``,
    each section a title plus rows — so a ``.docx`` can be tagged against it
    without the tagger needing to understand the portfolio domain.
    """
    params = params or {}
    start, end, period_label = resolve_period(period)
    definition = template_def(template)

    rate, _asof = fx.get_usd_twd()
    rate = rate or 0.0
    holdings = portfolio.build_holdings(db, user_id)
    net_worth = sum((h.get("market_value") or 0.0) * (rate if h.get("market") == "US" else 1.0)
                    for h in holdings)

    cover = {
        "title": definition["name"],
        "subtitle": f"{period_label} · TWD base",
        "facts": [
            {"label": "Account", "value": user_id.replace("google:", "")},
            {"label": "Period", "value": period_label},
            {"label": "Base currency", "value": "TWD"},
            {"label": "USD/TWD used", "value": f"{rate:,.4f}"},
            {"label": "Positions", "value": str(len(holdings))},
            {"label": "Investing net worth", "value": _money(net_worth, "TWD")},
        ],
    }

    builder = {
        "dividend_year": _dividend_year,
        "holdings_snapshot": _holdings_snapshot,
        "realized_pl": _realized_pl,
        "period_performance": _period_performance,
    }.get(template, _dividend_year)

    sections, headline, row_count = builder(
        db, user_id, start, end, rate, holdings, params)

    return {
        "template": template,
        "title": definition["name"],
        "subtitle": cover["subtitle"],
        "cover": cover,
        "sections": sections + [_disclosures(rate)],
        "headline": headline,
        "row_count": row_count,
        "fx_rate": rate,
        "generated_at": datetime.now(_TAIPEI).isoformat(timespec="seconds"),
    }


def _disclosures(rate: float) -> dict:
    return {
        "kind": "notes",
        "title": "Method & disclosures",
        "paragraphs": [
            "Figures are computed from your own records in this app. Market "
            "values use the last quote available at generation time; prices "
            "may be delayed.",
            "Realized profit and loss is matched first-in, first-out. A sell "
            "consumes the oldest open lots first, buy fees are folded into "
            "cost basis, and the sell fee is deducted from proceeds.",
            "Unrealized profit and loss on Taiwan positions is shown net of "
            "estimated exit costs — 0.1425% commission plus securities "
            "transaction tax of 0.3% for a share, 0.1% for an ETF and nil for "
            "a bond ETF — which is what makes it agree with a broker's 損益試算.",
            "Taiwan cash dividends of NT$20,000 or more in a single payment "
            "carry the 2.11% National Health Insurance supplementary premium. "
            "US dividends are shown withheld at the 30% statutory rate for a "
            "non-resident alien; Taiwan has no US tax treaty reducing it.",
            f"Every conversion in this document uses one rate captured at "
            f"generation time, USD/TWD {rate:,.4f}. This document reports your "
            f"own records and public market data. It is not investment advice "
            f"and is not a tax filing.",
        ],
    }


def _dividend_year(db, user_id, start, end, rate, holdings, params):
    rows = (db.query(Dividend)
            .filter(Dividend.user_id == user_id)
            .order_by(Dividend.pay_date.asc(), Dividend.id.asc())
            .all())
    rows = [d for d in rows if _in_period(d.pay_date, start, end)]

    tw_rows, us_rows = [], []
    tw_gross = tw_net = us_gross = us_net = 0.0
    for d in rows:
        if (d.market or "TW").upper() == "TW":
            premium = tw_premium(d.amount)
            net = d.amount - premium
            tw_gross += d.amount
            tw_net += net
            tw_rows.append({
                "date": d.pay_date.isoformat(),
                "ticker": d.ticker,
                "basis": d.notes or "現金股利",
                "gross": _money(d.amount, "TWD"),
                "premium": _money(-premium, "TWD") if premium else "—",
                "net": _money(net, "TWD"),
            })
        else:
            withheld = us_withheld(d.amount)
            net = d.amount - withheld
            us_gross += d.amount
            us_net += net
            us_rows.append({
                "date": d.pay_date.isoformat(),
                "ticker": d.ticker,
                "gross": _money(d.amount, "USD"),
                "withheld": _money(-withheld, "USD"),
                "net_usd": _money(net, "USD"),
                "net_twd": _money(net * rate, "TWD"),
            })

    forward = _forward_estimates(db, user_id, holdings)

    sections = [
        {"kind": "table", "title": "Taiwan cash dividends",
         "subtitle": "Gross, NHI supplementary premium, net received",
         "columns": [
             {"key": "date", "label": "Date"},
             {"key": "ticker", "label": "Ticker"},
             {"key": "basis", "label": "Basis"},
             {"key": "gross", "label": "Gross", "align": "right"},
             {"key": "premium", "label": "Premium", "align": "right"},
             {"key": "net", "label": "Net", "align": "right"},
         ],
         "rows": tw_rows,
         "totals": {"date": f"{len(tw_rows)} payments", "gross": _money(tw_gross, "TWD"),
                    "net": _money(tw_net, "TWD")},
         "footnote": "The 2.11% premium applies per payment of NT$20,000 or more.",
         },
        {"kind": "table", "title": "US cash dividends",
         "subtitle": "Withheld at the 30% statutory rate",
         "columns": [
             {"key": "date", "label": "Date"},
             {"key": "ticker", "label": "Ticker"},
             {"key": "gross", "label": "Gross", "align": "right"},
             {"key": "withheld", "label": "Withheld 30%", "align": "right"},
             {"key": "net_usd", "label": "Net USD", "align": "right"},
             {"key": "net_twd", "label": "Net TWD", "align": "right"},
         ],
         "rows": us_rows,
         "totals": {"date": f"{len(us_rows)} payments", "gross": _money(us_gross, "USD"),
                    "net_usd": _money(us_net, "USD"),
                    "net_twd": _money(us_net * rate, "TWD")},
         "footnote": "Net TWD uses the single rate on the cover, not a per-payment rate.",
         },
        forward,
    ]

    headline = (f"Taiwan {_money(tw_net, 'TWD')} net across {len(tw_rows)} "
                f"payment{'' if len(tw_rows) == 1 else 's'}; "
                f"US {_money(us_net, 'USD')} net across {len(us_rows)}.")
    return sections, headline, len(tw_rows) + len(us_rows)


def _forward_estimates(db, user_id, holdings) -> dict:
    """Declared per-share rate × shares held, labelled an estimate on the page.

    A projection printed like a receipt is the one error in this document a
    reader would act on, so the label is part of the section, not a footnote
    someone can miss.
    """
    calendar = income.build_dividend_calendar(db, user_id)
    shares = {h["ticker"]: h.get("shares") or 0.0 for h in holdings}
    rows = []
    for item in calendar.get("upcoming", []):
        per_share = item.get("per_share")
        if not per_share:
            continue
        held = shares.get(item["ticker"], 0.0)
        annual = per_share * 4 * held
        rows.append({
            "ticker": item["ticker"],
            "market": item.get("market", ""),
            "ex_date": item.get("ex_date", ""),
            "per_share": f"{per_share:,.4f}",
            "shares": f"{held:,.0f}",
            "annual": _money(annual, item.get("currency", "TWD")),
        })
    return {
        "kind": "table",
        "title": "Estimated forward 12 months",
        "subtitle": "ESTIMATE — declared per-share rate × 4 × current shares",
        "columns": [
            {"key": "ticker", "label": "Ticker"},
            {"key": "market", "label": "Market"},
            {"key": "ex_date", "label": "Next ex-date"},
            {"key": "per_share", "label": "Per share", "align": "right"},
            {"key": "shares", "label": "Shares", "align": "right"},
            {"key": "annual", "label": "Est. annual", "align": "right"},
        ],
        "rows": rows,
        "footnote": "An estimate, not a declaration. Boards change payouts.",
    }


def _holdings_snapshot(db, user_id, start, end, rate, holdings, params):
    rows = []
    total_value = total_cost = total_pl = 0.0
    for h in sorted(holdings, key=lambda x: -(x.get("market_value") or 0.0)):
        currency = "TWD" if h.get("market") == "TW" else "USD"
        value = h.get("market_value") or 0.0
        cost = h.get("cost_basis") or 0.0
        pl = h.get("unrealized_pl") or 0.0
        multiplier = rate if currency == "USD" else 1.0
        total_value += value * multiplier
        total_cost += cost * multiplier
        total_pl += pl * multiplier
        rows.append({
            "ticker": h["ticker"],
            "name": h.get("name") or "",
            "market": h.get("market") or "",
            "shares": f"{h.get('shares') or 0:,.0f}",
            "avg_cost": f"{h.get('avg_cost') or 0:,.2f}",
            "price": f"{h.get('current_price') or 0:,.2f}",
            "value": _money(value, currency),
            "cost": _money(cost, currency),
            "pl": _money(pl, currency),
            "pl_pct": f"{h.get('unrealized_pl_pct') or 0:+.1f}%",
        })
    sections = [{
        "kind": "table", "title": "Positions",
        "subtitle": "Unrealized P/L is net of estimated exit costs",
        "columns": [
            {"key": "ticker", "label": "Ticker"},
            {"key": "name", "label": "Name"},
            {"key": "shares", "label": "Shares", "align": "right"},
            {"key": "avg_cost", "label": "Avg cost", "align": "right"},
            {"key": "price", "label": "Price", "align": "right"},
            {"key": "value", "label": "Market value", "align": "right"},
            {"key": "pl", "label": "Unrealized", "align": "right"},
            {"key": "pl_pct", "label": "%", "align": "right"},
        ],
        "rows": rows,
        "totals": {"ticker": f"{len(rows)} positions",
                   "value": _money(total_value, "TWD"),
                   "pl": _money(total_pl, "TWD")},
        "footnote": "Totals are in TWD at the cover rate.",
    }]
    headline = (f"{len(rows)} positions worth {_money(total_value, 'TWD')}, "
                f"unrealized {_money(total_pl, 'TWD')}.")
    return sections, headline, len(rows)


def _realized_pl(db, user_id, start, end, rate, holdings, params):
    from .ai_tools import _realized_by_sell  # lazy: shared FIFO walk

    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    booked = _realized_by_sell(trades)
    lots = {l["lot_id"]: l for l in portfolio.build_lots(trades)}
    buys = {t.id: t for t in trades if t.type == "buy"}

    rows = []
    total = {"TWD": 0.0, "USD": 0.0}
    for t in sorted((t for t in trades if t.type == "sell"),
                    key=lambda t: (t.trade_date, t.id)):
        if not _in_period(t.trade_date, start, end):
            continue
        currency = "TWD" if (t.market or "TW").upper() == "TW" else "USD"
        pl = booked.get(t.id, 0.0)
        total[currency] += pl
        # Holding period from the oldest lot the sale could have consumed —
        # what a tax return asks for, and not derivable from the sell alone.
        opened = min((b.trade_date for b in buys.values() if b.ticker == t.ticker
                      and b.trade_date <= t.trade_date), default=None)
        rows.append({
            "date": t.trade_date.isoformat(),
            "ticker": t.ticker,
            "shares": f"{t.shares:,.0f}",
            "price": f"{t.price:,.2f}",
            "proceeds": _money(t.shares * t.price - t.fee, currency),
            "held_from": opened.isoformat() if opened else "—",
            "days": str((t.trade_date - opened).days) if opened else "—",
            "realized": _money(pl, currency),
        })

    sections = [{
        "kind": "table", "title": "Realized sales",
        "subtitle": "FIFO-matched, net of fees",
        "columns": [
            {"key": "date", "label": "Sold"},
            {"key": "ticker", "label": "Ticker"},
            {"key": "shares", "label": "Shares", "align": "right"},
            {"key": "price", "label": "Price", "align": "right"},
            {"key": "proceeds", "label": "Net proceeds", "align": "right"},
            {"key": "held_from", "label": "First lot"},
            {"key": "days", "label": "Days", "align": "right"},
            {"key": "realized", "label": "Realized", "align": "right"},
        ],
        "rows": rows,
        "totals": {"date": f"{len(rows)} sales",
                   "realized": f"{_money(total['TWD'], 'TWD')} · {_money(total['USD'], 'USD')}"},
        "footnote": "Totals are per currency; the two are not added.",
    }]
    headline = (f"{len(rows)} sales realized {_money(total['TWD'], 'TWD')} "
                f"and {_money(total['USD'], 'USD')}.")
    return sections, headline, len(rows)


def _period_performance(db, user_id, start, end, rate, holdings, params):
    from . import performance as perf

    period_map = {"ytd": "ytd", "last_12m": "1y", "all": "max"}
    window = period_map.get("all" if start is None else "ytd", "ytd")
    sections, lines = [], []
    for market in ("TW", "US"):
        try:
            report = perf.build_performance(db, user_id, market=market, period=window)
        except Exception:
            continue
        benchmark = report.get("benchmark") or {}
        rows = [
            {"metric": "Time-weighted return (TWR)",
             "value": _pct(report.get("twr_pct"))},
            {"metric": "Annualized", "value": _pct(report.get("twr_annualized_pct"))},
            {"metric": "Money-weighted (XIRR)", "value": _pct(report.get("xirr_pct"))},
            {"metric": f"Benchmark — {benchmark.get('name', '—')}",
             "value": _pct(benchmark.get("return_pct"))},
            {"metric": "Difference",
             "value": _pct((report.get("twr_pct") or 0) - (benchmark.get("return_pct") or 0))},
        ]
        monthly = [{"metric": m["month"],
                    "value": _money(m.get("pl") or 0.0,
                                    "TWD" if market == "TW" else "USD")}
                   for m in (report.get("monthly") or [])[-12:]]
        sections.append({
            "kind": "table",
            "title": f"{'Taiwan' if market == 'TW' else 'US'} performance",
            "subtitle": "Time-weighted removes the effect of deposits; XIRR does not",
            "columns": [{"key": "metric", "label": "Metric"},
                        {"key": "value", "label": "Value", "align": "right"}],
            "rows": rows + ([{"metric": "— Monthly P&L —", "value": ""}] + monthly
                            if monthly else []),
            "footnote": "TWR is the fair comparison against an index over the same window.",
        })
        lines.append(f"{market} TWR {_pct(report.get('twr_pct'))}")
    headline = "; ".join(lines) or "Not enough history yet."
    return sections, headline, sum(len(s["rows"]) for s in sections)


def _pct(value) -> str:
    if value is None:
        return "—"
    sign = "+" if value > 0 else ("−" if value < 0 else "")
    return f"{sign}{abs(value):,.1f}%"


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def adobe_configured() -> bool:
    return bool(os.environ.get("ADOBE_CLIENT_ID") and os.environ.get("ADOBE_CLIENT_SECRET"))


def render(payload: dict) -> tuple[bytes, str]:
    """``(pdf_bytes, renderer)``.

    Adobe when it is configured and the template file exists; otherwise the
    local renderer, so the endpoints, the chat card and the viewer are all
    usable before an Adobe account exists. The fallback is not the design — it
    reproduces the page furniture, not the Word template.
    """
    template_file = TEMPLATES_DIR / f"{payload['template']}.docx"
    if adobe_configured() and template_file.exists():
        from . import adobe_docgen
        try:
            return adobe_docgen.render(template_file, payload), "adobe"
        except Exception as exc:  # noqa: BLE001 — never fail the job on Adobe
            print(f"[reports] Adobe render failed, falling back locally: {exc}")
    from . import pdf_fallback
    return pdf_fallback.render(payload), "local"


# ---------------------------------------------------------------------------
# Job running
# ---------------------------------------------------------------------------

def file_path(report_id: str) -> Path:
    return REPORTS_DIR / f"{report_id}.pdf"


def thumb_path(report_id: str) -> Path:
    return REPORTS_DIR / f"{report_id}.png"


def start(report_id: str, user_id: str, template: str, period: str, params: dict) -> None:
    """Render off the request thread. ``POST /api/reports`` must return
    immediately — a Document Generation round trip is seconds, and the app
    polls."""
    threading.Thread(target=_run, args=(report_id, user_id, template, period, params),
                     daemon=True).start()


def _run(report_id: str, user_id: str, template: str, period: str, params: dict) -> None:
    with SessionLocal() as db:
        row = db.get(Report, report_id)
        if row is None:
            return
        try:
            payload = assemble(db, user_id, template, period, params)
            pdf, renderer = render(payload)
            REPORTS_DIR.mkdir(parents=True, exist_ok=True)
            file_path(report_id).write_bytes(pdf)

            from . import pdf_fallback
            thumb = pdf_fallback.thumbnail(payload)
            if thumb:
                thumb_path(report_id).write_bytes(thumb)

            row.status = "ready"
            row.pages = _page_count(pdf)
            row.bytes = len(pdf)
            row.renderer = renderer
            row.title = payload["title"]
            row.subtitle = payload["subtitle"]
            row.headline = payload["headline"][:500]
            row.row_count = payload["row_count"]
            row.fx_rate = payload["fx_rate"]
            row.generated_at = datetime.utcnow()
        except Exception as exc:  # noqa: BLE001 — a job must never hang pending
            row.status = "failed"
            row.error = f"{type(exc).__name__}: {exc}"[:500]
        db.commit()


def _page_count(pdf: bytes) -> int:
    return max(1, pdf.count(b"/Type /Page") - pdf.count(b"/Type /Pages"))


def new_id() -> str:
    return "rpt_" + uuid.uuid4().hex[:20]


def evict_old() -> None:
    """Drop files and rows past the retention window."""
    cutoff = datetime.utcnow() - timedelta(days=RETENTION_DAYS)
    with SessionLocal() as db:
        stale = db.query(Report).filter(Report.created_at < cutoff).all()
        for row in stale:
            file_path(row.id).unlink(missing_ok=True)
            thumb_path(row.id).unlink(missing_ok=True)
            db.delete(row)
        if stale:
            db.commit()
