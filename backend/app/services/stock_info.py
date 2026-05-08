"""Per-stock fundamentals + historical prices via yfinance.

yfinance is used only for slow-moving data — fundamentals (P/E, market
cap, sector, etc.) and daily price history. Live intraday quotes still
go through TWSE MIS in ``tw_quotes.py``; yfinance prices for TW are
delayed and unsuitable for the dashboard.

All calls cache per-process so the per-stock detail page can be opened
many times without hammering yfinance. Fundamentals cache 1 hour;
history caches 30 minutes (so today's bar updates a few times during
the session); the latest day's bar is always extended on demand from
MIS so it reflects intraday movement, not yesterday's close.
"""
from __future__ import annotations

import time
from threading import Lock
from typing import Any

from .quotes import resolve_symbol


_FUNDAMENTALS_TTL = 3600.0   # 1 hour
_HISTORY_TTL = 1800.0        # 30 minutes

_fundamentals_cache: dict[str, tuple[float, dict]] = {}
_history_cache: dict[tuple[str, str], tuple[float, list[dict]]] = {}
_lock = Lock()


def _yticker(ticker: str):
    """Lazy-import yfinance so the module loads even if yfinance is missing."""
    import yfinance as yf

    return yf.Ticker(resolve_symbol(ticker))


def get_fundamentals(ticker: str) -> dict[str, Any]:
    """Return a small subset of yfinance ``info`` keys: market cap, P/E, EPS,
    dividend yield, 52-week range, sector, industry, name. Missing fields
    come back as ``None`` rather than absent."""
    now = time.time()
    sym = resolve_symbol(ticker)
    with _lock:
        cached = _fundamentals_cache.get(sym)
        if cached and now - cached[0] < _FUNDAMENTALS_TTL:
            return cached[1]

    info: dict = {}
    try:
        info = _yticker(ticker).info or {}
    except Exception:
        info = {}

    out = {
        "symbol": sym,
        "long_name": info.get("longName"),
        "short_name": info.get("shortName"),
        "sector": info.get("sector"),
        "industry": info.get("industry"),
        "market_cap": info.get("marketCap"),
        "currency": info.get("currency"),
        "pe": info.get("trailingPE") or info.get("forwardPE"),
        "forward_pe": info.get("forwardPE"),
        "eps": info.get("trailingEps"),
        "dividend_yield": info.get("dividendYield"),
        "dividend_rate": info.get("dividendRate"),
        "payout_ratio": info.get("payoutRatio"),
        "fifty_two_week_high": info.get("fiftyTwoWeekHigh"),
        "fifty_two_week_low": info.get("fiftyTwoWeekLow"),
        "fifty_day_avg": info.get("fiftyDayAverage"),
        "two_hundred_day_avg": info.get("twoHundredDayAverage"),
        "beta": info.get("beta"),
        "book_value": info.get("bookValue"),
        "price_to_book": info.get("priceToBook"),
        "shares_outstanding": info.get("sharesOutstanding"),
    }

    with _lock:
        _fundamentals_cache[sym] = (now, out)
    return out


def get_history(ticker: str, period: str = "1y") -> list[dict]:
    """Daily OHLCV bars for the requested period.

    period: yfinance shorthand — ``1mo``, ``3mo``, ``6mo``, ``1y``, ``2y``,
    ``5y``, ``max``. Returned as a list of
    ``{date, open, high, low, close, volume}`` dicts, oldest first.
    """
    now = time.time()
    sym = resolve_symbol(ticker)
    key = (sym, period)
    with _lock:
        cached = _history_cache.get(key)
        if cached and now - cached[0] < _HISTORY_TTL:
            return cached[1]

    try:
        df = _yticker(ticker).history(period=period, auto_adjust=False)
    except Exception:
        return []

    if df is None or df.empty:
        return []

    bars: list[dict] = []
    for idx, row in df.iterrows():
        try:
            bars.append({
                "date": idx.date().isoformat() if hasattr(idx, "date") else str(idx)[:10],
                "open": float(row.get("Open")) if row.get("Open") == row.get("Open") else None,
                "high": float(row.get("High")) if row.get("High") == row.get("High") else None,
                "low": float(row.get("Low")) if row.get("Low") == row.get("Low") else None,
                "close": float(row.get("Close")) if row.get("Close") == row.get("Close") else None,
                "volume": int(row.get("Volume")) if row.get("Volume") == row.get("Volume") else None,
            })
        except Exception:
            continue

    with _lock:
        _history_cache[key] = (now, bars)
    return bars


def get_taiex_history(period: str = "1y") -> list[dict]:
    """TAIEX (台股加權) daily history for benchmark comparison."""
    return get_history("^TWII", period)
