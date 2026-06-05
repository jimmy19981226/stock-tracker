"""Quote service — Taiwan + US equities.

Live prices for TWSE / TPEx tickers via the TWSE MIS endpoint
(see ``tw_quotes.py``); US tickers (and any quote MIS can't serve) fall back
to Yahoo (see ``yahoo_quotes.py``). A ticker's market is inferred from its
format: bare 4-6 digit codes are Taiwan (TWD), letter symbols are US (USD).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable


_TW_NUMERIC = re.compile(r"^\d{4,6}[A-Z]?$")


def market_of(ticker: str) -> str:
    """Infer the market ("TW" or "US") from a ticker's format.

    TW codes are numeric (``2330``, ``00919``, ``00937B``); US tickers are
    letter-based (``AAPL``, ``BRK.B``). Used as the default for the form's
    market picker and to classify tickers with no stored market row.
    """
    return "TW" if _TW_NUMERIC.match(_bare(ticker)) else "US"


def currency_of(market: str) -> str:
    """The reporting currency for a market: TW → TWD, US → USD."""
    return "USD" if (market or "").upper() == "US" else "TWD"


def resolve_symbol(ticker: str) -> str:
    """Map a user-entered ticker to its Yahoo-style symbol form.

    Bare 4-6 digit codes (e.g. ``2330``, ``00937B``) get a ``.TW`` suffix.
    US / already-qualified tickers are returned as-is in upper case.
    """
    t = ticker.strip().upper()
    if _TW_NUMERIC.match(t):
        return f"{t}.TW"
    return t


def detect_currency(ticker: str) -> str:
    """Currency for a ticker, inferred from its market. Tolerates either a
    bare code or an already-resolved symbol (e.g. ``2330.TW``)."""
    return currency_of(market_of(ticker))


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
    #    "2330" and "2330.TW" share one fetch. This now covers US tickers too —
    #    yahoo_quotes resolves the right symbol per market (.TW for TW, bare for
    #    US), so this is the primary source for US quotes (MIS is TW-only).
    missing: dict[str, list[str]] = {}
    for t in tickers:
        if t not in out:
            missing.setdefault(_bare(t), []).append(t)
    if missing:
        yq = yahoo_quotes.get_quotes(missing.keys())
        for bare, originals in missing.items():
            q = yq.get(bare)
            if q is not None:
                for original in originals:
                    out[original] = q

    return out
