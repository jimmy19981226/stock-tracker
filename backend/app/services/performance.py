"""Portfolio performance — TWR, XIRR, benchmark comparison, 期間績效.

Built on the cached daily value series (portfolio.build_value_history) plus
the user's trade/dividend log as external cash flows:

  * TWR (time-weighted return) — daily chain-linked, flows neutralized, the
    right number to compare against an index. Buys are contributions, sells
    and dividends are withdrawals (the value series holds securities only).
  * XIRR (money-weighted, annualized) — what *your* money actually earned,
    timing included. Bisection solver, no dependencies.
  * Benchmark — the market's headline index (TAIEX / S&P 500) normalized to
    the same start date, as a % series for overlaying on the TWR curve.
  * Monthly P/L (期間績效) — per-calendar-month profit net of contributions,
    the bars TW broker apps show.
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Iterable

import time
from threading import Lock

from sqlalchemy.orm import Session

from ..database import Dividend, Metadata, Trade
from . import portfolio, quotes, stock_info

# What each market is compared against unless the user picks something else.
DEFAULT_BENCHMARKS = {"TW": "^TWII", "US": "^GSPC"}

# Offered in the app's picker. Any Yahoo-resolvable symbol works — an index
# (``^TWII``), a TW ETF by bare code (``0050``), or a US ticker (``QQQ``) — so
# this list is a convenience, not a whitelist.
BENCHMARK_PRESETS = {
    "TW": [
        ("^TWII", "加權指數"),
        ("^TWOII", "櫃買指數"),
        ("0050", "元大台灣50"),
        ("006208", "富邦台50"),
        ("0056", "元大高股息"),
    ],
    "US": [
        ("^GSPC", "S&P 500"),
        ("^IXIC", "NASDAQ"),
        ("^DJI", "Dow Jones"),
        ("^SOX", "費城半導體"),
        ("QQQ", "Invesco QQQ"),
        ("VOO", "Vanguard S&P 500"),
    ],
}

_PRESET_NAMES = {sym: name for rows in BENCHMARK_PRESETS.values() for sym, name in rows}
_BENCHMARK_META_PREFIX = "benchmark:"
# Metadata.key is String(50): "benchmark:" + "google:<21-digit sub>" ≈ 38 chars.
_SYMBOL_RE = re.compile(r"^[\^]?[A-Z0-9.\-=]{1,12}$")


def _benchmark_meta_key(user_id: str) -> str:
    return f"{_BENCHMARK_META_PREFIX}{user_id}"


def get_benchmarks(db: Session, user_id: str) -> dict[str, str]:
    """The user's benchmark symbol per market, with defaults filled in."""
    out = dict(DEFAULT_BENCHMARKS)
    row = db.get(Metadata, _benchmark_meta_key(user_id))
    if row and row.value:
        try:
            saved = json.loads(row.value)
        except ValueError:
            saved = {}
        if isinstance(saved, dict):
            for market, symbol in saved.items():
                if isinstance(symbol, str) and symbol.strip():
                    out[str(market).upper()] = symbol.strip().upper()
    return out


def set_benchmark(db: Session, user_id: str, market: str, symbol: str) -> dict[str, str]:
    """Point one market at a different benchmark. An empty symbol resets it to
    the default. Raises ValueError on a malformed symbol."""
    market = market.upper()
    if market not in DEFAULT_BENCHMARKS:
        raise ValueError(f"Unknown market '{market}'")
    symbol = (symbol or "").strip().upper()
    if symbol and not _SYMBOL_RE.match(symbol):
        raise ValueError(f"Invalid benchmark symbol: {symbol}")

    current = get_benchmarks(db, user_id)
    current[market] = symbol or DEFAULT_BENCHMARKS[market]
    # Persist only the non-default picks, so changing a default later actually
    # takes effect for users who never chose one.
    stored = {m: s for m, s in current.items() if s != DEFAULT_BENCHMARKS.get(m)}
    key = _benchmark_meta_key(user_id)
    row = db.get(Metadata, key)
    if row is None:
        db.add(Metadata(key=key, value=json.dumps(stored)))
    else:
        row.value = json.dumps(stored)
    db.commit()
    invalidate_user(user_id)
    return current


