"""Near-real-time TW quotes via the TWSE MIS endpoint.

The MIS (Market Information System) endpoint at
https://mis.twse.com.tw/stock/api/getStockInfo.jsp is the same one TWSE's
own website uses. It updates every ~5 seconds during market hours
(09:00-13:30 TW time, weekdays) and returns the previous close outside
those hours.

We try both ``tse_`` and ``otc_`` prefixes per ticker in a single batched
HTTP call so callers don't have to know which exchange a ticker is
listed on. All errors are silenced — the caller is expected to fall
back to yfinance.
"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from threading import Lock
from typing import Iterable

from .quotes import QuoteData, resolve_symbol


_MIS_URL = "https://mis.twse.com.tw/stock/api/getStockInfo.jsp"
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    "Referer": "https://mis.twse.com.tw/stock/index.jsp",
}
_TTL_SECONDS = 5.0
_TICKER_RE = re.compile(r"^\d{4,6}[A-Z]?$")

_cache: dict[str, tuple[float, QuoteData]] = {}
_lock = Lock()


def _bare(ticker: str) -> str:
    """Strip ``.TW``/``.TWO`` suffix to get the bare numeric code."""
    t = ticker.strip().upper()
    return t.split(".", 1)[0] if "." in t else t


def _is_tw(bare: str) -> bool:
    return bool(_TICKER_RE.match(bare))


def get_quote(ticker: str) -> QuoteData | None:
    return get_quotes([ticker]).get(ticker)


def get_quotes(tickers: Iterable[str]) -> dict[str, QuoteData]:
    """Return live TW quotes keyed by the original input strings.

    Non-TW or unknown tickers are silently dropped from the output —
    callers should fall back to yfinance for anything missing.
    """
    now = time.time()

    # Map bare codes back to the original ticker strings the caller used,
    # so e.g. both "2330" and "2330.TW" can resolve to the same fetch.
    bare_to_originals: dict[str, list[str]] = {}
    for t in tickers:
        b = _bare(t)
        if _is_tw(b):
            bare_to_originals.setdefault(b, []).append(t)

    if not bare_to_originals:
        return {}

    out: dict[str, QuoteData] = {}
    misses: list[str] = []
    with _lock:
        for bare in bare_to_originals:
            cached = _cache.get(bare)
            if cached and now - cached[0] < _TTL_SECONDS:
                for original in bare_to_originals[bare]:
                    out[original] = cached[1]
            else:
                misses.append(bare)

    if not misses:
        return out

    parts: list[str] = []
    for bare in misses:
        parts.append(f"tse_{bare}.tw")
        parts.append(f"otc_{bare}.tw")
    params = {
        "ex_ch": "|".join(parts),
        "json": "1",
        "delay": "0",
        "_": str(int(now * 1000)),
    }
    url = f"{_MIS_URL}?{urllib.parse.urlencode(params)}"

    try:
        req = urllib.request.Request(url, headers=_HEADERS)
        with urllib.request.urlopen(req, timeout=8) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return out  # silent failure; caller falls back

    fresh: dict[str, QuoteData] = {}
    for item in payload.get("msgArray", []) or []:
        bare = (item.get("c") or "").strip()
        if not bare:
            continue
        z = (item.get("z") or "").strip()  # last trade price
        y = (item.get("y") or "").strip()  # yesterday's close
        try:
            price: float | None = (
                float(z) if z and z != "-" else (float(y) if y and y != "-" else None)
            )
            prev: float | None = float(y) if y and y != "-" else None
        except ValueError:
            continue
        if price is None:
            continue
        fresh[bare] = QuoteData(
            symbol=resolve_symbol(bare),
            price=price,
            previous_close=prev,
            currency="TWD",
            name=(item.get("n") or "").strip(),
        )

    with _lock:
        for bare, q in fresh.items():
            _cache[bare] = (now, q)
            for original in bare_to_originals.get(bare, []):
                out[original] = q

    return out
