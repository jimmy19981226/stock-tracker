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

from collections import defaultdict
from datetime import date, datetime
from typing import Iterable

import time
from threading import Lock

from sqlalchemy.orm import Session

from ..database import Dividend, Trade
from . import portfolio, quotes, stock_info

BENCHMARKS = {"TW": ("^TWII", "加權指數"), "US": ("^GSPC", "S&P 500")}

# The first build triggers the full value-history sweep (one yfinance "max"
# fetch per ticker ever traded) — minutes on a throttled cloud IP. Cache the
# finished report per (user, market, period) so only the first hit pays.
_CACHE_TTL = 900.0
_cache: dict[tuple[str, str, str], tuple[float, dict]] = {}
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


def build_performance(db: Session, user_id: str, market: str, period: str) -> dict:
    key = (user_id, market, period)
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < _CACHE_TTL:
            return hit[1]
    result = _build(db, user_id, market, period)
    # Never cache an empty report — that's a failed value-history build
    # (throttled Yahoo), not a fact.
    if result["portfolio_series"]:
        with _cache_lock:
            _cache[key] = (now, result)
    return result


def _build(db: Session, user_id: str, market: str, period: str) -> dict:
    bench_symbol, bench_name = BENCHMARKS.get(market, BENCHMARKS["US"])
    empty = {
        "market": market,
        "currency": quotes.currency_of(market),
        "period": period,
        "twr_pct": None,
        "twr_annualized_pct": None,
        "xirr_pct": None,
        "period_pl": None,
        "portfolio_series": [],
        "benchmark": {"symbol": bench_symbol, "name": bench_name,
                      "return_pct": None, "series": []},
        "monthly": [],
    }

    series = portfolio.build_value_history(db, user_id, market, "max")
    if len(series) < 2:
        return empty

    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    dividends = db.query(Dividend).filter(Dividend.user_id == user_id).all()
    fin, fout = _daily_flows(trades, dividends, market)

    start_iso = portfolio._window_start(period)
    window = [p for p in series if p["date"] >= start_iso]
    if len(window) < 2:
        window = series[-2:]
    # Base = last value before the window (so the first windowed day's move
    # counts); if the portfolio started inside the window, its first day is
    # the base instead.
    before = [p for p in series if p["date"] < window[0]["date"]]
    base = before[-1] if before else window[0]
    days_in_window = window[1:] if base is window[0] else window

    # --- TWR: chain daily returns with flows neutralized ------------------
    twr = 1.0
    prev = base["total"]
    curve: list[dict] = [{"date": base["date"], "pct": 0.0}]
    for p in days_in_window:
        d = p["date"]
        denom = prev + fin.get(d, 0.0)
        if denom > 1e-9:
            r = (p["total"] + fout.get(d, 0.0)) / denom - 1.0
            twr *= 1.0 + r
        curve.append({"date": d, "pct": round((twr - 1.0) * 100, 3)})
        prev = p["total"]

    twr_pct = (twr - 1.0) * 100
    d0 = datetime.strptime(base["date"], "%Y-%m-%d").date()
    d1 = datetime.strptime(window[-1]["date"], "%Y-%m-%d").date()
    span_days = max((d1 - d0).days, 1)
    twr_annualized = (
        (twr ** (365.0 / span_days) - 1.0) * 100 if span_days >= 360 else None
    )

    # --- XIRR over the same window ----------------------------------------
    xflows: list[tuple[date, float]] = []
    if before:  # opening position counts as buying the portfolio at the start
        xflows.append((d0, -base["total"]))
    for p in days_in_window:
        d = p["date"]
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
    bars = stock_info.get_history(bench_symbol, "max")
    bbars = [b for b in bars if b["date"] >= base["date"] and b.get("close")]
    bench_series: list[dict] = []
    bench_return = None
    if len(bbars) >= 2:
        b0 = bbars[0]["close"]
        bench_series = [
            {"date": b["date"], "pct": round((b["close"] / b0 - 1.0) * 100, 3)}
            for b in bbars
        ]
        bench_return = bench_series[-1]["pct"]

    # --- Monthly P/L (期間績效), newest last, capped at 24 months ----------
    monthly: list[dict] = []
    month_points: dict[str, list[dict]] = defaultdict(list)
    for p in days_in_window:
        month_points[p["date"][:7]].append(p)
    prev_end = base["total"]
    for month in sorted(month_points)[-24:]:
        pts = month_points[month]
        m_fin = sum(v for d, v in fin.items() if d[:7] == month)
        m_fout = sum(v for d, v in fout.items() if d[:7] == month)
        pl = pts[-1]["total"] - prev_end - m_fin + m_fout
        invested = prev_end + m_fin
        monthly.append(
            {
                "month": month,
                "pl": round(pl, 2),
                "return_pct": round(pl / invested * 100, 2) if invested > 1e-9 else None,
            }
        )
        prev_end = pts[-1]["total"]

    return {
        "market": market,
        "currency": quotes.currency_of(market),
        "period": period,
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
