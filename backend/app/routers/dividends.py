from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ..database import Dividend, get_db
from ..schemas import DividendCreate, DividendOut
from ..services import quotes

router = APIRouter(prefix="/api/dividends", tags=["dividends"])


def _to_out(d: Dividend) -> DividendOut:
    return DividendOut(
        id=d.id,
        ticker=d.ticker,
        amount=d.amount,
        currency=quotes.detect_currency(quotes.resolve_symbol(d.ticker)),
        pay_date=d.pay_date,
        notes=d.notes,
        created_at=d.created_at,
    )


@router.get("", response_model=list[DividendOut])
def list_dividends(db: Session = Depends(get_db)):
    rows = (
        db.query(Dividend)
        .order_by(Dividend.pay_date.desc(), Dividend.id.desc())
        .all()
    )
    return [_to_out(d) for d in rows]


@router.post("", response_model=DividendOut, status_code=status.HTTP_201_CREATED)
def create_dividend(payload: DividendCreate, db: Session = Depends(get_db)):
    d = Dividend(
        ticker=payload.ticker.strip().upper(),
        amount=payload.amount,
        pay_date=payload.pay_date,
        notes=payload.notes,
    )
    db.add(d)
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
