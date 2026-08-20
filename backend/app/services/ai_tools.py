"""Tool-use layer for the AI assistant (modern function calling).

Instead of only reading a static context dump, the model can call typed tools
mid-conversation: portfolio reads, live quotes, price history, performance,
web search — and two write actions (add_trade / add_dividend) that never touch
the DB directly. Write tools emit an "action" proposal the app renders as an
in-chat confirm card; the records are saved through the normal REST endpoints
only after the user taps Add.

One neutral ``TOOLS`` spec drives all providers; small adapters translate it
to each API's schema. ``run_tool_loop`` is a generator yielding
``("chunk"|"status"|"action", payload)`` events so the SSE endpoint can
stream text, progress labels, and confirm cards with one protocol.
"""
from __future__ import annotations

import base64
import json
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone

from ..database import Dividend, Report, SessionLocal, Trade
from . import ai_providers, fx, income, markets, performance, portfolio, quotes, stock_info

_TAIPEI = timezone(timedelta(hours=8))

_MARKET = {"type": "string", "enum": ["TW", "US"]}
_PERIOD = {"type": "string",
           "enum": ["5d", "1mo", "3mo", "6mo", "ytd", "1y", "2y", "5y", "max"]}

# name, description, parameters (JSON schema), label (status text shown in-app
# while the tool runs).
# name, description, parameters (JSON schema), label (status text shown in-app
# while the tool runs).
#
# Schemas stay to the intersection all three providers accept: no ``$ref``/
# ``$defs``, no ``additionalProperties``, no ``exclusiveMinimum``. Gemini's
# FunctionDeclaration rejects them outright, and a tool that fails to register
# on one provider is a tool that silently does not exist for those users.
TOOLS: list[dict] = [
    {
        "name": "get_portfolio_summary",
        "description": (
            "Per-currency portfolio totals: market value, cost, unrealized and "
            "realized P/L, dividends collected, today's move, holdings count. "
            "Includes the USD/TWD rate used, so combined figures don't need a "
            "separate get_fx_rate call."
        ),
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET},
        },
        "label": "Checking portfolio totals…",
    },
    {
        "name": "get_holdings",
        "description": (
            "Current open positions with live prices and P/L. Optionally filter "
            "to one market (TW or US)."
        ),
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET},
        },
        "label": "Reading holdings…",
    },
    {
        "name": "get_trades",
        "description": (
            "Trade history (buys/sells), newest first, with FIFO open/closed "
            "status, the row id, and realized P/L on closed sells. Filter by "
            "ticker, market, year and/or side. Use the id to update or delete "
            "a specific trade."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "market": _MARKET,
                "year": {"type": "integer"},
                "type": {"type": "string", "enum": ["buy", "sell"]},
                "limit": {"type": "integer", "description": "Max rows (default 20, max 100)"},
            },
        },
        "label": "Reading trade history…",
    },
    {
        "name": "get_dividends",
        "description": (
            "Dividend payments received, newest first, with the row id. Filter "
            "by ticker, market and/or year. Use the id to update or delete a "
            "specific dividend."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "market": _MARKET,
                "year": {"type": "integer"},
                "limit": {"type": "integer", "description": "Max rows (default 20, max 100)"},
            },
        },
        "label": "Reading dividends…",
    },
    {
        "name": "get_quote",
        "description": (
            "Live quotes for ANY tickers (held or not): price, previous close, "
            "day range, volume. Pass up to 10 in one call rather than calling "
            "repeatedly. TW tickers are numeric codes like 2330; US are letter "
            "symbols like AAPL."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "tickers": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "1-10 tickers",
                },
                "ticker": {"type": "string", "description": "Alias for a single ticker"},
            },
        },
        "label": "Fetching live quotes…",
    },
    {
        "name": "get_price_history",
        "description": (
            "Closing prices over a period, for up to 3 tickers at once (for "
            "trends and relative-performance comparisons). Use a weekly or "
            "monthly interval for long periods so the series survives intact."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "tickers": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "1-3 tickers",
                },
                "ticker": {"type": "string", "description": "Alias for a single ticker"},
                "period": _PERIOD,
                "interval": {"type": "string", "enum": ["1d", "1wk", "1mo"]},
            },
        },
        "label": "Fetching price history…",
    },
    {
        "name": "get_performance",
        "description": (
            "Performance metrics for one market's portfolio over a period: "
            "time-weighted return (TWR), money-weighted return (XIRR), "
            "benchmark comparison, monthly P&L."
        ),
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET, "period": _PERIOD},
            "required": ["market"],
        },
        "label": "Computing performance…",
    },
    {
        "name": "get_dividend_calendar",
        "description": (
            "Projected annual dividend income, 12-month forward payment "
            "calendar, and known upcoming ex-dividend dates (除權息). Every "
            "projected figure is an estimate of per-share payout × shares held "
            "and is flagged as such — never present one as a booked amount."
        ),
        "parameters": {"type": "object", "properties": {}},
        "label": "Building dividend calendar…",
    },
    {
        "name": "get_value_history",
        "description": "Daily total market value of one market's holdings (net-worth curve).",
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET, "period": _PERIOD},
            "required": ["market"],
        },
        "label": "Charting net worth…",
    },
    {
        "name": "get_stock_info",
        "description": (
            "Fundamentals for any ticker from this app's own data: sector, "
            "market cap, P/E, forward P/E, EPS, yield, beta, P/B, average "
            "volume, 52-week range; optionally 12 months of Taiwan monthly "
            "revenue (月營收) with YoY, and 8 quarters of revenue, EPS and "
            "gross/operating margin. Prefer this over search_web for anything "
            "about a company's numbers."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "include": {
                    "type": "array",
                    "items": {"type": "string", "enum": ["profile", "revenue", "financials"]},
                    "description": "Defaults to profile only",
                },
            },
            "required": ["ticker"],
        },
        "label": "Reading company fundamentals…",
    },
    {
        "name": "get_lots",
        "description": (
            "FIFO buy lots: for each, the originating trade id, buy date, "
            "shares bought, shares still unsold, unit cost (buy fee included) "
            "and days held. This is the arithmetic under a position's open/"
            "closed status — use it instead of reconstructing FIFO from raw "
            "trades, which loses partial fills."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "market": _MARKET,
                "open_only": {"type": "boolean", "description": "Default true"},
            },
        },
        "label": "Reading cost lots…",
    },
    {
        "name": "simulate_sale",
        "description": (
            "What selling would actually net: the lots FIFO would consume, "
            "gross proceeds, commission, transaction tax, net proceeds, "
            "realized P/L and the position left over. Uses the app's own "
            "損益試算 arithmetic — do not compute fees or tax yourself."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "shares": {"type": "number"},
                "price": {"type": "number", "description": "Defaults to the live price"},
            },
            "required": ["ticker", "shares"],
        },
        "label": "Simulating the sale…",
    },
    {
        "name": "get_allocation",
        "description": (
            "Position weights — each holding as a share of its market and of "
            "total net worth, largest first, with a tail aggregate. For "
            "concentration questions. Totals come from get_portfolio_summary."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "market": _MARKET,
                "group_by": {"type": "string", "enum": ["ticker", "sector"]},
                "top_n": {"type": "integer", "description": "Default 10"},
            },
        },
        "label": "Computing allocation…",
    },
    {
        "name": "get_followed_indices",
        "description": (
            "The market indices THIS user follows, with live level and change. "
            "Use this to answer \"am I beating the market\" — it is the user's "
            "own benchmark list, which get_performance cannot tell you."
        ),
        "parameters": {"type": "object", "properties": {}},
        "label": "Reading followed indices…",
    },
    {
        "name": "get_fx_rate",
        "description": "Current USD/TWD exchange rate.",
        "parameters": {"type": "object", "properties": {}},
        "label": "Checking FX rate…",
    },
    {
        "name": "get_market_status",
        "description": (
            "Whether the TW and US stock markets are open right now, with local "
            "times and the next open/close as ISO timestamps (holidays "
            "accounted for) — don't guess when trading resumes."
        ),
        "parameters": {"type": "object", "properties": {}},
        "label": "Checking market hours…",
    },
    {
        "name": "search_web",
        "description": (
            "Web search (DuckDuckGo) for fresh information: news, earnings, "
            "dividend announcements, analyst views, macro events. For a "
            "company's own numbers use get_stock_info instead."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "queries": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "1-3 concise search queries",
                },
            },
            "required": ["queries"],
        },
        "label": "Searching the web…",
    },
    {
        "name": "propose_records",
        "description": (
            "Propose any number of trades and/or dividends in ONE call — "
            "creates, corrections and deletions together. This does NOT save: "
            "the app shows one confirmation card and writes only what the user "
            "keeps. Prefer this over add_trade/add_dividend, especially when "
            "reading a statement with several rows."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "trades": {
                    "type": "array",
                    "description": "Up to 50 trade rows",
                    "items": {
                        "type": "object",
                        "properties": {
                            "op": {"type": "string", "enum": ["create", "update", "delete"]},
                            "id": {"type": "integer", "description": "Required for update/delete"},
                            "type": {"type": "string", "enum": ["buy", "sell"]},
                            "ticker": {"type": "string"},
                            "shares": {"type": "number"},
                            "price": {"type": "number"},
                            "date": {"type": "string", "description": "YYYY-MM-DD"},
                            "fee": {"type": "number"},
                            "market": _MARKET,
                            "notes": {"type": "string"},
                        },
                    },
                },
                "dividends": {
                    "type": "array",
                    "description": "Up to 50 dividend rows",
                    "items": {
                        "type": "object",
                        "properties": {
                            "op": {"type": "string", "enum": ["create", "update", "delete"]},
                            "id": {"type": "integer", "description": "Required for update/delete"},
                            "ticker": {"type": "string"},
                            "amount": {"type": "number"},
                            "date": {"type": "string", "description": "YYYY-MM-DD"},
                            "market": _MARKET,
                            "notes": {"type": "string"},
                        },
                    },
                },
                "summary": {
                    "type": "string",
                    "description": "One line for the card header, e.g. '3 buys and 1 sell, Aug 2026'",
                },
            },
        },
        "label": "Preparing records for confirmation…",
    },
    {
        "name": "update_trade",
        "description": (
            "Propose a correction to an existing trade. Pass the id and ONLY "
            "the fields that change. This does NOT save: the app shows a "
            "before → after card and writes only if the user confirms. Use this "
            "to fix a wrong price or date — never add a second trade."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "integer"},
                "type": {"type": "string", "enum": ["buy", "sell"]},
                "ticker": {"type": "string"},
                "shares": {"type": "number"},
                "price": {"type": "number"},
                "date": {"type": "string", "description": "YYYY-MM-DD"},
                "fee": {"type": "number"},
                "market": _MARKET,
                "notes": {"type": "string"},
            },
            "required": ["id"],
        },
        "label": "Preparing the correction…",
    },
    {
        "name": "update_dividend",
        "description": (
            "Propose a correction to an existing dividend. Pass the id and ONLY "
            "the fields that change. Proposal only — the user confirms."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "id": {"type": "integer"},
                "ticker": {"type": "string"},
                "amount": {"type": "number"},
                "date": {"type": "string", "description": "YYYY-MM-DD"},
                "market": _MARKET,
                "notes": {"type": "string"},
            },
            "required": ["id"],
        },
        "label": "Preparing the correction…",
    },
    {
        "name": "delete_trade",
        "description": (
            "Propose deleting a trade by id. Proposal only — the app shows the "
            "full record plus any knock-on effect on FIFO status, and deletes "
            "only if the user confirms."
        ),
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "integer"}},
            "required": ["id"],
        },
        "label": "Preparing the deletion…",
    },
    {
        "name": "delete_dividend",
        "description": (
            "Propose deleting a dividend by id. Proposal only — the user "
            "confirms."
        ),
        "parameters": {
            "type": "object",
            "properties": {"id": {"type": "integer"}},
            "required": ["id"],
        },
        "label": "Preparing the deletion…",
    },
    {
        "name": "generate_report",
        "description": (
            "Render a multi-page PDF report from the user's own records when "
            "the answer is too large or too tabular for chat — a full year of "
            "dividends, a tax summary, a full holdings listing — or when the "
            "user asks for a report, a PDF or an export. Do NOT use it for an "
            "answer that fits in a sentence or a small table; answer those in "
            "chat. The app shows a card with an Open button; do not restate "
            "the table, and use the `headline` field for the one sentence you "
            "write beside it."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "template": {
                    "type": "string",
                    "enum": ["dividend_year", "holdings_snapshot",
                             "realized_pl", "period_performance"],
                },
                "period": {"type": "string", "enum": ["ytd", "last_12m", "all"]},
                "year": {"type": "integer",
                         "description": "Calendar year; overrides period"},
                "ticker": {"type": "string",
                           "description": "Only for single-stock templates"},
            },
            "required": ["template"],
        },
        "label": "Rendering the report…",
    },
    {
        "name": "add_trade",
        "description": (
            "Propose recording ONE buy/sell trade. Prefer propose_records, "
            "which handles several rows in one call. This does NOT save "
            "directly: the app shows a confirmation card and saves only after "
            "the user taps Add."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": ["buy", "sell"]},
                "ticker": {"type": "string"},
                "shares": {"type": "number"},
                "price": {"type": "number"},
                "date": {"type": "string", "description": "YYYY-MM-DD; default today"},
                "fee": {"type": "number"},
                "market": _MARKET,
                "notes": {"type": "string"},
            },
            "required": ["type", "ticker", "shares", "price"],
        },
        "label": "Preparing trade for confirmation…",
    },
    {
        "name": "add_dividend",
        "description": (
            "Propose recording ONE received dividend. Prefer propose_records. "
            "This does NOT save directly: the app shows a confirmation card and "
            "saves only after the user taps Add."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "amount": {"type": "number"},
                "date": {"type": "string", "description": "YYYY-MM-DD; default today"},
                "market": _MARKET,
                "notes": {"type": "string"},
            },
            "required": ["ticker", "amount"],
        },
        "label": "Preparing dividend for confirmation…",
    },
]

