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
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from threading import Lock
from typing import Iterable

from .quotes import QuoteData, market_of, resolve_symbol

_TAIPEI = timezone(timedelta(hours=8))

_CHART = "https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range=1d"
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
}
# Short cache so on-screen prices stay close to the broker. Yahoo's US quotes
# are near-real-time, so the main lag is this cache. 5s matches the frontend's
# in-session poll cadence, so prices refresh on essentially every poll. Only
# open US tickers hit Yahoo (TW uses the relay/MIS), so this stays within rate
# limits — the one exception is if the TW relay is down and TW also falls back
# to Yahoo, which adds more tickers to each fetch.
_TTL_SECONDS = 5.0
_cache: dict[str, tuple[float, QuoteData]] = {}
_lock = Lock()


def _fetch_meta(sym: str) -> dict | None:
    # Index symbols carry a caret (^TWII, ^GSPC) — encode it for the URL path.
    url = _CHART.format(sym=urllib.parse.quote(sym, safe=""))
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
    is_tw = market_of(bare) == "TW"
    if is_tw:
        # TSE stocks are <code>.TW on Yahoo; TPEx/OTC are <code>.TWO. We don't
        # know which a code is, so try .TW then fall back to .TWO.
        meta = _fetch_meta(f"{bare}.TW") or _fetch_meta(f"{bare}.TWO")
    else:
        # US (and other already-qualified) symbols are fetched as-is. Class
        # shares are dashed on Yahoo (BRK-B), while brokers print them dotted
        # (BRK.B) — fall back to the dashed form when the dotted one misses.
        meta = _fetch_meta(bare)
        if meta is None and "." in bare and not bare.startswith("^"):
            meta = _fetch_meta(bare.replace(".", "-"))
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

    price = _f("regularMarketPrice")
    prev_close = _f("previousClose") or _f("chartPreviousClose")

    # Staleness guard: Yahoo's TW feed is delayed and, for the first ~15-30 min
    # of a session, can still serve the *previous* day's snapshot whole — both
    # price and prev-close a day behind. Computing "today's change" from that
    # mislabels yesterday's full-day move as today's. If the snapshot predates
    # the current Taipei trading day, treat it as flat (prev = price) until
    # fresh intraday data arrives, rather than showing a wrong non-zero move.
    mkt_time = meta.get("regularMarketTime")
    if is_tw and mkt_time is not None and price is not None:
        try:
            snap_date = (
                datetime.fromtimestamp(int(mkt_time), tz=timezone.utc)
                .astimezone(_TAIPEI)
                .date()
            )
            today = datetime.now(timezone.utc).astimezone(_TAIPEI).date()
            if snap_date < today:
                prev_close = price
        except (TypeError, ValueError, OverflowError, OSError):
            pass

    return QuoteData(
        symbol=resolve_symbol(bare),
        price=price,
        previous_close=prev_close,
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

    _overlay_live(out)
    return out


def _overlay_live(out: dict[str, QuoteData]) -> None:
    """Replace US prices with fresher WebSocket ticks (see live_quotes.py).

    Only while the US session is open — after the close, the REST snapshot's
    official close price is authoritative and the tick table goes stale.
    """
    us = [b for b in out if market_of(b) == "US"]
    if not us:
        return
    from . import live_quotes, markets

    if not markets.is_market_open("US"):
        return
    now = time.time()
    for b in us:
        tick = live_quotes.get(b)
        # 6.5h = one full US session; older ticks are a previous session's.
        if tick is None or now - tick.ts > 6.5 * 3600:
            continue
        q = out[b]
        out[b] = replace(
            q,
            price=tick.price,
            previous_close=tick.prev_close if tick.prev_close is not None else q.previous_close,
            volume=tick.day_volume if tick.day_volume is not None else q.volume,
        )
