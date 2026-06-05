from datetime import date, datetime
from typing import Literal
from pydantic import BaseModel, Field, ConfigDict


class TradeCreate(BaseModel):
    type: Literal["buy", "sell"]
    ticker: str = Field(min_length=1, max_length=20)
    shares: float = Field(gt=0)
    price: float = Field(gt=0)
    trade_date: date
    fee: float = Field(default=0.0, ge=0)
    notes: str | None = None
    # None ⇒ the server infers the market from the ticker format.
    market: Literal["TW", "US"] | None = None


class TradeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    type: str
    ticker: str
    shares: float
    price: float
    trade_date: date
    fee: float
    notes: str | None
    market: str = "TW"
    created_at: datetime
    status: str = "open"  # "open" (unrealized) or "closed" (realized)


class Holding(BaseModel):
    ticker: str
    name: str = ""
    currency: str
    market: str = "TW"
    shares: float
    avg_cost: float
    current_price: float | None
    market_value: float | None
    cost_basis: float
    exit_cost: float | None = None
    unrealized_pl: float | None
    unrealized_pl_pct: float | None
    today_change: float | None
    today_change_pct: float | None


class PortfolioSummary(BaseModel):
    currency: str
    total_value: float
    total_cost: float
    total_pl: float
    total_pl_pct: float
    today_pl: float
    today_pl_pct: float
    realized_pl: float
    dividends: float
    total_earned: float
    holdings_count: int


class DividendCreate(BaseModel):
    ticker: str = Field(min_length=1, max_length=20)
    amount: float = Field(gt=0)
    pay_date: date
    notes: str | None = None
    market: Literal["TW", "US"] | None = None


class DividendOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    ticker: str
    amount: float
    currency: str
    market: str = "TW"
    pay_date: date
    notes: str | None
    created_at: datetime


class HistoryPoint(BaseModel):
    date: date
    value: float


class Quote(BaseModel):
    ticker: str
    price: float
    currency: str
    previous_close: float | None
