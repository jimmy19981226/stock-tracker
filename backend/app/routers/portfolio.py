import time
from threading import Lock

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import Dividend, Trade, get_db
from ..services import performance, portfolio, quotes

router = APIRouter(prefix="/api/portfolio", tags=["portfolio"])

# Ticker -> name almost never changes, but get_names used to fetch live quotes
# for EVERY ticker ever traded (incl. closed positions) on every 5s poll. Cache
# the result so that heavy fetch happens at most once per TTL (keyed by the
# ticker set, so a newly-added ticker still refreshes immediately).
_NAMES_TTL_SECONDS = 600.0
# Keyed by user_id: a single shared entry made two users evict each other's
# names on every poll, so neither ever got a cache hit.
_names_cache: dict[str, dict] = {}
# Guards _names_cache against concurrent read-modify-write from the threadpool.
_names_lock = Lock()


def _names_entry(user: str) -> dict:
    return _names_cache.get(user) or {"key": None, "at": 0.0, "value": {}}


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


# yfinance period shorthands the value-history chart's tabs map to.
_VALUE_PERIODS = {"5d", "1mo", "3mo", "6mo", "ytd", "1y", "2y", "5y", "max"}


@router.get("/value-history")
def get_value_history(
    market: str = Query("TW", pattern="^(TW|US)$"),
    period: str = Query("1y"),
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    """Daily total market value of one market's holdings (net-worth curve)."""
    if period not in _VALUE_PERIODS:
        period = "1y"
    return portfolio.build_value_history(db, user, market=market, period=period)


@router.get("/performance")
def get_performance(
    market: str = Query("TW", pattern="^(TW|US)$"),
    period: str = Query("1y"),
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    """TWR / XIRR / benchmark comparison / monthly P&L for one market.
    See services/performance.py."""
    if period not in _VALUE_PERIODS:
        period = "1y"
    return performance.build_performance(db, user, market=market, period=period)


class BenchmarkUpdate(BaseModel):
    market: str = Field(..., pattern="^(TW|US)$")
    # Any Yahoo-resolvable symbol: an index (^TWII), a TW ETF by bare code
    # (0050), or a US ticker (QQQ). Empty resets the market to its default.
    symbol: str = Field("", max_length=12)


@router.get("/benchmark")
def get_benchmark(db: Session = Depends(get_db), user: str = Depends(get_current_user)):
    """The caller's benchmark per market, plus the picker's preset list."""
    chosen = performance.get_benchmarks(db, user)
    return {
        "benchmarks": chosen,
        "defaults": performance.DEFAULT_BENCHMARKS,
        "presets": {
            market: [{"symbol": s, "name": n} for s, n in rows]
            for market, rows in performance.BENCHMARK_PRESETS.items()
        },
        "names": {m: performance.benchmark_name(s) for m, s in chosen.items()},
    }


@router.put("/benchmark")
def set_benchmark(
    payload: BenchmarkUpdate,
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    """Point one market's performance comparison at a different symbol."""
    try:
        chosen = performance.set_benchmark(db, user, payload.market, payload.symbol)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {
        "benchmarks": chosen,
        "names": {m: performance.benchmark_name(s) for m, s in chosen.items()},
    }


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
        entry = _names_entry(user)
        cached = dict(entry["value"])
        cached_at = entry["at"]
        fresh = bool(cached) and now - cached_at < _NAMES_TTL_SECONDS
        if fresh and entry["key"] == all_tickers:
            return cached

    # Within the TTL, only fetch tickers the cache doesn't know yet — names
    # essentially never change, and refetching the full lifetime ticker set
    # whenever the set grew is what made saving a trade with a NEW ticker
    # take tens of seconds.
    to_fetch = [t for t in all_tickers if not cached.get(t)] if fresh else list(all_tickers)
    quote_map = quotes.get_quotes(to_fetch) if to_fetch else {}

    fetched = {
        t: quotes.display_name(
            t, fallback=quote_map[t].name if t in quote_map and quote_map[t].name else "")
        for t in to_fetch
    }
    names = {t: cached.get(t) or fetched.get(t, "") for t in all_tickers}
    # Only cache once we actually have names (don't pin a failed/empty fetch).
    # An incremental merge keeps the old timestamp so the TTL still forces a
    # full refresh on schedule.
    if any(names.values()):
        with _names_lock:
            _names_cache[user] = {
                "key": all_tickers, "at": cached_at if fresh else now, "value": names
            }
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
        "name": quotes.display_name(ticker, fallback=q.name),
        "price": q.price,
        "previous_close": q.previous_close,
        "currency": q.currency,
    }