def benchmark_name(symbol: str) -> str:
    """Display name for a benchmark symbol: the curated name where we have one,
    otherwise the TW Chinese short name / live quote name, else the symbol."""
    symbol = symbol.upper()
    if symbol in _PRESET_NAMES:
        return _PRESET_NAMES[symbol]
    quote = quotes.get_quote(symbol)
    return quotes.display_name(symbol, fallback=(quote.name if quote else "")) or symbol

# Cache a report's exact bounds, so a rolling window advances each day.
_CACHE_TTL = 900.0
_cache: dict[tuple, tuple[float, dict]] = {}
_cache_lock = Lock()


def _xirr(flows: list[tuple[date, float]]) -> float | None:
    """Annualized money-weighted return via bisection. ``flows`` are
    (date, amount) with investor outlays negative, proceeds positive."""
    if len(flows) < 2:
        return None
    if all(a >= 0 for _, a in flows) or all(a <= 0 for _, a in flows):
        return None
    t0 = flows[0][0]

    def npv(rate: float) -> float:
        return sum(a / (1.0 + rate) ** ((d - t0).days / 365.0) for d, a in flows)

    lo, hi = -0.9999, 10.0
    f_lo, f_hi = npv(lo), npv(hi)
    if f_lo * f_hi > 0:
        return None
    for _ in range(200):
        mid = (lo + hi) / 2
        f_mid = npv(mid)
        if abs(f_mid) < 1e-9:
            break
        if f_lo * f_mid < 0:
            hi, f_hi = mid, f_mid
        else:
            lo, f_lo = mid, f_mid
    return (lo + hi) / 2


def _daily_flows(
    trades: Iterable[Trade], dividends: Iterable[Dividend], market: str
) -> tuple[dict[str, float], dict[str, float]]:
    """(inflows, outflows) keyed by ISO date. Inflow = cash the investor put
    in (buy cost incl. fee); outflow = cash taken out (sell net proceeds +
    dividends received)."""
    fin: dict[str, float] = defaultdict(float)
    fout: dict[str, float] = defaultdict(float)
    for t in trades:
        if (t.market or quotes.market_of(t.ticker)) != market:
            continue
        d = t.trade_date.isoformat()
        if t.type == "buy":
            fin[d] += t.shares * t.price + t.fee
        else:
            fout[d] += t.shares * t.price - t.fee
    for dv in dividends:
        if (dv.market or quotes.market_of(dv.ticker)) != market:
            continue
        fout[dv.pay_date.isoformat()] += dv.amount
    return fin, fout


def invalidate_user(user_id: str) -> None:
    """Drop this user's cached reports — called when they switch benchmark, so
    the change shows up on the next request instead of after the TTL."""
    with _cache_lock:
        for key in [k for k in _cache if k[0] == user_id]:
            _cache.pop(key, None)


PERIODS = {"5d", "2w", "14d", "1mo", "3mo", "6mo", "ytd", "1y", "2y", "5y", "max"}


def _resolve_window(period: str, start_date: str | None = None,
                    end_date: str | None = None) -> tuple[date | None, date]:
    today = date.today()
    if start_date is not None or end_date is not None:
        if not start_date or not end_date:
            raise ValueError("Provide both start_date and end_date (YYYY-MM-DD).")
        try:
            start, end = date.fromisoformat(start_date), date.fromisoformat(end_date)
        except (TypeError, ValueError) as exc:
            raise ValueError("Dates must use YYYY-MM-DD.") from exc
        if start >= end:
            raise ValueError("start_date must be before end_date.")
        if end > today:
            raise ValueError("end_date cannot be in the future.")
        return start, end
    if period not in PERIODS:
        raise ValueError(f"Unsupported performance period: {period}. Use 2w for the last 14 days.")
    start = None if period == "max" else date.fromisoformat(portfolio._window_start(period))
    return start, today


