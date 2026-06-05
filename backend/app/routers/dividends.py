from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from ..database import Dividend, get_db
from ..schemas import DividendCreate, DividendOut
from ..services import quotes

router = APIRouter(prefix="/api/dividends", tags=["dividends"])


def _to_out(d: Dividend) -> DividendOut:
    market = d.market or quotes.market_of(d.ticker)
    return DividendOut(
        id=d.id,
        ticker=d.ticker,
        amount=d.amount,
        currency=quotes.currency_of(market),
        market=market,
        pay_date=d.pay_date,
        notes=d.notes,
        created_at=d.created_at,
    )


@router.get("", response_model=list[DividendOut])
def list_dividends(
    market: str | None = Query(None),
    db: Session = Depends(get_db),
):
    q = db.query(Dividend)
    if market:
        q = q.filter(Dividend.market == market.upper())
    rows = q.order_by(Dividend.pay_date.desc(), Dividend.id.desc()).all()
    return [_to_out(d) for d in rows]


@router.post("", response_model=DividendOut, status_code=status.HTTP_201_CREATED)
def create_dividend(payload: DividendCreate, db: Session = Depends(get_db)):
    ticker = payload.ticker.strip().upper()
    d = Dividend(
        ticker=ticker,
        amount=payload.amount,
        pay_date=payload.pay_date,
        notes=payload.notes,
        market=payload.market or quotes.market_of(ticker),
    )
    db.add(d)
    db.commit()
    db.refresh(d)
    return _to_out(d)


@router.put("/{dividend_id}", response_model=DividendOut)
def update_dividend(
    dividend_id: int, payload: DividendCreate, db: Session = Depends(get_db)
):
    d = db.query(Dividend).filter(Dividend.id == dividend_id).first()
    if not d:
        raise HTTPException(status_code=404, detail="Dividend not found")
    d.ticker = payload.ticker.strip().upper()
    d.amount = payload.amount
    d.pay_date = payload.pay_date
    d.notes = payload.notes
    d.market = payload.market or quotes.market_of(d.ticker)
    db.commit()
    db.refresh(d)
    return _to_out(d)


@router.delete("/{dividend_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_dividend(dividend_id: int, db: Session = Depends(get_db)):
    d = db.query(Dividend).filter(Dividend.id == dividend_id).first()
    if not d:
        raise HTTPException(status_code=404, detail="Dividend not found")
    db.delete(d)
    db.commit()
    return None
