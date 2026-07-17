"""Market index strip API.

The iOS app pins a slim index bar across every tab of a market's pages
(dashboard, trades, dividends). Each user has a configurable list of Yahoo
index symbols; the defaults are the TAIEX for Taiwan and the S&P 500 for the
US. Any Yahoo symbol works (^IXIC, ^SOX, ^N225, …), so users can add whatever
they follow.

GET /api/indices  -> quotes for the caller's configured indices
PUT /api/indices  -> replace the caller's list (validated, capped)

The list is stored per user in the Metadata table (key ``indices:<user_id>``)
— a tiny bit of per-user config doesn't warrant its own table. US index
quotes additionally ride the live WebSocket (services/live_quotes.py), so the
strip ticks in real time while the US market is open.
"""
from __future__ import annotations

import json
import re
import time

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import Metadata, get_db
from ..services import live_quotes, quotes

router = APIRouter(prefix="/api/indices", tags=["indices"])

DEFAULT_INDICES = ["^TWII", "^GSPC"]
MAX_INDICES = 12
_SYMBOL_RE = re.compile(r"^[\^]?[A-Z0-9.\-=]{1,12}$")

# Friendly display names for common indices; anything else falls back to the
# name Yahoo reports. TW indices use the names TW brokers print.
KNOWN_NAMES = {
    "^TWII": "加權指數",
    "^TWOII": "櫃買指數",
    "^GSPC": "S&P 500",
    "^IXIC": "NASDAQ",
    "^DJI": "Dow Jones",
    "^SOX": "費城半導體",
    "^VIX": "VIX",
    "^N225": "日經 225",
    "^HSI": "恒生指數",
    "^FTSE": "FTSE 100",
    "^GDAXI": "DAX",
}

# Which market's session an index belongs to — drives the "is this live or a
# close" dot in the UI. Default is US; TW-listed indices are tagged TW.
_TW_INDICES = {"^TWII", "^TWOII"}


def _key(user_id: str) -> str:
    return f"indices:{user_id}"


def _load_symbols(db: Session, user_id: str) -> list[str]:
    row = db.get(Metadata, _key(user_id))
    if row is None:
        return list(DEFAULT_INDICES)
    try:
        symbols = json.loads(row.value)
        if isinstance(symbols, list) and all(isinstance(s, str) for s in symbols):
            return symbols or list(DEFAULT_INDICES)
    except ValueError:
        pass
    return list(DEFAULT_INDICES)


class IndicesUpdate(BaseModel):
    symbols: list[str]


@router.get("")
def get_indices(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    symbols = _load_symbols(db, user)
    quote_map = quotes.get_quotes(symbols)
    now = time.time()
    out = []
    for sym in symbols:
        q = quote_map.get(sym)
        price = q.price if q else None
        prev = q.previous_close if q else None
        # A fresh WebSocket tick beats the 5s REST cache (US indices stream
        # in real time; gate on recency, not market hours — index sessions
        # differ per exchange).
        tick = live_quotes.get(sym)
        if tick is not None and now - tick.ts < 120:
            price = tick.price
            if tick.prev_close is not None:
                prev = tick.prev_close
        change = price - prev if price is not None and prev is not None else None
        out.append(
            {
                "symbol": sym,
                "name": KNOWN_NAMES.get(sym) or (q.name if q else sym) or sym,
                "market": "TW" if sym in _TW_INDICES else "US",
                "price": price,
                "change": change,
                "change_pct": (change / prev * 100) if change is not None and prev else None,
            }
        )
    return {"indices": out}


@router.put("")
def set_indices(
    payload: IndicesUpdate,
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    symbols = []
    for s in payload.symbols:
        s = s.strip().upper()
        if not s:
            continue
        if not _SYMBOL_RE.match(s):
            raise HTTPException(status_code=422, detail=f"Invalid index symbol: {s}")
        if s not in symbols:
            symbols.append(s)
    if len(symbols) > MAX_INDICES:
        raise HTTPException(status_code=422, detail=f"At most {MAX_INDICES} indices")

    row = db.get(Metadata, _key(user))
    value = json.dumps(symbols)
    if row is None:
        db.add(Metadata(key=_key(user), value=value))
    else:
        row.value = value
    db.commit()
    return {"symbols": symbols or list(DEFAULT_INDICES)}
