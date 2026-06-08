import time

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import Dividend, Trade, get_db
from ..services import fx, portfolio, quotes

router = APIRouter(prefix="/api/portfolio", tags=["portfolio"])

# Ticker -> name almost never changes, but get_names used to fetch live quotes
# for EVERY ticker ever traded (incl. closed positions) on every 5s poll. Cache
# the result so that heavy fetch happens at most once per TTL (keyed by the
# ticker set, so a newly-added ticker still refreshes immediately).
_NAMES_TTL_SECONDS = 600.0
_names_cache: dict = {"key": None, "at": 0.0, "value": {}}


@router.get("/holdings")
def get_holdings(db: Session = Depends(get_db)):
    return portfolio.build_holdings(db)


@router.get("/overview")
def get_overview(db: Session = Depends(get_db)):
    """Per-market summary cards (TW + US) plus a combined net worth shown in
    both NT$ and US$. Powers the landing page. The combined figures are null
    when the FX rate is unavailable, or while a market that holds positions has
    no live quote (so we never show a fabricated total)."""
    holdings = portfolio.build_holdings(db)
    summaries = portfolio.summarize(holdings, db)
    by_currency = {s["currency"]: s for s in summaries}
    tw = by_currency.get("TWD")
    us = by_currency.get("USD")

    rate, asof = fx.get_usd_twd()
    tw_value = tw["total_value"] if tw else None
    us_value = us["total_value"] if us else None

    combined_twd: float | None = None
    combined_usd: float | None = None
    # Only blank the combined total if a market that HAS holdings is missing a
    # live value (transient quote outage) — an empty market just contributes 0.
    tw_missing = tw is not None and tw_value is None
    us_missing = us is not None and us_value is None
    if rate and not tw_missing and not us_missing:
        t = tw_value or 0.0
        u = us_value or 0.0
        combined_twd = t + u * rate
        combined_usd = u + t / rate

    return {
        "tw": tw,
        "us": us,
        "fx": {"usd_twd": rate, "asof": asof},
        "combined": {"twd": combined_twd, "usd": combined_usd},
    }


@router.get("/summary")
def get_summary(db: Session = Depends(get_db)):
    holdings = portfolio.build_holdings(db)
    return portfolio.summarize(holdings, db)


@router.get("/realized-history")
def get_realized_history(
    days: int = Query(180, ge=7, le=1825), db: Session = Depends(get_db)
):
    return portfolio.build_realized_history(db, days=days)


@router.get("/earnings-history")
def get_earnings_history(
    days: int = Query(180, ge=7, le=1825), db: Session = Depends(get_db)
):
    return portfolio.build_earnings_history(db, days=days)


@router.get("/names")
def get_names(db: Session = Depends(get_db)):
    """Ticker → short-name map for every ticker the user has touched.
    Pulled from the live quote service (TWSE MIS for TW)."""
    trade_tickers = {t for (t,) in db.query(Trade.ticker).distinct()}
    dividend_tickers = {t for (t,) in db.query(Dividend.ticker).distinct()}
    all_tickers = tuple(sorted(trade_tickers | dividend_tickers))
    if not all_tickers:
        return {}

    now = time.time()
    cached = _names_cache
    if (
        cached["key"] == all_tickers
        and cached["value"]
        and now - cached["at"] < _NAMES_TTL_SECONDS
    ):
        return cached["value"]

    quote_map = quotes.get_quotes(all_tickers)
    names = {
        t: (quote_map[t].name if t in quote_map and quote_map[t].name else "")
        for t in all_tickers
    }
    # Only cache once we actually have names (don't pin a failed/empty fetch).
    if any(names.values()):
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
