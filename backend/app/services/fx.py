"""USD↔TWD exchange rate for the combined net-worth view.

Yahoo serves the pair as ``TWD=X`` — units of TWD per 1 USD (e.g. ~32). We
cache it briefly in-process and persist the last good value in the Metadata
table, so a transient fetch failure still yields a (stale-but-labelled) rate
instead of blanking the combined total. Only when there is neither a live nor
a persisted value do we report "unavailable".
"""
from __future__ import annotations

import json
import time
import urllib.request
from datetime import datetime, timezone
from threading import Lock

from ..database import Metadata, SessionLocal

_CHART = (
    "https://query1.finance.yahoo.com/v8/finance/chart/TWD=X?interval=1d&range=1d"
)
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
}
_TTL_SECONDS = 300.0  # FX moves slowly; one fetch per 5 min is plenty
_META_KEY = "fx_usd_twd"

_lock = Lock()
_cache: tuple[float, float, str] | None = None  # (fetched_at, rate, asof_iso)


def _fetch_live() -> tuple[float, str] | None:
    try:
        req = urllib.request.Request(_CHART, headers=_HEADERS)
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None
    result = (data.get("chart") or {}).get("result") or []
    if not result:
        return None
    meta = result[0].get("meta") or {}
    try:
        rate = float(meta.get("regularMarketPrice"))
    except (TypeError, ValueError):
        return None
    if rate <= 0:
        return None
    ts = meta.get("regularMarketTime")
    try:
        asof = (
            datetime.fromtimestamp(int(ts), tz=timezone.utc).isoformat()
            if ts
            else datetime.now(timezone.utc).isoformat()
        )
    except (TypeError, ValueError, OSError, OverflowError):
        asof = datetime.now(timezone.utc).isoformat()
    return rate, asof


def _load_persisted() -> tuple[float, str] | None:
    try:
        with SessionLocal() as db:
            row = db.get(Metadata, _META_KEY)
            if row and row.value:
                payload = json.loads(row.value)
                asof = payload.get("asof") or row.updated_at.isoformat()
                return float(payload["rate"]), asof
    except Exception:
        return None
    return None


def _persist(rate: float, asof: str) -> None:
    try:
        with SessionLocal() as db:
            row = db.get(Metadata, _META_KEY)
            value = json.dumps({"rate": rate, "asof": asof})
            if row is None:
                db.add(Metadata(key=_META_KEY, value=value))
            else:
                row.value = value
            db.commit()
    except Exception:
        pass


def get_usd_twd() -> tuple[float | None, str | None]:
    """Return ``(rate, asof_iso)`` where ``rate`` is TWD per 1 USD.

    ``(None, None)`` only when there is no live value AND no persisted
    fallback — callers must treat that as "combined total unavailable"."""
    global _cache
    now = time.time()
    with _lock:
        if _cache and now - _cache[0] < _TTL_SECONDS:
            return _cache[1], _cache[2]

    live = _fetch_live()
    if live is not None:
        rate, asof = live
        _persist(rate, asof)
        with _lock:
            _cache = (now, rate, asof)
        return rate, asof

    # Live fetch failed — fall back to the last good value we stored.
    persisted = _load_persisted()
    if persisted is not None:
        return persisted
    return None, None
