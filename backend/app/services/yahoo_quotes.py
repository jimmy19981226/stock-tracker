"""Yahoo Finance quote fallback.

TWSE MIS (see ``tw_quotes.py``) gives true real-time prices but refuses
requests from many overseas / cloud datacenter IPs — so a backend hosted on
Render/Fly/etc. gets nothing from it. Yahoo's chart endpoint works from those
IPs (it's the same source ``yfinance`` uses for history/fundamentals), so we
use it to fill in any quotes MIS couldn't return.

Trade-off: Yahoo TW quotes are lightly delayed vs MIS's ~5s, so this is a
fallback, not the primary source. Results are cached longer than the MIS cache
to stay well clear of Yahoo rate limits even while the dashboard polls.
"""
from __future__ import annotations

import json
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from threading import Lock
from typing import Iterable

from .quotes import QuoteData, resolve_symbol

_CHART = "https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range=1d"
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
}
_TTL_SECONDS = 30.0  # longer than MIS's 5s — Yahoo data is delayed anyway
_cache: dict[str, tuple[float, QuoteData]] = {}
_lock = Lock()


def _fetch_meta(sym: str) -> dict | None:
    url = _CHART.format(sym=sym)
    try:
        req = urllib.request.Request(url, headers=_HEADERS)
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None
    result = (data.get("chart") or {}).get("result") or []
    if not result:
        return None
    meta = result[0].get("meta") or {}
    return meta if meta.get("regularMarketPrice") is not None else None


def _fetch_one(bare: str) -> QuoteData | None:
    # TSE stocks are <code>.TW on Yahoo; TPEx/OTC are <code>.TWO. We don't
    # know which a code is, so try .TW then fall back to .TWO.
    meta = _fetch_meta(f"{bare}.TW") or _fetch_meta(f"{bare}.TWO")
    if meta is None:
        return None

    def _f(key: str) -> float | None:
        v = meta.get(key)
        try:
            return float(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    vol_raw = meta.get("regularMarketVolume")
    try:
        volume = int(vol_raw) if vol_raw is not None else None
    except (TypeError, ValueError):
        volume = None

    return QuoteData(
        symbol=resolve_symbol(bare),
        price=_f("regularMarketPrice"),
        previous_close=_f("chartPreviousClose") or _f("previousClose"),
        currency=meta.get("currency") or "TWD",
        name=meta.get("shortName") or meta.get("longName") or "",
        day_open=_f("regularMarketOpen"),
        day_high=_f("regularMarketDayHigh"),
        day_low=_f("regularMarketDayLow"),
        volume=volume,
    )


def get_quotes(bares: Iterable[str]) -> dict[str, QuoteData]:
    """Quotes for bare TW codes (e.g. ``2330``), keyed by the bare code."""
    bares = list(dict.fromkeys(bares))  # de-dupe, keep order
    now = time.time()
    out: dict[str, QuoteData] = {}
    misses: list[str] = []
    with _lock:
        for b in bares:
            c = _cache.get(b)
            if c and now - c[0] < _TTL_SECONDS:
                out[b] = c[1]
            else:
                misses.append(b)

    if misses:
        with ThreadPoolExecutor(max_workers=6) as ex:
            for b, q in zip(misses, ex.map(_fetch_one, misses)):
                if q is not None and q.price is not None:
                    out[b] = q
        with _lock:
            for b in misses:
                if b in out:
                    _cache[b] = (now, out[b])

    return out
