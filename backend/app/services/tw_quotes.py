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
from datetime import datetime, timedelta, timezone
from threading import Lock
from typing import Iterable

from .quotes import QuoteData, resolve_symbol


_TAIPEI = timezone(timedelta(hours=8))


def _is_tw_market_open(now: datetime | None = None) -> bool:
    """09:00-13:30 Taipei time, Monday-Friday. Used to decide whether MIS's
    `y` field is yesterday's close (during session) vs today's close that
    has rolled over (after session)."""
    tw = (now or datetime.now(timezone.utc)).astimezone(_TAIPEI)
    if tw.weekday() >= 5:
        return False
    minutes = tw.hour * 60 + tw.minute
    return 9 * 60 <= minutes < 13 * 60 + 30


def _first_token(s: str) -> str:
    """MIS bid/ask fields look like 2300.0000_2305.0000_..._. Return the
    first token, stripped."""
    return s.strip().split("_", 1)[0].strip() if s else ""


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
# Long-lived "last good" snapshot per ticker. MIS returns z="-" between
# trades and rolls `y` to today's close after the session ends, so a naive
# read shows today_change = 0. We hold onto the most recent QuoteData where
# z was a real number (and y was still yesterday's close) and serve that
# whenever MIS gives us a degraded response.
_last_good: dict[str, QuoteData] = {}
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

    market_open = _is_tw_market_open()
    fresh: dict[str, QuoteData] = {}
    for item in payload.get("msgArray", []) or []:
        bare = (item.get("c") or "").strip()
        if not bare:
            continue
        z = (item.get("z") or "").strip()  # last trade price
        y = (item.get("y") or "").strip()  # yesterday's close (rolls after market close)
        n = (item.get("n") or "").strip()
        z_valid = z and z != "-"
        y_valid = y and y != "-"
        last = _last_good.get(bare)

        # Current price priority: z (live trade) → bid/ask midpoint
        # (between trades but session active) → today's open → cached last
        # good → y. MIS uses "0.0000" as a placeholder in some bid/ask
        # levels, so anything ≤ 0 is treated as invalid.
        def _pos_float(s: str) -> float | None:
            s = (s or "").strip()
            if not s or s == "-":
                return None
            try:
                v = float(s)
            except ValueError:
                return None
            return v if v > 0 else None

        price: float | None = _pos_float(z) if z_valid else None
        if price is None:
            a0 = _pos_float(_first_token(item.get("a") or ""))
            b0 = _pos_float(_first_token(item.get("b") or ""))
            if a0 is not None and b0 is not None:
                price = (a0 + b0) / 2
            elif a0 is not None:
                price = a0
            elif b0 is not None:
                price = b0
        if price is None:
            price = _pos_float(item.get("o") or "")
        if price is None and last is not None:
            price = last.price
        if price is None and y_valid:
            price = _pos_float(y)
        if price is None:
            continue

        # Previous close: trust y only during market hours (it rolls to
        # today's close after the session ends). Outside market hours,
        # prefer the cached value captured during the last session.
        prev: float | None = None
        if market_open and y_valid:
            try:
                prev = float(y)
            except ValueError:
                pass
        elif last is not None:
            prev = last.previous_close
        elif y_valid:
            try:
                prev = float(y)
            except ValueError:
                pass

        q = QuoteData(
            symbol=resolve_symbol(bare),
            price=price,
            previous_close=prev,
            currency="TWD",
            name=n or (last.name if last else ""),
        )
        _last_good[bare] = q
        fresh[bare] = q

    with _lock:
        for bare, q in fresh.items():
            _cache[bare] = (now, q)
            for original in bare_to_originals.get(bare, []):
                out[original] = q

    return out
