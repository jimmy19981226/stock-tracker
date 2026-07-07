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
import os
import re
import time
import urllib.parse
import urllib.request
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Lock
from typing import Iterable

from .quotes import QuoteData, resolve_symbol
from . import markets


_TAIPEI = timezone(timedelta(hours=8))


def _is_tw_market_open(now: datetime | None = None) -> bool:
    """Whether the TW market is currently in session — its hours/holidays now
    live in the DB (see services/markets.py). Used to decide whether MIS's `y`
    field is yesterday's close (during session) vs today's rolled-over close."""
    return markets.is_market_open("TW", now)


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

# Persist `_last_good` so a process restart doesn't lose the prior-session
# close. Without this, a fresh process queried outside market hours has an
# empty cache and falls back to MIS's rolled `y` (= today's close), making
# "today's move" read 0. The file lives beside the DB and is gitignored.
_LAST_GOOD_FILE = Path(__file__).resolve().parents[2] / "data" / "last_good_quotes.json"
_SAVE_INTERVAL = 60.0
_last_save = 0.0


def _load_last_good() -> None:
    try:
        with open(_LAST_GOOD_FILE, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except (FileNotFoundError, ValueError, OSError):
        return
    for bare, d in (raw or {}).items():
        try:
            _last_good[bare] = QuoteData(**d)
        except (TypeError, ValueError):
            continue


def _save_last_good(now: float) -> None:
    """Throttled, best-effort snapshot of `_last_good` to disk."""
    global _last_save
    if now - _last_save < _SAVE_INTERVAL:
        return
    _last_save = now
    with _lock:
        snapshot = {b: asdict(q) for b, q in _last_good.items()}
    try:
        _LAST_GOOD_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = _LAST_GOOD_FILE.with_name(_LAST_GOOD_FILE.name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(snapshot, f)
        os.replace(tmp, _LAST_GOOD_FILE)
    except OSError:
        pass


_load_last_good()


def _bare(ticker: str) -> str:
    """Strip ``.TW``/``.TWO`` suffix to get the bare numeric code. Dots in
    US symbols (``BRK.B``) are kept — they'd fail ``_is_tw`` either way."""
    t = ticker.strip().upper()
    base, _, suffix = t.partition(".")
    return base if suffix in ("TW", "TWO") else t


def _is_tw(bare: str) -> bool:
    return bool(_TICKER_RE.match(bare))


def probe(timeout: float = 6.0) -> bool:
    """One uncached MIS round-trip: can this process reach MIS *right now*?

    Bypasses the quote caches (including the persisted last-good snapshot) so
    the answer reflects current reachability, not history. Used by the
    /api/quotes/sources availability endpoint.
    """
    params = {
        "ex_ch": "tse_2330.tw",
        "json": "1",
        "delay": "0",
        "_": str(int(time.time() * 1000)),
    }
    url = f"{_MIS_URL}?{urllib.parse.urlencode(params)}"
    try:
        req = urllib.request.Request(url, headers=_HEADERS)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return False
    return bool(payload.get("msgArray"))


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
        with _lock:
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

        # Capture other live fields from the same MIS payload. They use the
        # same "0.0000 = placeholder" convention so we filter zeros.
        day_open = _pos_float(item.get("o") or "")
        day_high = _pos_float(item.get("h") or "")
        day_low = _pos_float(item.get("l") or "")
        bid = _pos_float(_first_token(item.get("b") or ""))
        ask = _pos_float(_first_token(item.get("a") or ""))
        volume_raw = (item.get("v") or "").strip()
        try:
            volume: int | None = int(float(volume_raw)) if volume_raw and volume_raw != "-" else None
        except ValueError:
            volume = None

        q = QuoteData(
            symbol=resolve_symbol(bare),
            price=price,
            previous_close=prev,
            currency="TWD",
            name=n or (last.name if last else ""),
            day_open=day_open or (last.day_open if last else None),
            day_high=day_high or (last.day_high if last else None),
            day_low=day_low or (last.day_low if last else None),
            bid=bid,
            ask=ask,
            volume=volume if volume is not None else (last.volume if last else None),
        )
        with _lock:
            _last_good[bare] = q
        fresh[bare] = q

    with _lock:
        for bare, q in fresh.items():
            _cache[bare] = (now, q)
            for original in bare_to_originals.get(bare, []):
                out[original] = q

    if fresh:
        _save_last_good(now)

    return out
