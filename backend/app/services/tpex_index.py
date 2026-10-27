"""Official TPEx index quotes and monthly OHLC history for the app's ^TWOII ID.

Yahoo does not serve this index. MIS supplies intraday quotes; TPEx OpenAPI
supplies an explicitly dated closing quote when MIS is unavailable. Monthly
history comes from the official indexInfo/inx endpoint used by TPEx's site.
"""
from __future__ import annotations

import calendar
import json
import math
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from threading import Lock

from .quotes import QuoteData

SYMBOL = "^TWOII"
_HEADERS = {"User-Agent": "Mozilla/5.0", "Referer": "https://www.tpex.org.tw/"}
_cache: dict[str, tuple[float, object]] = {}
_lock = Lock()


def _fetch_json(url: str):
    request = urllib.request.Request(url, headers=_HEADERS)
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read().decode("utf-8"))


def _cached(url: str, ttl: float):
    now = time.monotonic()
    with _lock:
        prior = _cache.get(url)
        if prior and now - prior[0] < (min(ttl, 30) if prior[1] is None else ttl):
            return prior[1]
    try:
        value = _fetch_json(url)
    except Exception:
        value = None
    with _lock:
        _cache[url] = (now, value)
    return value


def _number(value) -> float | None:
    try:
        result = float(str(value).replace(",", "").strip())
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def _day(value) -> date | None:
    try:
        return date.fromisoformat(str(value).replace("/", "-").strip())
    except ValueError:
        return None


def get_quote() -> QuoteData | None:
    payload = _cached("https://mis.twse.com.tw/stock/api/getStockInfo.jsp?ex_ch=otc_o00.tw&json=1&delay=0", 30)
    rows = payload.get("msgArray") if isinstance(payload, dict) else None
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict) or row.get("ch") != "o00.tw":
            continue
        price, previous = _number(row.get("z")), _number(row.get("y"))
        day = _day(row.get("d"))
        if price is not None and price > 0 and day:
            previous = previous if previous is not None and previous > 0 else None
            return QuoteData(SYMBOL, price, previous, "TWD", "櫃買指數",
                             day_open=_number(row.get("o")), day_high=_number(row.get("h")),
                             day_low=_number(row.get("l")), as_of=day.isoformat() if day else None,
                             source="TWSE MIS")
    payload = _cached("https://www.tpex.org.tw/openapi/v1/tpex_index", 300)
    valid = []
    for row in payload if isinstance(payload, list) else []:
        if not isinstance(row, dict):
            continue
        day, close = _day(row.get("Date")), _number(row.get("Close"))
        if day and close is not None and close > 0:
            valid.append((day, close, row))
    if not valid:
        return None
    day, close, row = max(valid, key=lambda item: item[0])
    change = _number(row.get("Change"))
    previous = close - change if change is not None else None
    previous = previous if previous is not None and previous > 0 else None
    return QuoteData(SYMBOL, close, previous,
                     "TWD", "櫃買指數", day_open=_number(row.get("Open")),
                     day_high=_number(row.get("High")), day_low=_number(row.get("Low")),
                     as_of=day.isoformat(), source="TPEx close")


def _month_history(month: date) -> list[dict] | None:
    params = urllib.parse.urlencode({"date": month.strftime("%Y/%m/%d"), "response": "json"})
    url = "https://www.tpex.org.tw/www/en-us/indexInfo/inx?" + params
    current = datetime.now(timezone(timedelta(hours=8))).date().replace(day=1)
    payload = _cached(url, 300 if month == current else 86400)
    def unavailable():
        # Malformed responses must not poison historical months for a day.
        # Do not extend an existing negative entry on every polling request.
        if payload is not None:
            with _lock:
                _cache[url] = (time.monotonic(), None)
        return None

    tables = payload.get("tables") if isinstance(payload, dict) else None
    if not isinstance(tables, list) or not tables or payload.get("stat") != "ok":
        return unavailable()
    bars = []
    for table in tables:
        rows = table.get("data") if isinstance(table, dict) else None
        if not isinstance(rows, list):
            return unavailable()
        for row in rows:
            if not isinstance(row, list) or len(row) < 5:
                continue
            day, close = _day(row[0]), _number(row[4])
            if day is None or day.replace(day=1) != month or close is None or close <= 0:
                continue
            bars.append(dict(date=day.isoformat(), open=_number(row[1]), high=_number(row[2]),
                             low=_number(row[3]), close=close, volume=None))
    return bars


def get_history(period: str = "1mo", *, start_date: str | None = None,
                end_date: str | None = None) -> list[dict]:
    end = date.fromisoformat(end_date) if end_date else datetime.now(timezone(timedelta(hours=8))).date()
    if start_date:
        start = date.fromisoformat(start_date)
    else:
        months = {"1mo": 1, "3mo": 3, "6mo": 6, "1y": 12, "2y": 24, "5y": 60}.get(period)
        if months is None:
            return []  # Unbounded/max requests are unavailable, never a fabricated partial range.
        year, month = divmod(end.year * 12 + end.month - 1 - months, 12)
        start = date(year, month + 1, min(end.day, calendar.monthrange(year, month + 1)[1]))
    if start > end:
        return []
    cursor = start.replace(day=1)
    months = []
    while cursor <= end:
        months.append(cursor)
        if len(months) > 61:
            return []
        cursor = date(cursor.year + cursor.month // 12, cursor.month % 12 + 1, 1)
    with ThreadPoolExecutor(max_workers=min(4, len(months))) as pool:
        pages = list(pool.map(_month_history, months))
    if any(page is None for page in pages):
        return []  # Do not present a missing month as a complete requested range.
    bars = {bar["date"]: bar for page in pages for bar in page
            if start.isoformat() <= bar["date"] <= end.isoformat()}
    return [bars[day] for day in sorted(bars)]
