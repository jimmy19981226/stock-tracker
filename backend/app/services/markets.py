"""Market reference data — currency, session hours, and holiday closures —
read from the ``markets`` / ``market_holidays`` tables.

A small in-process cache (TTL) keeps hot quote paths from hitting the DB on
every call; ``invalidate()`` clears it after a holiday is added/removed.
"""
from __future__ import annotations

import time
from datetime import date, datetime, timezone
from threading import Lock
from zoneinfo import ZoneInfo

from ..database import Market, MarketHoliday, SessionLocal

_TTL_SECONDS = 3600.0  # config/holidays change rarely
_FALLBACK_CURRENCY = {"TW": "TWD", "US": "USD"}

_lock = Lock()
_cache: dict | None = None  # {"at": float, "markets": {code: {...}}, "holidays": {code: set[str]}}


def _load() -> dict:
    """Return the cached markets+holidays snapshot, refreshing from the DB when
    the TTL has elapsed. Falls back to a stale cache if the DB is unreachable."""
    global _cache
    now = time.time()
    with _lock:
        if _cache is not None and now - _cache["at"] < _TTL_SECONDS:
            return _cache

    markets: dict[str, dict] = {}
    holidays: dict[str, set[str]] = {}
    try:
        with SessionLocal() as db:
            for m in db.query(Market).order_by(Market.sort_order, Market.code).all():
                markets[m.code] = {
                    "code": m.code,
                    "name": m.name,
                    "currency": m.currency,
                    "timezone": m.timezone,
                    "open_minute": m.open_minute,
                    "close_minute": m.close_minute,
                    "sort_order": m.sort_order,
                }
                holidays[m.code] = set()
            for h in db.query(MarketHoliday).all():
                holidays.setdefault(h.market_code, set()).add(h.holiday_date.isoformat())
    except Exception:
        if _cache is not None:
            return _cache  # serve stale rather than nothing

    data = {"at": now, "markets": markets, "holidays": holidays}
    with _lock:
        _cache = data
    return data


def invalidate() -> None:
    """Drop the cache so the next read reloads from the DB (call after writes)."""
    global _cache
    with _lock:
        _cache = None


def all_markets() -> list[dict]:
    """Every market with its config + holiday list (ISO dates). For the API."""
    data = _load()
    out: list[dict] = []
    for code, m in sorted(
        data["markets"].items(), key=lambda kv: (kv[1]["sort_order"], kv[0])
    ):
        out.append({**m, "holidays": sorted(data["holidays"].get(code, set()))})
    return out


def currency_for(code: str) -> str:
    """Reporting currency for a market code; falls back to the TW/US default
    if the row is missing (e.g. cache not yet warmed)."""
    code = (code or "").upper()
    m = _load()["markets"].get(code)
    if m:
        return m["currency"]
    return _FALLBACK_CURRENCY.get(code, "TWD")


def holidays_for(code: str) -> set[str]:
    return set(_load()["holidays"].get((code or "").upper(), set()))


def is_holiday(code: str, d: date) -> bool:
    return d.isoformat() in _load()["holidays"].get((code or "").upper(), set())


def is_market_open(code: str, now: datetime | None = None) -> bool:
    """Is ``code``'s market open right now? Weekday + session hours in the
    market's own timezone, minus its holiday closures."""
    code = (code or "").upper()
    data = _load()
    m = data["markets"].get(code)
    if not m:
        return False
    when = now or datetime.now(timezone.utc)
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    try:
        local = when.astimezone(ZoneInfo(m["timezone"]))
    except Exception:
        return False
    if local.weekday() >= 5:  # Saturday / Sunday
        return False
    if local.date().isoformat() in data["holidays"].get(code, set()):
        return False
    minutes = local.hour * 60 + local.minute
    return m["open_minute"] <= minutes < m["close_minute"]
