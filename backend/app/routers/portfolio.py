from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import Dividend, Trade, get_db
from ..services import portfolio, quotes

router = APIRouter(prefix="/api/portfolio", tags=["portfolio"])


@router.get("/holdings")
def get_holdings(db: Session = Depends(get_db)):
    return portfolio.build_holdings(db)


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
    all_tickers = sorted(trade_tickers | dividend_tickers)
    if not all_tickers:
        return {}
    quote_map = quotes.get_quotes(all_tickers)
    return {
        t: (quote_map[t].name if t in quote_map and quote_map[t].name else "")
        for t in all_tickers
    }


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