_LABELS = {t["name"]: t["label"] for t in TOOLS}


def status_label(name: str) -> str:
    return _LABELS.get(name, "Working…")


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

# Rounded floats keep results compact; long series are downsampled so a "max"
# history can't blow the model's context.
_MAX_POINTS = 90


def _downsample(rows: list[dict], keys: tuple[str, ...]) -> list[dict]:
    slim = [{k: r.get(k) for k in keys} for r in rows]
    if len(slim) <= _MAX_POINTS:
        return slim
    step = len(slim) / _MAX_POINTS
    picked = [slim[int(i * step)] for i in range(_MAX_POINTS)]
    if picked[-1] is not slim[-1]:
        picked.append(slim[-1])  # always keep the latest point
    return picked


def _round(v, nd=2):
    return round(v, nd) if isinstance(v, float) else v


def execute(name: str, args: dict, user_id: str) -> tuple[dict, dict | None]:
    """Run one tool. Returns ``(result_for_model, action_or_None)`` where the
    action is a ParsedRecords-shaped proposal for the app's confirm card.
    Never raises — errors come back as ``{"error": ...}`` so the model can
    recover in-conversation."""
    try:
        return _execute(name, args or {}, user_id)
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"}, None


# The one sentence every write tool tells the model. Write tools never touch
# the database — they hand the app a proposal and the app writes only what the
# user confirms — and the model has to say so, or the user is left wondering
# whether something already happened.
_PROPOSED = {
    "status": "proposed",
    "note": ("A confirmation card is now shown to the user in the app. Nothing "
             "is saved until they confirm it — tell them to review the card."),
}


