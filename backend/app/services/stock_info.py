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
from datetime import date, datetime, timezone
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


def _normalize_date(value: Any) -> str | None:
    """yfinance returns calendar dates as Unix-epoch ints, datetime/date
    objects, or already-formatted strings (and sometimes lists for ranged
    earnings estimates). Always return a single ISO date string or None."""
    if value is None:
        return None
    if isinstance(value, (list, tuple)) and value:
        # Earnings estimates often come as [start, end]; show the earliest.
        value = value[0]
    if isinstance(value, (datetime, date)):
        return (value.date() if isinstance(value, datetime) else value).isoformat()
    if isinstance(value, (int, float)):
        # Unix epoch seconds (sometimes ms — rough sanity threshold).
        try:
            secs = float(value)
            if secs > 1e12:  # likely ms
                secs /= 1000
            return datetime.fromtimestamp(secs, tz=timezone.utc).date().isoformat()
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        # Already an ISO date or datetime string?
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00")).date().isoformat()
        except ValueError:
            return s  # unrecognized but non-empty — pass through
    return None


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
    calendar: dict | None = None
    try:
        yt = _yticker(ticker)
        info = yt.info or {}
        # ticker.calendar holds the next earnings date (a dict with
        # "Earnings Date": [d1, d2]) when yfinance can find it. info's
        # "earningsDate" is unreliable — often missing for non-US tickers.
        try:
            cal = yt.calendar
            if isinstance(cal, dict):
                calendar = cal
        except Exception:
            calendar = None
    except Exception:
        info = {}

    # yfinance is inconsistent across versions about whether dividendYield
    # is returned as a decimal (0.01 = 1%) or a percentage (1.0 = 1%). Some
    # tickers also return 0 instead of None when there's no dividend.
    # Normalize: anything > 1 is treated as a percentage and divided by 100,
    # so callers can always do `value * 100` for display.
    raw_yield = info.get("dividendYield")
    if raw_yield is not None and raw_yield > 1:
        raw_yield = raw_yield / 100

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
        "dividend_yield": raw_yield,
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
        # Volume averages — Yahoo's "Avg. Volume" is the 3-month avg
        # (info["averageVolume"]); the 10-day version is also useful
        # for short-term context.
        "average_volume": info.get("averageVolume"),
        "average_volume_10d": info.get("averageVolume10days") or info.get("averageDailyVolume10Day"),
        # Calendar dates — yfinance returns these as ISO strings, ints
        # (Unix epoch in seconds), or datetime/date objects depending
        # on the ticker and version. Normalize all to ISO date strings.
        # Prefer ticker.calendar for earnings date (info field is often
        # missing on non-US tickers).
        "earnings_date": _normalize_date(
            (calendar or {}).get("Earnings Date")
            or info.get("earningsDate")
        ),
        "ex_dividend_date": _normalize_date(info.get("exDividendDate")),
        "last_dividend_date": _normalize_date(info.get("lastDividendDate")),
        # Analyst price targets
        "target_mean_price": info.get("targetMeanPrice"),
        "target_median_price": info.get("targetMedianPrice"),
        "target_high_price": info.get("targetHighPrice"),
        "target_low_price": info.get("targetLowPrice"),
        "analyst_count": info.get("numberOfAnalystOpinions"),
        "recommendation_mean": info.get("recommendationMean"),
        "recommendation_key": info.get("recommendationKey"),
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
