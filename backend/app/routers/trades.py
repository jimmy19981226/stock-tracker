from collections import defaultdict

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import Trade, get_db
from ..schemas import TradeCreate, TradeOut
from ..services import quotes

router = APIRouter(prefix="/api/trades", tags=["trades"])


def _compute_statuses(trades: list[Trade]) -> dict[int, str]:
    """For each ticker, walk trades chronologically and use FIFO matching:
    sells consume buy lots front-first. After all matches, any buy lot
    with leftover shares is "open" (contributes to unrealized P/L).
    Sells, and buys whose shares were fully sold, are "closed"
    (contribute to realized P/L).
    """
    statuses: dict[int, str] = {}
    by_ticker: dict[str, list[Trade]] = defaultdict(list)
    for t in trades:
        by_ticker[t.ticker].append(t)

    for ticker_trades in by_ticker.values():
        sorted_t = sorted(ticker_trades, key=lambda t: (t.trade_date, t.id))
        # FIFO queue of [trade_id, remaining_shares] pairs
        lots: list[list] = []
        for t in sorted_t:
            if t.type == "buy":
                lots.append([t.id, t.shares])
            else:  # sell — always counted as realized
                statuses[t.id] = "closed"
                remaining = t.shares
                while remaining > 1e-9 and lots:
                    lot = lots[0]
                    if lot[1] <= remaining + 1e-9:
                        statuses[lot[0]] = "closed"
                        remaining -= lot[1]
                        lots.pop(0)
                    else:
                        lot[1] -= remaining
                        remaining = 0
        # Anything still in the queue had shares left unsold → open
        for lot in lots:
            statuses[lot[0]] = "open"
    return statuses


def _to_out(t: Trade, status: str) -> dict:
    return {
        "id": t.id,
        "type": t.type,
        "ticker": t.ticker,
        "shares": t.shares,
        "price": t.price,
        "trade_date": t.trade_date,
        "fee": t.fee,
        "notes": t.notes,
        "market": t.market,
        "created_at": t.created_at,
        "status": status,
    }


@router.get("", response_model=list[TradeOut])
def list_trades(
    market: str | None = Query(None),
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    q = db.query(Trade).filter(Trade.user_id == user)
    if market:
        q = q.filter(Trade.market == market.upper())
    rows = q.order_by(Trade.trade_date.desc(), Trade.id.desc()).all()
    statuses = _compute_statuses(rows)
    return [_to_out(t, statuses.get(t.id, "open")) for t in rows]


@router.post("", response_model=TradeOut, status_code=status.HTTP_201_CREATED)
def create_trade(
    payload: TradeCreate,
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    ticker = payload.ticker.strip().upper()
    trade = Trade(
        type=payload.type,
        ticker=ticker,
        shares=payload.shares,
        price=payload.price,
        trade_date=payload.trade_date,
        fee=payload.fee,
        notes=payload.notes,
        market=payload.market or quotes.market_of(ticker),
        user_id=user,
    )
    db.add(trade)
    db.commit()
    db.refresh(trade)
    return trade


@router.put("/{trade_id}", response_model=TradeOut)
def update_trade(
    trade_id: int,
    payload: TradeCreate,
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    trade = (
        db.query(Trade)
        .filter(Trade.id == trade_id, Trade.user_id == user)
        .first()
    )
    if not trade:
        raise HTTPException(status_code=404, detail="Trade not found")
    trade.type = payload.type
    trade.ticker = payload.ticker.strip().upper()
    trade.shares = payload.shares
    trade.price = payload.price
    trade.trade_date = payload.trade_date
    trade.fee = payload.fee
    trade.notes = payload.notes
    trade.market = payload.market or quotes.market_of(trade.ticker)
    db.commit()
    db.refresh(trade)
    return trade


@router.delete("/{trade_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_trade(
    trade_id: int,
    db: Session = Depends(get_db),
    user: str = Depends(get_current_user),
):
    trade = (
        db.query(Trade)
        .filter(Trade.id == trade_id, Trade.user_id == user)
        .first()
    )
    if not trade:
        raise HTTPException(status_code=404, detail="Trade not found")
    db.delete(trade)
    db.commit()
    return None