def _load_owned(db, model, user_id: str, record_id):
    """Fetch one of the caller's own rows, or ``None``.

    Scoped by user on purpose: an id from another account must read as "not
    found" rather than leak that it exists.
    """
    try:
        rid = int(record_id)
    except (TypeError, ValueError):
        return None
    row = db.get(model, rid)
    if row is None or row.user_id != user_id:
        return None
    return row


def _trade_fields(t: Trade) -> dict:
    return {"type": t.type, "ticker": t.ticker, "shares": t.shares,
            "price": t.price, "date": t.trade_date.isoformat(), "fee": t.fee,
            "market": t.market, "notes": t.notes}


def _dividend_fields(d: Dividend) -> dict:
    return {"ticker": d.ticker, "amount": d.amount,
            "date": d.pay_date.isoformat(), "market": d.market, "notes": d.notes}


def _changed(stored: dict, proposed: dict) -> tuple[dict, dict]:
    """Split a proposal into the fields that actually move. A card that
    re-lists unchanged values makes the reader hunt for the edit."""
    before, after = {}, {}
    for key, value in proposed.items():
        if value is None:
            continue
        old = stored.get(key)
        if isinstance(value, float) and isinstance(old, (int, float)):
            if abs(float(old) - value) < 1e-9:
                continue
        elif old == value:
            continue
        before[key] = old
        after[key] = value
    return before, after


def _delete_consequences(db, trade: Trade) -> list[str]:
    """What else moves if this trade goes.

    Computed by re-running the FIFO pass without the row and diffing — not
    authored by the model, which has no way to know and every incentive to
    sound confident. Three things are checked, because a status diff alone
    misses the worst case: deleting a buy that a later sell consumed leaves
    that sell with no cost basis, and its status never changes (a sell is
    always "closed"), while its realized P/L moves by the whole lot.

    Empty when nothing else changes.
    """
    from ..routers.trades import _compute_statuses  # lazy: avoid import cycle

    rows = (db.query(Trade)
            .filter(Trade.user_id == trade.user_id, Trade.ticker == trade.ticker)
            .all())
    kept = [r for r in rows if r.id != trade.id]
    out: list[str] = []

    before_status = _compute_statuses(rows)
    after_status = _compute_statuses(kept)
    for row in kept:
        was, now = before_status.get(row.id), after_status.get(row.id)
        if was != now:
            out.append(
                f"The {row.ticker} {row.type} of {row.trade_date.isoformat()} "
                f"changes from {was} to {now} (FIFO)."
            )

    before_pl = _realized_by_sell(rows)
    after_pl = _realized_by_sell(kept)
    for row in kept:
        if row.type != "sell":
            continue
        was, now = before_pl.get(row.id), after_pl.get(row.id)
        if was is None or now is None or abs(was - now) < 0.5:
            continue
        out.append(
            f"Realized P/L on the {row.ticker} sell of "
            f"{row.trade_date.isoformat()} changes from {was:,.0f} to {now:,.0f}."
        )

    # Deleting a buy can leave more shares sold than ever bought — the ledger
    # still computes, but the position is then fiction.
    states = portfolio.compute_states(kept)
    state = states.get(trade.ticker)
    sold = sum(r.shares for r in kept if r.type == "sell")
    bought = sum(r.shares for r in kept if r.type == "buy")
    if sold > bought + 1e-9:
        out.append(
            f"This would leave {sold - bought:,.0f} more {trade.ticker} shares "
            f"sold than bought — the remaining sells would have no cost basis."
        )
    elif state is not None and trade.type == "buy":
        out.append(
            f"{trade.ticker} holdings drop to {state.shares:,.0f} shares."
        )
    return out


def _next_session(code: str) -> tuple[str | None, str | None]:
    """Next open and next close for a market, as ISO timestamps in its own
    timezone. "Closed" on its own makes the model guess when trading resumes,
    and it guesses wrong across a holiday — so the dates are computed from the
    same config the app's own open/closed badge reads."""
    from zoneinfo import ZoneInfo

    cfg = markets._load()["markets"].get((code or "").upper())
    if not cfg:
        return None, None
    holidays = markets.holidays_for(code)
    try:
        tz = ZoneInfo(cfg["timezone"])
    except Exception:
        return None, None

    now = datetime.now(tz)
    open_at = close_at = None
    for offset in range(0, 30):          # a month covers any holiday run
        day = (now + timedelta(days=offset)).date()
        if day.weekday() >= 5 or day.isoformat() in holidays:
            continue
        base = datetime(day.year, day.month, day.day, tzinfo=tz)
        session_open = base + timedelta(minutes=cfg["open_minute"])
        session_close = base + timedelta(minutes=cfg["close_minute"])
        if open_at is None and session_open > now:
            open_at = session_open
        if close_at is None and session_close > now:
            close_at = session_close
        if open_at and close_at:
            break
    return (open_at.isoformat() if open_at else None,
            close_at.isoformat() if close_at else None)


def _tickers_arg(args: dict, cap: int) -> list[str]:
    """`tickers: [...]` with a single `ticker` kept as an alias — batching is
    the point of these tools, but a model mid-conversation will still send the
    old shape."""
    raw = args.get("tickers")
    if isinstance(raw, str):
        raw = [raw]
    if not raw:
        raw = [args.get("ticker")] if args.get("ticker") else []
    out, seen = [], set()
    for item in raw:
        t = str(item or "").strip()
        if t and t.upper() not in seen:
            seen.add(t.upper())
            out.append(t)
    return out[:cap]


