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


def _bare(ticker: str) -> str:
    t = ticker.strip().upper()
    return t.split(".", 1)[0] if "." in t else t


def get_quote(ticker: str) -> QuoteData | None:
    return get_quotes([ticker]).get(ticker)


def get_quotes(tickers: Iterable[str]) -> dict[str, QuoteData]:
    # Lazy imports avoid a circular dependency at module load time.
    from . import quote_relay_client, tw_quotes, yahoo_quotes

    tickers = list(tickers)
    out: dict[str, QuoteData] = {}

    # 1) Real-time via an out-of-cloud relay on a Taiwan connection, if one is
    #    configured (QUOTE_RELAY_URL). This is how a cloud-hosted backend gets
    #    live MIS prices despite TWSE blocking its IP. No-op when unset.
    if quote_relay_client.configured():
        out.update(quote_relay_client.get_quotes(tickers))

    # 2) Direct TWSE MIS — real-time when this process itself runs on a TW IP
    #    (e.g. local dev); a silent no-op on an IP MIS blocks.
    still = [t for t in tickers if t not in out]
    if still:
        out.update(tw_quotes.get_quotes(still))

    # 3) Fill anything still missing from Yahoo (delayed), keyed by bare code so
    #    "2330" and "2330.TW" share one fetch.
    missing: dict[str, list[str]] = {}
    for t in tickers:
        if t not in out:
            b = _bare(t)
            if _TW_NUMERIC.match(b):
                missing.setdefault(b, []).append(t)
    if missing:
        yq = yahoo_quotes.get_quotes(missing.keys())
        for bare, originals in missing.items():
            q = yq.get(bare)
            if q is not None:
                for original in originals:
                    out[original] = q

    return out
