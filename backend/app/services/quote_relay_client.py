"""Client for an out-of-cloud quote relay.

TWSE MIS refuses requests from many cloud / datacenter IPs, so a hosted
backend can't fetch real-time prices directly. If ``QUOTE_RELAY_URL`` points
at a relay running on a Taiwan connection (see ``backend/quote_relay.py``),
this fetches live quotes through it. On any error it returns ``{}`` so
``quotes.get_quotes`` silently drops to the Yahoo fallback.
"""
from __future__ import annotations

import json
import os
import time
import urllib.parse
import urllib.request
from typing import Iterable

from .quotes import QuoteData

# Short cloud-side cache so a burst of internal calls within one poll cycle
# doesn't make repeated round-trips to the relay; the relay itself caches MIS.
_TTL_SECONDS = 4.0
_cache: dict[str, tuple[float, QuoteData]] = {}


def configured() -> bool:
    return bool(os.environ.get("QUOTE_RELAY_URL"))


def _opt_float(v) -> float | None:
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _opt_int(v) -> int | None:
    try:
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _parse(raw: dict) -> QuoteData | None:
    price = _opt_float(raw.get("price"))
    if price is None:
        return None
    return QuoteData(
        symbol=raw.get("symbol") or "",
        price=price,
        previous_close=_opt_float(raw.get("previous_close")),
        currency=raw.get("currency") or "TWD",
        name=raw.get("name") or "",
        day_open=_opt_float(raw.get("day_open")),
        day_high=_opt_float(raw.get("day_high")),
        day_low=_opt_float(raw.get("day_low")),
        bid=_opt_float(raw.get("bid")),
        ask=_opt_float(raw.get("ask")),
        volume=_opt_int(raw.get("volume")),
    )


def get_quotes(tickers: Iterable[str]) -> dict[str, QuoteData]:
    base = os.environ.get("QUOTE_RELAY_URL")
    if not base:
        return {}

    tickers = list(dict.fromkeys(tickers))  # de-dupe, keep order
    now = time.time()
    out: dict[str, QuoteData] = {}
    misses: list[str] = []
    for t in tickers:
        c = _cache.get(t)
        if c and now - c[0] < _TTL_SECONDS:
            out[t] = c[1]
        else:
            misses.append(t)
    if not misses:
        return out

    url = base.rstrip("/") + "/quotes?" + urllib.parse.urlencode(
        {"codes": ",".join(misses)}
    )
    headers = {"User-Agent": "stock-tracker-relay-client"}
    secret = os.environ.get("QUOTE_RELAY_SECRET")
    if secret:
        headers["X-Relay-Secret"] = secret

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=6) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return out  # relay down/slow → caller falls back to Yahoo

    quotes = payload.get("quotes") or {}
    for t in misses:
        q = _parse(quotes.get(t) or {})
        if q is not None:
            out[t] = q
            _cache[t] = (now, q)
    return out
