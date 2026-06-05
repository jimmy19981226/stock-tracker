"""Per-stock detail endpoint.

Aggregates everything the detail UI needs in one call:
- live quote from MIS (intraday, near real-time)
- fundamentals (P/E, market cap, sector, ...) from yfinance
- daily price history for the chosen period from yfinance
- TAIEX history over the same range (for benchmark overlay)
- position-specific stats from the user's trades and dividends
- trade and dividend markers to overlay on the chart
"""
from __future__ import annotations

from datetime import date, datetime, timezone
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from ..database import Dividend, Trade, get_db
from ..services import quotes, stock_info
from ..services.portfolio import compute_states, estimate_exit_cost


router = APIRouter(prefix="/api/stock", tags=["stock"])

PeriodLiteral = Literal["1mo", "3mo", "6mo", "1y", "2y", "5y", "max"]


@router.get("/{ticker}/detail")
def stock_detail(
    ticker: str,
    period: PeriodLiteral = Query("1y"),
    db: Session = Depends(get_db),
):
    ticker = ticker.strip().upper()
    if not ticker:
        raise HTTPException(status_code=400, detail="Ticker required")

    # --- live quote (MIS) ---
    quote = quotes.get_quote(ticker)
    today_change = today_change_pct = None
    if quote and quote.previous_close:
        today_change = quote.price - quote.previous_close
        today_change_pct = today_change / quote.previous_close * 100 if quote.previous_close else None

    live = {
        "price": quote.price if quote else None,
        "previous_close": quote.previous_close if quote else None,
        "today_change": today_change,
        "today_change_pct": today_change_pct,
        "day_open": quote.day_open if quote else None,
        "day_high": quote.day_high if quote else None,
        "day_low": quote.day_low if quote else None,
        "bid": quote.bid if quote else None,
        "ask": quote.ask if quote else None,
        "volume": quote.volume if quote else None,
    }

    # --- fundamentals + history + financials (yfinance/FinMind, cached) ---
    fundamentals = stock_info.get_fundamentals(ticker)
    history = stock_info.get_history(ticker, period)
    taiex = stock_info.get_taiex_history(period)
    monthly_revenue = stock_info.get_monthly_revenue(ticker, months=24)
    quarterly_financials = stock_info.get_quarterly_financials(ticker, quarters=8)

    # --- position state from user's trades ---
    trades = db.query(Trade).filter(Trade.ticker == ticker).order_by(Trade.trade_date).all()
    dividends = (
        db.query(Dividend)
        .filter(Dividend.ticker == ticker)
        .order_by(Dividend.pay_date)
        .all()
    )
    states = compute_states(db.query(Trade).all())  # full FIFO state across all tickers
    st = states.get(ticker)

    position: dict | None = None
    if trades:
        first_buy = min((t.trade_date for t in trades if t.type == "buy"), default=None)
        holding_days = (date.today() - first_buy).days if first_buy else None
        fees_paid = sum(t.fee or 0.0 for t in trades)
        dividends_total = sum(d.amount for d in dividends)
        if st is not None:
            shares = st.shares
            cost_basis = st.cost_basis
            avg_cost = (cost_basis / shares) if shares > 0 else None
            realized_pl = st.realized_pl
        else:
            shares = 0.0
            cost_basis = 0.0
            avg_cost = None
            realized_pl = 0.0

        market_value = (quote.price * shares) if (quote and shares > 0) else None
        # Net of estimated exit costs (commission + tax), matching 損益試算 (0 for US).
        market = trades[0].market or quotes.market_of(ticker)
        exit_cost = (
            estimate_exit_cost(ticker, market_value, market)
            if market_value is not None
            else None
        )
        unrealized_pl = (
            market_value - cost_basis - exit_cost if market_value is not None else None
        )
        unrealized_pl_pct = (
            unrealized_pl / cost_basis * 100
            if unrealized_pl is not None and cost_basis > 0
            else None
        )
        total_return = (
            (unrealized_pl or 0.0) + realized_pl + dividends_total
            if shares > 0 or realized_pl or dividends_total
            else 0.0
        )
        # Total invested = sum of buy notional minus sells already applied
        # via realized P/L. For % we use the cumulative buy cost (more
        # intuitive than just open cost basis after partial sells).
        total_buy_cost = sum(
            (t.shares * t.price + (t.fee or 0.0)) for t in trades if t.type == "buy"
        ) or 1.0
        total_return_pct = total_return / total_buy_cost * 100

        position = {
            "shares": shares,
            "avg_cost": avg_cost,
            "cost_basis": cost_basis,
            "market_value": market_value,
            "exit_cost": exit_cost,
            "unrealized_pl": unrealized_pl,
            "unrealized_pl_pct": unrealized_pl_pct,
            "realized_pl": realized_pl,
            "dividends_received": dividends_total,
            "total_return": total_return,
            "total_return_pct": total_return_pct,
            "first_buy_date": first_buy.isoformat() if first_buy else None,
            "holding_days": holding_days,
            "trade_count": len(trades),
            "fees_paid": fees_paid,
        }

    # --- markers for the chart ---
    trade_markers = [
        {
            "date": t.trade_date.isoformat(),
            "type": t.type,
            "shares": t.shares,
            "price": t.price,
            "fee": t.fee,
            "notes": t.notes,
        }
        for t in trades
    ]
    dividend_markers = [
        {"date": d.pay_date.isoformat(), "amount": d.amount, "notes": d.notes}
        for d in dividends
    ]

    # Yield on cost (using current avg cost basis): annualized dividend / avg cost.
    yield_on_cost = None
    if position and position["avg_cost"] and dividends:
        # Use last 365 days of dividends as a rough "annual" figure.
        cutoff = datetime.now(timezone.utc).date()
        from datetime import timedelta as _td
        recent_div = sum(
            d.amount for d in dividends if (cutoff - d.pay_date) <= _td(days=365)
        )
        if position["shares"] > 0:
            per_share = recent_div / position["shares"]
            yield_on_cost = per_share / position["avg_cost"] * 100 if position["avg_cost"] else None

    return {
        "ticker": ticker,
        "symbol": quotes.resolve_symbol(ticker),
        "name": quote.name if quote else (fundamentals.get("short_name") or fundamentals.get("long_name") or ""),
        "live": live,
        "fundamentals": fundamentals,
        "position": position,
        "history": history,
        "taiex_history": taiex,
        "trades": trade_markers,
        "dividends": dividend_markers,
        "yield_on_cost": yield_on_cost,
        "monthly_revenue": monthly_revenue,
        "quarterly_financials": quarterly_financials,
    }
