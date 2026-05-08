"""Quote service — Taiwan equities only.

Live prices for TWSE / TPEx tickers via the TWSE MIS endpoint
(see ``tw_quotes.py``). Tickers that don't match the TW pattern simply
return ``None`` — there's no US / yfinance fallback in this build.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable


_TW_NUMERIC = re.compile(r"^\d{4,6}[A-Z]?$")


def resolve_symbol(ticker: str) -> str:
    """Map a user-entered ticker to its Yahoo-style symbol form.

    Bare 4-6 digit codes (e.g. ``2330``, ``00937B``) get a ``.TW`` suffix.
    Anything already qualified is returned as-is in upper case.
    """
    t = ticker.strip().upper()
    if _TW_NUMERIC.match(t):
        return f"{t}.TW"
    return t


def detect_currency(_symbol: str) -> str:
    """Single-currency build — always TWD."""
    return "TWD"


@dataclass
class QuoteData:
    symbol: str
    price: float
    previous_close: float | None
    currency: str
    name: str = ""
    day_open: float | None = None
    day_high: float | None = None
    day_low: float | None = None
    bid: float | None = None
    ask: float | None = None
    volume: int | None = None


def get_quote(ticker: str) -> QuoteData | None:
    # Lazy import to avoid a circular dependency at module load time.
    from . import tw_quotes
    return tw_quotes.get_quote(ticker)


def get_quotes(tickers: Iterable[str]) -> dict[str, QuoteData]:
    from . import tw_quotes
    return tw_quotes.get_quotes(tickers)
