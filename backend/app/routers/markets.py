"""Market reference data API: trading config + holiday closures.

GET is consumed by the frontend so the calendar/hours/currency live in one
place (the DB). POST/DELETE let you add or remove a closure without a code
change or redeploy.
"""
from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy.orm import Session

from ..database import Market, MarketHoliday, get_db
from ..services import markets

router = APIRouter(prefix="/api/markets", tags=["markets"])


class HolidayCreate(BaseModel):
    date: date
    name: str | None = None


@router.get("")
def list_markets():
    """Every market with its currency, timezone, session hours, and holidays."""
    return markets.all_markets()


@router.post("/{code}/holidays", status_code=status.HTTP_201_CREATED)
def add_holiday(code: str, body: HolidayCreate, db: Session = Depends(get_db)):
    code = code.upper()
    if db.get(Market, code) is None:
        raise HTTPException(status_code=404, detail=f"Unknown market '{code}'")
    row = (
        db.query(MarketHoliday)
        .filter(MarketHoliday.market_code == code, MarketHoliday.holiday_date == body.date)
        .first()
    )
    if row is not None:
        row.name = body.name
    else:
        db.add(MarketHoliday(market_code=code, holiday_date=body.date, name=body.name))
    db.commit()
    markets.invalidate()
    return {"market": code, "date": body.date.isoformat(), "name": body.name}


@router.delete("/{code}/holidays/{day}", status_code=status.HTTP_204_NO_CONTENT)
def remove_holiday(code: str, day: date, db: Session = Depends(get_db)):
    row = (
        db.query(MarketHoliday)
        .filter(MarketHoliday.market_code == code.upper(), MarketHoliday.holiday_date == day)
        .first()
    )
    if row is None:
        raise HTTPException(status_code=404, detail="Holiday not found")
    db.delete(row)
    db.commit()
    markets.invalidate()
    return None
