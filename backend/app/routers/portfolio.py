from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..database import get_db
from ..services import portfolio, quotes

router = APIRouter(prefix="/api/portfolio", tags=["portfolio"])


@router.get("/holdings")
def get_holdings(db: Session = Depends(get_db)):
    return portfolio.build_holdings(db)


@router.get("/summary")
def get_summary(db: Session = Depends(get_db)):
    holdings = portfolio.build_holdings(db)
    return portfolio.summarize(holdings, db)


@router.get("/history")
def get_history(days: int = Query(180, ge=7, le=1825), db: Session = Depends(get_db)):
    return portfolio.build_value_history(db, days=days)


@router.get("/quote/{ticker}")
def get_quote(ticker: str):
    q = quotes.get_quote(ticker)
    if q is None:
        return {"ticker": ticker, "found": False}
    return {
        "ticker": ticker,
        "found": True,
        "symbol": q.symbol,
        "price": q.price,
        "previous_close": q.previous_close,
        "currency": q.currency,
    }