def build_performance(db: Session, user_id: str, market: str, period: str = "1y", *,
                      start_date: str | None = None, end_date: str | None = None) -> dict:
    market = market.upper()
    if market not in DEFAULT_BENCHMARKS:
        raise ValueError(f"Unknown market: {market}")
    start, end = _resolve_window(period, start_date, end_date)
    period = "custom" if start_date is not None else ("2w" if period == "14d" else period)
    bench_symbol = get_benchmarks(db, user_id).get(market, DEFAULT_BENCHMARKS["US"])
    # The benchmark is part of the cache identity: two symbols produce two
    # different reports for the same (user, market, period).
    key = (user_id, market, period, bench_symbol, start, end)
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < _CACHE_TTL:
            return hit[1]
    result = _build(db, user_id, market, period, bench_symbol, start, end)
    # Never cache an empty report — that's a failed value-history build
    # (throttled Yahoo), not a fact.
    if result["portfolio_series"]:
        with _cache_lock:
            _cache[key] = (now, result)
    return result


def _build(db: Session, user_id: str, market: str, period: str,
           bench_symbol: str, start: date | None, end: date) -> dict:
    bench_name = benchmark_name(bench_symbol)
    empty = {
        "market": market,
        "currency": quotes.currency_of(market),
        "period": period,
        "requested_start_date": start.isoformat() if start else None,
        "requested_end_date": end.isoformat(),
        "start_date": None,
        "end_date": None,
        "status": "history_unavailable",
        "twr_pct": None,
        "twr_annualized_pct": None,
        "xirr_pct": None,
        "period_pl": None,
        "portfolio_series": [],
        "benchmark": {"symbol": bench_symbol, "name": bench_name,
                      "return_pct": None, "series": []},
        "monthly": [],
    }

    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    dividends = db.query(Dividend).filter(Dividend.user_id == user_id).all()
    mtrades = [t for t in trades if (t.market or quotes.market_of(t.ticker)) == market
               and t.trade_date <= end]
    if not mtrades:
        return {**empty, "status": "no_positions", "reason": "No trades recorded in this market."}
    try:
        series = (portfolio.build_value_history_range(db, user_id, market, start, end)
                  if start else portfolio.build_value_history(db, user_id, market, "max"))
    except portfolio.HistoryUnavailable as exc:
        return {**empty, "reason": str(exc)}
    series = [p for p in series if p["date"] <= end.isoformat()]
    if not series:
        return {**empty, "status": "no_positions" if start else "history_unavailable",
                "reason": "No portfolio value history available for the requested dates."}
    fin, fout = _daily_flows(trades, dividends, market)

    # Two weeks means opening value at the close 14 calendar days ago, not
    # all-time performance or the last two available points. A weekend or
    # holiday uses the preceding close, whose actual date is reported.
    before = [p for p in series if start and p["date"] <= start.isoformat()]
    if before:
        base = before[-1]
    elif start and not any(t.trade_date <= start for t in mtrades):
        base = {"date": start.isoformat(), "total": 0.0}
    else:
        base = series[0]
    days_in_window = [p for p in series if p["date"] > base["date"]]
    if not days_in_window:
        return {**empty, "status": "insufficient_history",
                "reason": "Opening and closing valuations are unavailable for this window."}
    window = days_in_window

    # --- TWR: chain daily returns with flows neutralized ------------------
    twr = 1.0
    prev = base["total"]
    prev_date = base["date"]
    curve: list[dict] = [{"date": base["date"], "pct": 0.0}]
    for p in days_in_window:
        d = p["date"]
        # Records can be dated on weekends/holidays. Include all cash flows
        # since the preceding valuation rather than losing those payments.
        incoming = sum(v for day, v in fin.items() if prev_date < day <= d)
        outgoing = sum(v for day, v in fout.items() if prev_date < day <= d)
        denom = prev + incoming
        if denom > 1e-9:
            r = (p["total"] + outgoing) / denom - 1.0
            twr *= 1.0 + r
        curve.append({"date": d, "pct": round((twr - 1.0) * 100, 3)})
        prev = p["total"]
        prev_date = d

    twr_pct = (twr - 1.0) * 100
    d0 = datetime.strptime(base["date"], "%Y-%m-%d").date()
    d1 = datetime.strptime(window[-1]["date"], "%Y-%m-%d").date()
    span_days = max((d1 - d0).days, 1)
    twr_annualized = (
        (twr ** (365.0 / span_days) - 1.0) * 100 if span_days >= 360 else None
    )

    # --- XIRR over the same window ----------------------------------------
    xflows: list[tuple[date, float]] = []
    if base["total"] > 0:  # opening position is bought at its opening valuation
        xflows.append((d0, -base["total"]))
    for d in sorted(set(fin) | set(fout)):
        if not base["date"] < d <= window[-1]["date"]:
            continue
        net = fout.get(d, 0.0) - fin.get(d, 0.0)
        if abs(net) > 1e-9:
            xflows.append((datetime.strptime(d, "%Y-%m-%d").date(), net))
    xflows.append((d1, window[-1]["total"]))
    xflows.sort(key=lambda f: f[0])
    xirr = _xirr(xflows)

    # --- Period P/L (value change net of contributions) --------------------
    contrib = sum(v for d, v in fin.items() if base["date"] < d <= window[-1]["date"])
    taken = sum(v for d, v in fout.items() if base["date"] < d <= window[-1]["date"])
    period_pl = window[-1]["total"] - base["total"] - contrib + taken

    # --- Benchmark, normalized to the portfolio window's first day ---------
    bars = stock_info.get_history(bench_symbol,
                                  start_date=(d0 - timedelta(days=14)).isoformat(),
                                  end_date=d1.isoformat())
    bbars = [b for b in bars if b["date"] <= d1.isoformat() and b.get("close")]
    bbase = [b for b in bbars if b["date"] <= base["date"]]
    bench_series: list[dict] = []
    bench_return = None
    if bbase:
        bbars = [bbase[-1]] + [b for b in bbars if b["date"] > base["date"]]
    if bbase and len(bbars) >= 2:
        b0 = bbase[-1]["close"]
        bench_series = [
            {"date": b["date"], "pct": round((b["close"] / b0 - 1.0) * 100, 3)}
            for b in bbars
        ]
        bench_return = bench_series[-1]["pct"]

    # --- Monthly P/L (期間績效), newest last, capped at 24 months ----------
    # Each month's P&L is measured over the interval actually charted for it:
    # (previous charted day, this month's last charted day]. Two things depend
    # on that bound:
    #   * The FIRST month is usually partial (a 3mo window starts mid-month), so
    #     summing the whole calendar month's flows would subtract buys made
    #     before the window even opened — a phantom loss the size of those buys.
    #   * The 24-month cap must not reset the baseline: prev_end/prev_date chain
    #     through EVERY month and only the last 24 are emitted, so the oldest
    #     surviving bar is still measured against the month before it.
    monthly: list[dict] = []
    month_points: dict[str, list[dict]] = defaultdict(list)
    for p in days_in_window:
        month_points[p["date"][:7]].append(p)
    all_months = sorted(month_points)
    emit_from = len(all_months) - 24
    prev_end = base["total"]
    prev_date = base["date"]
    for i, month in enumerate(all_months):
        pts = month_points[month]
        end_date = pts[-1]["date"]
        m_fin = sum(v for d, v in fin.items() if prev_date < d <= end_date)
        m_fout = sum(v for d, v in fout.items() if prev_date < d <= end_date)
        pl = pts[-1]["total"] - prev_end - m_fin + m_fout
        invested = prev_end + m_fin
        if i >= emit_from:
            monthly.append(
                {
                    "month": month,
                    "pl": round(pl, 2),
                    "return_pct": round(pl / invested * 100, 2) if invested > 1e-9 else None,
                }
            )
        prev_end = pts[-1]["total"]
        prev_date = end_date

    return {
        "market": market,
        "currency": quotes.currency_of(market),
        "period": period,
        "requested_start_date": start.isoformat() if start else None,
        "requested_end_date": end.isoformat(),
        "start_date": d0.isoformat(),
        "end_date": d1.isoformat(),
        "status": "ok",
        "opening_value": base["total"],
        "closing_value": window[-1]["total"],
        "contributions": round(contrib, 2),
        "withdrawals": round(taken, 2),
        "twr_pct": round(twr_pct, 2),
        "twr_annualized_pct": round(twr_annualized, 2) if twr_annualized is not None else None,
        "xirr_pct": round(xirr * 100, 2) if xirr is not None else None,
        "period_pl": round(period_pl, 2),
        "portfolio_series": curve,
        "benchmark": {
            "symbol": bench_symbol,
            "name": bench_name,
            "return_pct": bench_return,
            "series": bench_series,
        },
        "monthly": monthly,
    }
