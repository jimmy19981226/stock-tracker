from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ..database import Trade, get_db
from ..schemas import TradeCreate, TradeOut

router = APIRouter(prefix="/api/trades", tags=["trades"])


@router.get("", response_model=list[TradeOut])
def list_trades(db: Session = Depends(get_db)):
    return (
        db.query(Trade)
        .order_by(Trade.trade_date.desc(), Trade.id.desc())
        .all()
    )


@router.post("", response_model=TradeOut, status_code=status.HTTP_201_CREATED)
def create_trade(payload: TradeCreate, db: Session = Depends(get_db)):
    trade = Trade(
        type=payload.type,
        ticker=payload.ticker.strip().upper(),
        shares=payload.shares,
        price=payload.price,
        trade_date=payload.trade_date,
        fee=payload.fee,
        notes=payload.notes,
    )
    db.add(trade)
    db.commit()
    db.refresh(trade)
    return trade


@router.delete("/{trade_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_trade(trade_id: int, db: Session = Depends(get_db)):
    trade = db.query(Trade).filter(Trade.id == trade_id).first()
    if not trade:
        raise HTTPException(status_code=404, detail="Trade not found")
    db.delete(trade)
    db.commit()
    return None