def _execute(name: str, args: dict, user_id: str) -> tuple[dict, dict | None]:
    today = datetime.now(_TAIPEI).date().isoformat()

    if name == "get_portfolio_summary":
        market = (args.get("market") or "").upper()
        with SessionLocal() as db:
            holdings = portfolio.build_holdings(db, user_id)
            summaries = portfolio.summarize(holdings, db, user_id)
        if market:
            want = markets.currency_for(market)
            summaries = [s for s in summaries if s.get("currency") == want]
        rate, asof = fx.get_usd_twd()
        return {"summaries": summaries, "usd_twd": rate, "fx_asof": asof}, None

    if name == "get_holdings":
        with SessionLocal() as db:
            rows = portfolio.build_holdings(db, user_id)
        market = (args.get("market") or "").upper()
        if market:
            rows = [h for h in rows if h["market"] == market]
        keys = ("ticker", "name", "market", "shares", "avg_cost", "current_price",
                "market_value", "cost_basis", "unrealized_pl", "unrealized_pl_pct",
                "today_change", "today_change_pct")
        return {"holdings": [{k: _round(h.get(k)) for k in keys} for h in rows]}, None

    if name == "get_trades":
        from ..routers.trades import _compute_statuses  # lazy: avoid import cycle

        limit = max(1, min(int(args.get("limit") or 20), 100))
        with SessionLocal() as db:
            q = db.query(Trade).filter(Trade.user_id == user_id)
            if args.get("ticker"):
                q = q.filter(Trade.ticker == str(args["ticker"]).strip().upper())
            if args.get("market"):
                q = q.filter(Trade.market == str(args["market"]).upper())
            if args.get("type"):
                q = q.filter(Trade.type == str(args["type"]).lower())
            rows = q.order_by(Trade.trade_date.desc(), Trade.id.desc()).all()
            all_rows = db.query(Trade).filter(Trade.user_id == user_id).all()
            statuses = _compute_statuses(all_rows)
            realized = _realized_by_sell(all_rows)
        if args.get("year"):
            year = int(args["year"])
            rows = [t for t in rows if t.trade_date.year == year]
        out = []
        for t in rows[:limit]:
            row = {"id": t.id, **_trade_fields(t), "status": statuses.get(t.id, "open")}
            if t.type == "sell":
                row["realized_pl"] = _round(realized.get(t.id))
            out.append(row)
        return {"trades": out}, None

    if name == "get_dividends":
        limit = max(1, min(int(args.get("limit") or 20), 100))
        with SessionLocal() as db:
            q = db.query(Dividend).filter(Dividend.user_id == user_id)
            if args.get("ticker"):
                q = q.filter(Dividend.ticker == str(args["ticker"]).strip().upper())
            if args.get("market"):
                q = q.filter(Dividend.market == str(args["market"]).upper())
            rows = q.order_by(Dividend.pay_date.desc(), Dividend.id.desc()).all()
        if args.get("year"):
            rows = [d for d in rows if d.pay_date.year == int(args["year"])]
        return {"dividends": [
            {"id": d.id, **_dividend_fields(d)} for d in rows[:limit]
        ]}, None

    if name == "get_quote":
        tickers = _tickers_arg(args, 10)
        if not tickers:
            return {"error": "get_quote needs at least one ticker"}, None
        out, missing = [], []
        for ticker in tickers:
            q = quotes.get_quote(ticker)
            if q is None:
                missing.append(ticker)
                continue
            out.append({
                "ticker": ticker, "symbol": q.symbol,
                "name": quotes.display_name(ticker, fallback=q.name),
                "price": q.price, "previous_close": q.previous_close,
                "currency": q.currency, "day_open": q.day_open,
                "day_high": q.day_high, "day_low": q.day_low, "volume": q.volume,
            })
        if not out:
            return {"error": f"No quotes found for {', '.join(missing)}"}, None
        result = {"quotes": out}
        if missing:
            result["not_found"] = missing
        # Single-ticker calls keep the old key so a mid-conversation model
        # reading `quote.price` doesn't suddenly find nothing there.
        if len(out) == 1:
            result["quote"] = out[0]
        return result, None

    if name == "get_price_history":
        tickers = _tickers_arg(args, 3)
        if not tickers:
            return {"error": "get_price_history needs at least one ticker"}, None
        period = args.get("period") or "1y"
        interval = args.get("interval") or "1d"
        series = []
        for ticker in tickers:
            bars = stock_info.get_history(ticker, period)
            bars = _resample(bars, interval)
            series.append({"ticker": ticker,
                           "bars": _downsample(bars, ("date", "close"))})
        return {"period": period, "interval": interval, "series": series}, None

    if name == "get_performance":
        market = (args.get("market") or "TW").upper()
        period = args.get("period") or "1y"
        with SessionLocal() as db:
            return {"performance": performance.build_performance(
                db, user_id, market=market, period=period)}, None

    if name == "get_dividend_calendar":
        with SessionLocal() as db:
            calendar = income.build_dividend_calendar(db, user_id)
        return {
            "calendar": calendar,
            "estimated": True,
            "basis": ("Every projected figure is per-share payout × shares held, "
                      "from the trailing 12 months of payments (or Yahoo's "
                      "forward rate where history is missing). Totals are given "
                      "per currency and are estimates, not booked amounts."),
        }, None

    if name == "get_value_history":
        market = (args.get("market") or "TW").upper()
        period = args.get("period") or "1y"
        with SessionLocal() as db:
            rows = portfolio.build_value_history(db, user_id, market=market, period=period)
        return {"market": market, "period": period,
                "points": _downsample(rows, ("date", "total"))}, None

    if name == "get_stock_info":
        ticker = str(args.get("ticker") or "").strip()
        if not ticker:
            return {"error": "get_stock_info needs a ticker"}, None
        include = args.get("include") or ["profile"]
        include = {str(i).lower() for i in include}
        out: dict = {"ticker": ticker,
                     "name": quotes.display_name(ticker, fallback=ticker)}
        if "profile" in include or not include:
            f = stock_info.get_fundamentals(ticker) or {}
            keys = ("sector", "industry", "market_cap", "pe", "forward_pe", "eps",
                    "dividend_yield", "dividend_rate", "beta", "price_to_book",
                    "average_volume", "fifty_two_week_high", "fifty_two_week_low",
                    "target_mean_price", "ex_dividend_date")
            out["profile"] = {k: _round(f.get(k)) for k in keys}
        if "revenue" in include:
            rev = stock_info.get_monthly_revenue(ticker, months=12) or []
            out["monthly_revenue"] = rev[-12:]
            if not rev:
                out["monthly_revenue_note"] = "月營收 is published for TW-listed companies only."
        if "financials" in include:
            fin = stock_info.get_quarterly_financials(ticker, quarters=8) or []
            keys = ("quarter", "revenue", "eps_diluted", "gross_margin",
                    "operating_margin", "net_margin")
            out["quarterly_financials"] = [
                {k: _round(row.get(k), 4) for k in keys} for row in fin[-8:]
            ]
        return out, None

    if name == "get_lots":
        open_only = args.get("open_only")
        open_only = True if open_only is None else bool(open_only)
        with SessionLocal() as db:
            q = db.query(Trade).filter(Trade.user_id == user_id)
            if args.get("market"):
                q = q.filter(Trade.market == str(args["market"]).upper())
            rows = q.all()
        lots = portfolio.build_lots(rows)
        ticker = str(args.get("ticker") or "").strip().upper()
        if ticker:
            lots = [l for l in lots if l["ticker"] == ticker]
        if open_only:
            lots = [l for l in lots if l["shares_remaining"] > 1e-9]
        return {"lots": lots, "open_only": open_only}, None

    if name == "simulate_sale":
        ticker = str(args.get("ticker") or "").strip().upper()
        shares = float(args.get("shares") or 0)
        if not ticker or shares <= 0:
            return {"error": "simulate_sale needs a ticker and shares > 0"}, None
        with SessionLocal() as db:
            rows = (db.query(Trade)
                    .filter(Trade.user_id == user_id, Trade.ticker == ticker)
                    .all())
        if not rows:
            return {"error": f"No trades recorded for {ticker}"}, None
        market = (rows[-1].market or quotes.market_of(ticker) or "TW").upper()
        price = args.get("price")
        if price is None:
            q = quotes.get_quote(ticker)
            price = q.price if q else None
        if not price:
            return {"error": f"No price available for {ticker}; pass one explicitly"}, None
        price = float(price)

        lots = [l for l in portfolio.build_lots(rows)
                if l["ticker"] == ticker and l["shares_remaining"] > 1e-9]
        held = sum(l["shares_remaining"] for l in lots)
        if shares > held + 1e-9:
            return {"error": f"Only {_round(held)} shares of {ticker} are held; "
                             f"cannot sell {_round(shares)}"}, None

        remaining, consumed, cost = shares, [], 0.0
        for lot in lots:
            if remaining <= 1e-9:
                break
            take = min(remaining, lot["shares_remaining"])
            consumed.append({"lot_id": lot["lot_id"], "buy_date": lot["buy_date"],
                             "shares": _round(take), "unit_cost": lot["unit_cost"]})
            cost += take * lot["unit_cost"]
            remaining -= take

        gross = shares * price
        costs = portfolio.sell_costs(ticker, gross, market)
        net = gross - costs["total"]
        return {
            "ticker": ticker, "market": market, "shares": _round(shares),
            "price": _round(price), "lots_consumed": consumed,
            "gross_proceeds": _round(gross),
            "commission": _round(costs["commission"]),
            "transaction_tax": _round(costs["tax"]),
            "transaction_tax_rate": costs["tax_rate"],
            "net_proceeds": _round(net),
            "cost_basis_consumed": _round(cost),
            "realized_pl": _round(net - cost),
            "shares_remaining_after": _round(held - shares),
            "basis": "Commission 0.1425%; TW transaction tax 0.3% for a stock, "
                     "0.1% for an ETF, 0% for a bond ETF; each floored to the "
                     "dollar. US sales are modelled commission- and tax-free.",
        }, None

    if name == "get_allocation":
        market = (args.get("market") or "").upper()
        group_by = (args.get("group_by") or "ticker").lower()
        top_n = max(1, min(int(args.get("top_n") or 10), 50))
        with SessionLocal() as db:
            rows = portfolio.build_holdings(db, user_id)
        rate, _ = fx.get_usd_twd()
        rate = rate or 0.0

        def in_twd(h):
            value = h.get("market_value") or 0.0
            return value * rate if h.get("market") == "US" else value

        net_worth = sum(in_twd(h) for h in rows) or 1.0
        scoped = [h for h in rows if not market or h.get("market") == market]
        market_total = sum(h.get("market_value") or 0.0 for h in scoped) or 1.0

        if group_by == "sector":
            names = sorted({h["ticker"] for h in scoped})
            with ThreadPoolExecutor(max_workers=8) as ex:
                info = dict(zip(names, ex.map(stock_info.get_fundamentals, names)))
            buckets: dict[str, float] = {}
            for h in scoped:
                sector = (info.get(h["ticker"]) or {}).get("sector") or "Unknown"
                buckets[sector] = buckets.get(sector, 0.0) + in_twd(h)
            items = [{"sector": k, "value_twd": _round(v),
                      "pct_of_net_worth": _round(v / net_worth * 100)}
                     for k, v in sorted(buckets.items(), key=lambda kv: -kv[1])]
        else:
            items = sorted(scoped, key=lambda h: -(h.get("market_value") or 0.0))
            items = [{
                "ticker": h["ticker"], "name": h.get("name"), "market": h.get("market"),
                "market_value": _round(h.get("market_value")),
                "pct_of_market": _round((h.get("market_value") or 0.0) / market_total * 100),
                "pct_of_net_worth": _round(in_twd(h) / net_worth * 100),
            } for h in items]

        head, tail = items[:top_n], items[top_n:]
        result = {"group_by": group_by, "market": market or "ALL", "positions": head}
        if tail:
            result["tail"] = {
                "count": len(tail),
                "pct_of_net_worth": _round(sum(i["pct_of_net_worth"] for i in tail)),
            }
        return result, None

    if name == "get_followed_indices":
        from ..routers.indices import KNOWN_NAMES, _index_market, _load_symbols

        with SessionLocal() as db:
            symbols = _load_symbols(db, user_id)
        quote_map = quotes.get_quotes(symbols)
        out = []
        for sym in symbols:
            q = quote_map.get(sym)
            price = q.price if q else None
            prev = q.previous_close if q else None
            change = price - prev if price is not None and prev is not None else None
            out.append({
                "symbol": sym,
                "name": KNOWN_NAMES.get(sym) or (q.name if q else sym) or sym,
                "market": _index_market(sym),
                "price": _round(price), "change": _round(change),
                "change_pct": _round(change / prev * 100) if change is not None and prev else None,
            })
        return {"indices": out}, None

    if name == "get_fx_rate":
        rate, asof = fx.get_usd_twd()
        return {"usd_twd": rate, "asof": asof}, None

    if name == "get_market_status":
        now = datetime.now(_TAIPEI)
        out = {"today": today, "taipei_time": now.strftime("%Y-%m-%d %H:%M")}
        for code in ("TW", "US"):
            nxt_open, nxt_close = _next_session(code)
            out[f"{code.lower()}_open"] = markets.is_market_open(code)
            out[f"{code.lower()}_next_open"] = nxt_open
            out[f"{code.lower()}_next_close"] = nxt_close
        return out, None

    if name == "search_web":
        raw = args.get("queries") or []
        queries = [_enrich_query(str(q).strip()) for q in raw if str(q).strip()][:3]
        if not queries:
            return {"error": "No queries given"}, None
        return {"results": ai_providers.search_web(queries)}, None

    if name == "generate_report":
        from . import reports as report_service

        template = str(args.get("template") or "").strip()
        if template not in report_service.TEMPLATE_IDS:
            return {"error": f"Unknown report template {template!r}. One of: "
                             f"{', '.join(sorted(report_service.TEMPLATE_IDS))}"}, None
        period = str(args.get("period") or "ytd")
        if args.get("year"):
            period = f"year:{int(args['year'])}"
        params = {"ticker": str(args["ticker"]).strip().upper()} if args.get("ticker") else {}

        with SessionLocal() as db:
            version = report_service.data_version(db, user_id)
            key = report_service.cache_key(template, period, params, version)
            existing = (db.query(Report)
                        .filter(Report.user_id == user_id, Report.cache_key == key,
                                Report.status != "failed")
                        .order_by(Report.created_at.desc())
                        .first())
            if existing is not None and (existing.status != "ready"
                                         or report_service.file_path(existing.id).exists()):
                row = existing
            else:
                definition = report_service.template_def(template)
                _s, _e, label = report_service.resolve_period(period)
                row = Report(id=report_service.new_id(), user_id=user_id,
                             template=template, period=period,
                             params=json.dumps(params), cache_key=key,
                             status="pending", title=definition["name"],
                             subtitle=f"{label} · TWD base",
                             created_at=datetime.utcnow())
                db.add(row)
                db.commit()
                report_service.start(row.id, user_id, template, period, params)
            payload = {"report_id": row.id, "status": row.status,
                       "template": row.template, "title": row.title,
                       "subtitle": row.subtitle, "row_count": row.row_count,
                       "headline": row.headline}

        # The model gets the headline and nothing else of the document: it must
        # write one honest sentence beside the card, not re-narrate a table it
        # cannot see.
        return {
            **payload,
            "note": ("The app is showing a report card with an Open button. "
                     "Write one sentence about what the report contains — use "
                     "`headline` if it is filled — and do not restate the "
                     "table."),
        }, {"report": payload}

    if name == "propose_records":
        return _propose_records(args, user_id, today)

    if name in ("update_trade", "update_dividend"):
        is_trade = name == "update_trade"
        model = Trade if is_trade else Dividend
        with SessionLocal() as db:
            row = _load_owned(db, model, user_id, args.get("id"))
            if row is None:
                return {"error": f"No {'trade' if is_trade else 'dividend'} with "
                                 f"id {args.get('id')!r} in your records."}, None
            stored = _trade_fields(row) if is_trade else _dividend_fields(row)
            fields = ("type", "ticker", "shares", "price", "date", "fee", "market", "notes") \
                if is_trade else ("ticker", "amount", "date", "market", "notes")
            proposed = {}
            for key in fields:
                if key not in args or args[key] is None:
                    continue
                value = args[key]
                if key in ("shares", "price", "fee", "amount"):
                    value = float(value)
                elif key in ("ticker", "market"):
                    value = str(value).strip().upper()
                elif key == "type":
                    value = str(value).lower()
                else:
                    value = str(value)
                proposed[key] = value
            before, after = _changed(stored, proposed)
            if not after:
                return {"error": "Nothing would change — the values given match "
                                 "what is already stored."}, None
            entry = {"op": "update", "id": row.id, "before": before,
                     "after": after, "record": stored}
        action = {"trades": [entry] if is_trade else [],
                  "dividends": [] if is_trade else [entry], "notes": ""}
        return dict(_PROPOSED), action

    if name in ("delete_trade", "delete_dividend"):
        is_trade = name == "delete_trade"
        model = Trade if is_trade else Dividend
        with SessionLocal() as db:
            row = _load_owned(db, model, user_id, args.get("id"))
            if row is None:
                return {"error": f"No {'trade' if is_trade else 'dividend'} with "
                                 f"id {args.get('id')!r} in your records."}, None
            entry = {
                "op": "delete", "id": row.id,
                "record": _trade_fields(row) if is_trade else _dividend_fields(row),
                "consequences": _delete_consequences(db, row) if is_trade else [],
            }
        action = {"trades": [entry] if is_trade else [],
                  "dividends": [] if is_trade else [entry], "notes": ""}
        return dict(_PROPOSED), action

    if name == "add_trade":
        row = {
            "op": "create",
            "type": str(args.get("type") or "buy").lower(),
            "ticker": str(args.get("ticker") or "").strip().upper(),
            "shares": float(args.get("shares") or 0),
            "price": float(args.get("price") or 0),
            "date": str(args.get("date") or today),
            "fee": float(args.get("fee") or 0),
            "notes": args.get("notes"),
        }
        if args.get("market"):
            row["market"] = str(args["market"]).upper()
        if not row["ticker"] or row["shares"] <= 0 or row["price"] <= 0:
            return {"error": "add_trade needs ticker, shares > 0 and price > 0"}, None
        with SessionLocal() as db:
            row["duplicate_of"] = _duplicate_trade_id(db, user_id, row)
        return dict(_PROPOSED), {"trades": [row], "dividends": [], "notes": ""}

    if name == "add_dividend":
        row = {
            "op": "create",
            "ticker": str(args.get("ticker") or "").strip().upper(),
            "amount": float(args.get("amount") or 0),
            "date": str(args.get("date") or today),
            "notes": args.get("notes"),
        }
        if args.get("market"):
            row["market"] = str(args["market"]).upper()
        if not row["ticker"] or row["amount"] <= 0:
            return {"error": "add_dividend needs ticker and amount > 0"}, None
        with SessionLocal() as db:
            row["duplicate_of"] = _duplicate_dividend_id(db, user_id, row)
        return dict(_PROPOSED), {"trades": [], "dividends": [row], "notes": ""}

    return {"error": f"Unknown tool: {name}"}, None


