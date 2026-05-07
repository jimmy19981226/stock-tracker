from __future__ import annotations

import re
import time
from dataclasses import dataclass
from datetime import date, timedelta
from threading import Lock
from typing import Iterable

import yfinance as yf


_TW_NUMERIC = re.compile(r"^\d{4,6}[A-Z]?$")
_QUOTE_TTL_SECONDS = 60.0
_HISTORY_TTL_SECONDS = 300.0


def resolve_symbol(ticker: str) -> str:
    """Map a user-entered ticker to the Yahoo Finance symbol.

    A bare 4-6 digit number (e.g. "2330") is treated as a Taiwan listing and
    suffixed with ``.TW``. Anything else (including ``2330.TW`` or ``AAPL``) is
    returned upper-cased.
    """
    t = ticker.strip().upper()
    if _TW_NUMERIC.match(t):
        return f"{t}.TW"
    return t


def detect_currency(symbol: str) -> str:
    if symbol.endswith(".TW") or symbol.endswith(".TWO"):
        return "TWD"
    return "USD"


@dataclass
class QuoteData:
    symbol: str
    price: float
    previous_close: float | None
    currency: str
    name: str = ""  # short name from the data source (e.g. "台積電")


_quote_cache: dict[str, tuple[float, QuoteData]] = {}
_history_cache: dict[tuple[str, str], tuple[float, list[tuple[date, float]]]] = {}
_lock = Lock()


def get_quote(ticker: str) -> QuoteData | None:
    """Return the latest quote for ``ticker`` or ``None`` if it cannot be fetched.

    Routes TW tickers through TWSE MIS first (near-real-time, ~5s cache);
    falls back to yfinance on miss/failure or for non-TW tickers.
    """
    symbol = resolve_symbol(ticker)
    if detect_currency(symbol) == "TWD":
        # Lazy import to avoid a circular dependency at module load time.
        from . import tw_quotes
        q = tw_quotes.get_quote(ticker)
        if q is not None:
            return q
    return _yfinance_quote(symbol)


def _yfinance_quote(symbol: str) -> QuoteData | None:
    now = time.time()
    with _lock:
        cached = _quote_cache.get(symbol)
        if cached and now - cached[0] < _QUOTE_TTL_SECONDS:
            return cached[1]

    try:
        tk = yf.Ticker(symbol)
        hist = tk.history(period="5d", auto_adjust=False)
        if hist.empty:
            return None
        last = hist.iloc[-1]
        prev = hist.iloc[-2] if len(hist) >= 2 else None
        data = QuoteData(
            symbol=symbol,
            price=float(last["Close"]),
            previous_close=float(prev["Close"]) if prev is not None else None,
            currency=detect_currency(symbol),
        )
    except Exception:
        return None

    with _lock:
        _quote_cache[symbol] = (now, data)
    return data


def get_quotes(tickers: Iterable[str]) -> dict[str, QuoteData]:
    """Batch-fetch quotes. TW tickers are batched into one MIS HTTP call.
    Anything MIS doesn't return (or non-TW tickers) goes through yfinance
    one at a time.
    """
    tickers = list(tickers)
    if not tickers:
        return {}

    out: dict[str, QuoteData] = {}

    # Group TW tickers and ask MIS in one shot.
    tw_tickers: list[str] = []
    other_tickers: list[str] = []
    for t in tickers:
        if detect_currency(resolve_symbol(t)) == "TWD":
            tw_tickers.append(t)
        else:
            other_tickers.append(t)

    if tw_tickers:
        from . import tw_quotes
        out.update(tw_quotes.get_quotes(tw_tickers))

    # Fall back to yfinance for anything missing.
    for t in other_tickers + [t for t in tw_tickers if t not in out]:
        q = _yfinance_quote(resolve_symbol(t))
        if q is not None:
            out[t] = q
    return out


def get_price_history(
    ticker: str, start: date, end: date | None = None
) -> list[tuple[date, float]]:
    """Daily close prices between ``start`` and ``end`` inclusive.

    Returns an empty list on failure.
    """
    symbol = resolve_symbol(ticker)
    end = end or date.today()
    cache_key = (symbol, f"{start.isoformat()}:{end.isoformat()}")
    now = time.time()

    with _lock:
        cached = _history_cache.get(cache_key)
        if cached and now - cached[0] < _HISTORY_TTL_SECONDS:
            return cached[1]

    try:
        tk = yf.Ticker(symbol)
        hist = tk.history(
            start=start.isoformat(),
            end=(end + timedelta(days=1)).isoformat(),
            auto_adjust=False,
        )
        if hist.empty:
            result: list[tuple[date, float]] = []
        else:
            result = [
                (idx.date(), float(row["Close"]))
                for idx, row in hist.iterrows()
            ]
    except Exception:
        result = []

    with _lock:
        _history_cache[cache_key] = (now, result)
    return result
