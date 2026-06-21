import time
from threading import Lock

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import Dividend, Trade, get_db
from ..services import portfolio, quotes

router = APIRouter(prefix="/api/portfolio", tags=["portfolio"])

# Ticker -> name almost never changes, but get_names used to fetch live quotes
# for EVERY ticker ever traded (incl. closed positions) on every 5s poll. Cache
# the result so that heavy fetch happens at most once per TTL (keyed by the
# ticker set, so a newly-added ticker still refreshes immediately).
_NAMES_TTL_SECONDS = 600.0
_names_cache: dict = {"key": None, "at": 0.0, "value": {}}
# Guards _names_cache against concurrent read-modify-write from the threadpool.
_names_lock = Lock()


@router.get("/holdings")
def get_holdings(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    return portfolio.build_holdings(db, user)


@router.get("/overview")
def get_overview(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    """Per-market summary cards (TW + US) plus a combined net worth shown in
    both NT$ and US$. Powers the landing page."""
    return portfolio.build_overview(db, user)


@router.get("/summary")
def get_summary(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    holdings = portfolio.build_holdings(db, user)
    return portfolio.summarize(holdings, db, user)


@router.get("/realized-history")
def get_realized_history(
    days: int = Query(180, ge=7, le=1825),
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    return portfolio.build_realized_history(db, user, days=days)


@router.get("/earnings-history")
def get_earnings_history(
    days: int = Query(180, ge=7, le=1825),
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    return portfolio.build_earnings_history(db, user, days=days)


@router.get("/names")
def get_names(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    """Ticker → short-name map for every ticker the user has touched.
    Pulled from the live quote service (TWSE MIS for TW)."""
    trade_tickers = {t for (t,) in db.query(Trade.ticker).filter(Trade.user_id == user).distinct()}
    dividend_tickers = {t for (t,) in db.query(Dividend.ticker).filter(Dividend.user_id == user).distinct()}
    all_tickers = tuple(sorted(trade_tickers | dividend_tickers))
    if not all_tickers:
        return {}

    now = time.time()
    with _names_lock:
        if (
            _names_cache["key"] == all_tickers
            and _names_cache["value"]
            and now - _names_cache["at"] < _NAMES_TTL_SECONDS
        ):
            return dict(_names_cache["value"])

    quote_map = quotes.get_quotes(all_tickers)
    names = {
        t: (quote_map[t].name if t in quote_map and quote_map[t].name else "")
        for t in all_tickers
    }
    # Only cache once we actually have names (don't pin a failed/empty fetch).
    if any(names.values()):
        with _names_lock:
            _names_cache.update({"key": all_tickers, "at": now, "value": names})
    return names


@router.get("/quote/{ticker}")
def get_quote(ticker: str):
    q = quotes.get_quote(ticker)
    if q is None:
        return {"ticker": ticker, "found": False}
    return {
        "ticker": ticker,
        "found": True,
        "symbol": q.symbol,
        "name": q.name,
        "price": q.price,
        "previous_close": q.previous_close,
        "currency": q.currency,
    }