# ---------------------------------------------------------------------------
# Write-tool helpers
# ---------------------------------------------------------------------------

def _duplicate_trade_id(db, user_id: str, row: dict) -> int | None:
    """An existing trade matching ticker + date + shares + price. The card
    pre-flags these; a statement photographed twice is the common case, and a
    silently doubled lot is expensive to notice later."""
    try:
        when = date.fromisoformat(str(row.get("date"))[:10])
    except ValueError:
        return None
    for t in (db.query(Trade)
              .filter(Trade.user_id == user_id,
                      Trade.ticker == row.get("ticker"),
                      Trade.trade_date == when)
              .all()):
        if (abs(t.shares - float(row.get("shares") or 0)) < 1e-9
                and abs(t.price - float(row.get("price") or 0)) < 1e-9):
            return t.id
    return None


def _duplicate_dividend_id(db, user_id: str, row: dict) -> int | None:
    try:
        when = date.fromisoformat(str(row.get("date"))[:10])
    except ValueError:
        return None
    for d in (db.query(Dividend)
              .filter(Dividend.user_id == user_id,
                      Dividend.ticker == row.get("ticker"),
                      Dividend.pay_date == when)
              .all()):
        if abs(d.amount - float(row.get("amount") or 0)) < 1e-9:
            return d.id
    return None


def _propose_records(args: dict, user_id: str, today: str) -> tuple[dict, dict | None]:
    """One proposal carrying any number of records of either kind, and any mix
    of create/update/delete.

    ``add_trade`` fills exactly one slot, so a statement photo with eight rows
    costs eight rounds against the loop ceiling and gives the user eight cards
    to tap. This is the same payload shape, filled properly.
    """
    trades_in = args.get("trades") or []
    dividends_in = args.get("dividends") or []
    if not trades_in and not dividends_in:
        return {"error": "propose_records needs at least one trade or dividend"}, None

    trades_out: list[dict] = []
    dividends_out: list[dict] = []
    errors: list[str] = []

    with SessionLocal() as db:
        for raw in trades_in[:50]:
            op = str(raw.get("op") or "create").lower()
            if op == "create":
                row = {
                    "op": "create",
                    "type": str(raw.get("type") or "buy").lower(),
                    "ticker": str(raw.get("ticker") or "").strip().upper(),
                    "shares": float(raw.get("shares") or 0),
                    "price": float(raw.get("price") or 0),
                    "date": str(raw.get("date") or today),
                    "fee": float(raw.get("fee") or 0),
                    "notes": raw.get("notes"),
                }
                if raw.get("market"):
                    row["market"] = str(raw["market"]).upper()
                if not row["ticker"] or row["shares"] <= 0 or row["price"] <= 0:
                    errors.append(f"Skipped a trade row: needs ticker, shares > 0 and price > 0")
                    continue
                row["duplicate_of"] = _duplicate_trade_id(db, user_id, row)
                trades_out.append(row)
                continue

            row_db = _load_owned(db, Trade, user_id, raw.get("id"))
            if row_db is None:
                errors.append(f"No trade with id {raw.get('id')!r} in your records.")
                continue
            stored = _trade_fields(row_db)
            if op == "delete":
                trades_out.append({"op": "delete", "id": row_db.id, "record": stored,
                                   "consequences": _delete_consequences(db, row_db)})
                continue
            proposed = {k: raw[k] for k in
                        ("type", "ticker", "shares", "price", "date", "fee", "market", "notes")
                        if raw.get(k) is not None}
            for k in ("shares", "price", "fee"):
                if k in proposed:
                    proposed[k] = float(proposed[k])
            for k in ("ticker", "market"):
                if k in proposed:
                    proposed[k] = str(proposed[k]).strip().upper()
            before, after = _changed(stored, proposed)
            if not after:
                errors.append(f"Trade {row_db.id} already holds those values.")
                continue
            trades_out.append({"op": "update", "id": row_db.id, "before": before,
                               "after": after, "record": stored})

        for raw in dividends_in[:50]:
            op = str(raw.get("op") or "create").lower()
            if op == "create":
                row = {
                    "op": "create",
                    "ticker": str(raw.get("ticker") or "").strip().upper(),
                    "amount": float(raw.get("amount") or 0),
                    "date": str(raw.get("date") or today),
                    "notes": raw.get("notes"),
                }
                if raw.get("market"):
                    row["market"] = str(raw["market"]).upper()
                if not row["ticker"] or row["amount"] <= 0:
                    errors.append("Skipped a dividend row: needs ticker and amount > 0")
                    continue
                row["duplicate_of"] = _duplicate_dividend_id(db, user_id, row)
                dividends_out.append(row)
                continue

            row_db = _load_owned(db, Dividend, user_id, raw.get("id"))
            if row_db is None:
                errors.append(f"No dividend with id {raw.get('id')!r} in your records.")
                continue
            stored = _dividend_fields(row_db)
            if op == "delete":
                dividends_out.append({"op": "delete", "id": row_db.id,
                                      "record": stored, "consequences": []})
                continue
            proposed = {k: raw[k] for k in ("ticker", "amount", "date", "market", "notes")
                        if raw.get(k) is not None}
            if "amount" in proposed:
                proposed["amount"] = float(proposed["amount"])
            for k in ("ticker", "market"):
                if k in proposed:
                    proposed[k] = str(proposed[k]).strip().upper()
            before, after = _changed(stored, proposed)
            if not after:
                errors.append(f"Dividend {row_db.id} already holds those values.")
                continue
            dividends_out.append({"op": "update", "id": row_db.id, "before": before,
                                  "after": after, "record": stored})

    if not trades_out and not dividends_out:
        return {"error": "; ".join(errors) or "Nothing could be proposed."}, None

    summary = str(args.get("summary") or "").strip()
    action = {"trades": trades_out, "dividends": dividends_out,
              "notes": summary, "summary": summary}
    result = dict(_PROPOSED)
    result["proposed"] = {"trades": len(trades_out), "dividends": len(dividends_out)}
    flagged = sum(1 for r in trades_out + dividends_out if r.get("duplicate_of"))
    if flagged:
        result["duplicates_flagged"] = flagged
    if errors:
        result["skipped"] = errors
    return result, action


def _realized_by_sell(trades: list) -> dict[int, float]:
    """Realized P/L booked by each sell, FIFO-matched over the whole ledger.

    The same walk ``portfolio._apply_trade`` does, kept per-sell rather than
    per-ticker: "what did that sale actually make" is asked constantly, and
    from a per-ticker total it is not answerable at all.
    """
    out: dict[int, float] = {}
    by_ticker: dict[str, list] = {}
    for t in trades:
        by_ticker.setdefault(t.ticker, []).append(t)
    for rows in by_ticker.values():
        lots: list[list] = []   # [remaining, unit_cost]
        for t in sorted(rows, key=lambda r: (r.trade_date, r.id)):
            if t.type == "buy":
                if t.shares > 0:
                    lots.append([t.shares, (t.shares * t.price + t.fee) / t.shares])
                continue
            qty, booked = t.shares, -t.fee
            while qty > 1e-9 and lots:
                take = min(qty, lots[0][0])
                booked += take * (t.price - lots[0][1])
                lots[0][0] -= take
                qty -= take
                if lots[0][0] <= 1e-9:
                    lots.pop(0)
            if qty > 1e-9:
                booked += qty * t.price
            out[t.id] = booked
    return out


def _resample(bars: list[dict], interval: str) -> list[dict]:
    """Weekly/monthly closes from daily bars — last bar of each bucket.

    Daily bars over five years are ~1,250 rows; a weekly series is a fifth of
    that and says the same thing about a trend, which matters when the
    alternative is the result being trimmed.
    """
    if interval == "1d" or not bars:
        return bars
    width = 7 if interval == "1wk" else 0
    out: list[dict] = []
    last_key = None
    for bar in bars:
        day = str(bar.get("date") or "")[:10]
        if not day:
            continue
        if width:
            try:
                key = date.fromisoformat(day).isocalendar()[:2]
            except ValueError:
                continue
        else:
            key = day[:7]
        if key == last_key:
            out[-1] = bar
        else:
            out.append(bar)
            last_key = key
    return out


_TW_CODE = re.compile(r"^\d{4,6}[A-Z]?$")


def _enrich_query(query: str) -> str:
    """Append the company name to a bare TW stock code.

    A search for "2330" alone returns numerology and part numbers. The tool
    description used to ask the model to remember this; the code can guarantee
    it, and a guarantee is worth more than an instruction.
    """
    parts = query.split()
    for part in parts:
        if _TW_CODE.match(part.upper()):
            name = stock_info.get_tw_chinese_name(part)
            if name and name not in query:
                return f"{query} {name}"
            break
    return query


# ---------------------------------------------------------------------------
# Provider schema adapters
# ---------------------------------------------------------------------------

def openai_tools() -> list[dict]:
    return [
        {"type": "function",
         "function": {"name": t["name"], "description": t["description"],
                      "parameters": t["parameters"]}}
        for t in TOOLS
    ]


def claude_tools() -> list[dict]:
    return [
        {"name": t["name"], "description": t["description"],
         "input_schema": t["parameters"]}
        for t in TOOLS
    ]


def gemini_declarations(types) -> list:
    decls = []
    for t in TOOLS:
        params = t["parameters"]
        # Gemini rejects an object schema with zero properties — omit instead.
        decls.append(types.FunctionDeclaration(
            name=t["name"],
            description=t["description"],
            parameters=params if params.get("properties") else None,
        ))
    return decls


# ---------------------------------------------------------------------------
# Tool loops — one generator per provider API shape. Each yields
# ("chunk", text) / ("status", label) / ("action", records-dict) /
# ("thinking", text) — reasoning deltas, where the provider exposes them
# (Claude extended thinking, Gemini thought summaries; OpenAI/NIM don't).
# ---------------------------------------------------------------------------

# Raised from 6 now that quotes and price history batch: a grounded
# multi-market answer legitimately needs summary + holdings + two histories +
# FX + a search, and the loop used to end before the answer did.
MAX_TOOL_ROUNDS = 8

# Chars of JSON per tool result fed back to the model. Per-tool rather than one
# uniform number: a search result set and a price series have nothing in common
# except that both are text.
_RESULT_CAP = 8000
_RESULT_CAPS = {
    "search_web": 12000,
    "get_price_history": 12000,
    "get_performance": 12000,
    "get_dividend_calendar": 12000,
    "get_stock_info": 10000,
    "get_lots": 10000,
    "get_trades": 10000,
}

# Series a long result can be thinned by, rather than cut. Truncating JSON
# mid-array is worse than sending less of it: the model reads the fragment as
# the whole series and reports a trend that isn't there.
_SERIES_PATHS = (
    ("points",), ("bars",), ("series", "bars"), ("lots",), ("trades",),
    ("dividends",), ("performance", "portfolio_series"),
    ("performance", "benchmark", "series"),
)


def _thin(result: dict, budget: int) -> dict:
    """Halve the longest series in ``result`` until it fits."""
    out = json.loads(json.dumps(result, ensure_ascii=False, default=str))
    for _ in range(6):
        if len(json.dumps(out, ensure_ascii=False)) <= budget:
            return out
        longest, holder, key = 0, None, None
        for path in _SERIES_PATHS:
            for node in _walk(out, path):
                container, k = node
                value = container.get(k)
                if isinstance(value, list) and len(value) > longest:
                    longest, holder, key = len(value), container, k
        if holder is None or longest <= 4:
            break
        holder[key] = holder[key][:: 2] or holder[key][:1]
    return out


def _walk(node, path: tuple[str, ...]):
    """Yield ``(container, key)`` for every place ``path`` resolves to."""
    if not path:
        return
    head, rest = path[0], path[1:]
    if isinstance(node, list):
        for item in node:
            yield from _walk(item, path)
        return
    if not isinstance(node, dict) or head not in node:
        return
    if not rest:
        yield node, head
        return
    yield from _walk(node[head], rest)


def _result_json(result: dict, name: str = "") -> str:
    budget = _RESULT_CAPS.get(name, _RESULT_CAP)
    text = json.dumps(result, ensure_ascii=False, default=str)
    if len(text) <= budget:
        return text
    thinned = json.dumps(_thin(result, budget), ensure_ascii=False, default=str)
    # Still over after thinning (a huge search result, say) — cut, but say so,
    # so a fragment is never read as the whole.
    if len(thinned) > budget:
        return thinned[:budget] + '… (truncated)"}'
    return thinned


def run_tool_loop(provider: str, api_key: str, model: str, system_prompt: str,
                  history, user_id: str):
    if provider == "gemini":
        return _gemini_loop(api_key, model, system_prompt, history, user_id)
    if provider == "claude":
        return _claude_loop(api_key, model, system_prompt, history, user_id)
    return _openai_loop(provider, api_key, model, system_prompt, history, user_id)


def _openai_user_content(content: str, image: bytes | None, mime: str | None,
                         vision: bool):
    """Plain text, or an OpenAI-style multipart content list when an image is
    attached. ``vision=False`` (NVIDIA NIM's free-tier text models) drops the
    image and tells the model one was attached, rather than sending bytes it
    can't understand."""
    if not image:
        return content
    if not vision:
        note = "[The user attached an image, but this model can't view images." \
               " Ask them to describe it, or switch to Gemini/OpenAI/Claude.]"
        return f"{content}\n{note}" if content else note
    parts: list[dict] = []
    if content:
        parts.append({"type": "text", "text": content})
    b64 = base64.b64encode(image).decode()
    parts.append({"type": "image_url",
                 "image_url": {"url": f"data:{mime or 'image/jpeg'};base64,{b64}"}})
    return parts


def _openai_loop(provider: str, api_key: str, model: str, system_prompt: str,
                 history, user_id: str):
    """OpenAI and NVIDIA NIM (OpenAI-compatible). NVIDIA's free-tier models are
    text-only, so images are only forwarded for the real OpenAI provider."""
    base_url = ai_providers.NVIDIA_BASE_URL if provider == "nvidia" else None
    client = ai_providers._openai_client(api_key, base_url=base_url, timeout=120.0)
    extra = ai_providers._nim_extra_body(model) if provider == "nvidia" else None
    vision = provider == "openai"

    messages: list[dict] = [{"role": "system", "content": system_prompt}]
    for role, content, image, mime in history:
        messages.append({
            "role": "assistant" if role == "assistant" else "user",
            "content": _openai_user_content(content, image, mime, vision),
        })

    for _ in range(MAX_TOOL_ROUNDS):
        stream = client.chat.completions.create(
            model=model, messages=messages, stream=True, max_tokens=1500,
            temperature=0.4, tools=openai_tools(), extra_body=extra,
        )
        calls: dict[int, dict] = {}
        for event in stream:
            choices = getattr(event, "choices", None) or []
            if not choices:
                continue
            delta = choices[0].delta
            if getattr(delta, "content", None):
                yield ("chunk", delta.content)
            for tc in getattr(delta, "tool_calls", None) or []:
                slot = calls.setdefault(tc.index, {"id": "", "name": "", "args": ""})
                if tc.id:
                    slot["id"] = tc.id
                if tc.function and tc.function.name:
                    slot["name"] = tc.function.name
                if tc.function and tc.function.arguments:
                    slot["args"] += tc.function.arguments

        if not calls:
            return
        ordered = [calls[i] for i in sorted(calls)]
        messages.append({
            "role": "assistant",
            "tool_calls": [
                {"id": c["id"], "type": "function",
                 "function": {"name": c["name"], "arguments": c["args"] or "{}"}}
                for c in ordered
            ],
        })
        for c in ordered:
            yield ("status", status_label(c["name"]))
            try:
                parsed = json.loads(c["args"] or "{}")
            except json.JSONDecodeError:
                parsed = {}
            result, action = execute(c["name"], parsed, user_id)
            if action:
                yield ("action", action)
            messages.append({"role": "tool", "tool_call_id": c["id"],
                             "content": _result_json(result, c["name"])})


def _claude_content(content: str, image: bytes | None, mime: str | None):
    """Plain text, or an Anthropic-style content block list with the image
    first (Claude reads images best when they precede the caption text)."""
    if not image:
        return content
    parts: list[dict] = [{
        "type": "image",
        "source": {"type": "base64", "media_type": mime or "image/jpeg",
                   "data": base64.b64encode(image).decode()},
    }]
    if content:
        parts.append({"type": "text", "text": content})
    return parts


def _claude_loop(api_key: str, model: str, system_prompt: str,
                 history, user_id: str):
    import anthropic

    client = anthropic.Anthropic(api_key=api_key)
    messages = [
        {"role": "assistant" if role == "assistant" else "user",
         "content": _claude_content(content, image, mime)}
        for role, content, image, mime in history
    ]
    if not messages:
        return

    # Extended thinking streams the model's reasoning as it happens (the app
    # shows it in a collapsible section, like Claude's own UI). Models that
    # reject the parameter fall back to plain streaming once, permanently.
    thinking: dict | None = {"type": "enabled", "budget_tokens": 2000}

    for _ in range(MAX_TOOL_ROUNDS):
        kwargs = dict(model=model, max_tokens=4096, system=system_prompt,
                      messages=messages, tools=claude_tools())
        if thinking:
            kwargs["thinking"] = thinking
        try:
            stream_cm = client.messages.stream(**kwargs)
            stream_cm.__enter__()
        except anthropic.BadRequestError:
            if not thinking:
                raise
            thinking = None
            kwargs.pop("thinking", None)
            stream_cm = client.messages.stream(**kwargs)
            stream_cm.__enter__()
        try:
            for event in stream_cm:
                if getattr(event, "type", "") == "content_block_delta":
                    delta = event.delta
                    dtype = getattr(delta, "type", "")
                    if dtype == "text_delta" and delta.text:
                        yield ("chunk", delta.text)
                    elif dtype == "thinking_delta" and getattr(delta, "thinking", ""):
                        yield ("thinking", delta.thinking)
            final = stream_cm.get_final_message()
        finally:
            stream_cm.__exit__(None, None, None)

        tool_uses = [b for b in final.content if b.type == "tool_use"]
        if not tool_uses:
            return
        messages.append({"role": "assistant", "content": final.content})
        results = []
        for block in tool_uses:
            yield ("status", status_label(block.name))
            result, action = execute(block.name, dict(block.input or {}), user_id)
            if action:
                yield ("action", action)
            results.append({"type": "tool_result", "tool_use_id": block.id,
                            "content": _result_json(result, block.name)})
        messages.append({"role": "user", "content": results})


def _gemini_loop(api_key: str, model: str, system_prompt: str,
                 history, user_id: str):
    """Gemini function calling. Note: Gemini cannot mix google_search with
    function declarations in one request, so web needs go through the
    search_web tool here."""
    from google import genai
    from google.genai import types

    client = genai.Client(api_key=api_key)

    def _parts(content: str, image: bytes | None, mime: str | None):
        parts = []
        if content:
            parts.append(types.Part(text=content))
        if image:
            parts.append(types.Part.from_bytes(data=image, mime_type=mime or "image/jpeg"))
        return parts

    contents = [
        types.Content(role="user" if role == "user" else "model",
                      parts=_parts(content, image, mime))
        for role, content, image, mime in history
    ]

    def _config(with_thoughts: bool):
        kwargs = dict(
            system_instruction=system_prompt,
            temperature=0.4,
            max_output_tokens=1500,
            tools=[types.Tool(function_declarations=gemini_declarations(types))],
        )
        if with_thoughts:
            # Thought summaries stream the model's reasoning for the app's
            # collapsible "Thinking" section.
            kwargs["thinking_config"] = types.ThinkingConfig(include_thoughts=True)
        return types.GenerateContentConfig(**kwargs)

    with_thoughts = True
    for _ in range(MAX_TOOL_ROUNDS):
        fcalls = []
        emitted_any = False
        try:
            stream = client.models.generate_content_stream(
                model=model, config=_config(with_thoughts), contents=contents,
            )
            for chunk in stream:
                for cand in getattr(chunk, "candidates", None) or []:
                    content = getattr(cand, "content", None)
                    for part in (getattr(content, "parts", None) or []):
                        fc = getattr(part, "function_call", None)
                        if fc is not None and fc.name:
                            fcalls.append(fc)
                        elif getattr(part, "text", None):
                            emitted_any = True
                            if getattr(part, "thought", False):
                                yield ("thinking", part.text)
                            else:
                                yield ("chunk", part.text)
        except Exception:
            # Models without thinking support can reject the config — retry
            # this round once without thought summaries, then stay off.
            if not with_thoughts or emitted_any or fcalls:
                raise
            with_thoughts = False
            continue

        if not fcalls:
            return
        contents.append(types.Content(
            role="model", parts=[types.Part(function_call=fc) for fc in fcalls]))
        resp_parts = []
        for fc in fcalls:
            yield ("status", status_label(fc.name))
            result, action = execute(fc.name, dict(fc.args or {}), user_id)
            if action:
                yield ("action", action)
            # Gemini takes the dict directly, so thin it here rather than
            # relying on the JSON cap the other two loops apply.
            resp_parts.append(types.Part.from_function_response(
                name=fc.name,
                response={"result": _thin(result, _RESULT_CAPS.get(fc.name, _RESULT_CAP))}))
        contents.append(types.Content(role="user", parts=resp_parts))
