from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Iterable

from sqlalchemy.orm import Session

from ..database import Dividend, Trade
from . import quotes


@dataclass
class HoldingState:
    ticker: str
    shares: float = 0.0
    cost_basis: float = 0.0  # remaining cost on open shares
    realized_pl: float = 0.0


def _apply_trade(state: HoldingState, trade: Trade) -> None:
    if trade.type == "buy":
        state.shares += trade.shares
        state.cost_basis += trade.shares * trade.price + trade.fee
    elif trade.type == "sell":
        if state.shares <= 0:
            # Selling without an open position — record as pure realized loss/gain
            # based on price alone (treat avg cost as 0 to avoid division errors).
            state.realized_pl += trade.shares * trade.price - trade.fee
            state.shares -= trade.shares
            return
        avg = state.cost_basis / state.shares
        sold = min(trade.shares, state.shares)
        state.realized_pl += sold * (trade.price - avg) - trade.fee
        state.cost_basis -= sold * avg
        state.shares -= trade.shares
        if state.shares <= 1e-9:
            state.shares = 0.0
            state.cost_basis = 0.0


def compute_states(trades: Iterable[Trade]) -> dict[str, HoldingState]:
    sorted_trades = sorted(trades, key=lambda t: (t.trade_date, t.id))
    states: dict[str, HoldingState] = {}
    for tr in sorted_trades:
        state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
        _apply_trade(state, tr)
    return states


def build_holdings(db: Session) -> list[dict]:
    trades = db.query(Trade).all()
    states = compute_states(trades)

    out: list[dict] = []
    for ticker, st in states.items():
        if st.shares <= 0:
            continue
        avg_cost = st.cost_basis / st.shares if st.shares else 0.0
        quote = quotes.get_quote(ticker)
        currency = quote.currency if quote else quotes.detect_currency(
            quotes.resolve_symbol(ticker)
        )
        current_price = quote.price if quote else None
        prev_close = quote.previous_close if quote else None
        market_value = current_price * st.shares if current_price is not None else None
        unrealized = (
            market_value - st.cost_basis if market_value is not None else None
        )
        unrealized_pct = (
            unrealized / st.cost_basis * 100
            if unrealized is not None and st.cost_basis > 0
            else None
        )
        today_change = (
            (current_price - prev_close) * st.shares
            if current_price is not None and prev_close is not None
            else None
        )
        today_change_pct = (
            (current_price - prev_close) / prev_close * 100
            if current_price is not None and prev_close is not None and prev_close > 0
            else None
        )
        out.append(
            {
                "ticker": ticker,
                "currency": currency,
                "shares": st.shares,
                "avg_cost": avg_cost,
                "current_price": current_price,
                "market_value": market_value,
                "cost_basis": st.cost_basis,
                "unrealized_pl": unrealized,
                "unrealized_pl_pct": unrealized_pct,
                "today_change": today_change,
                "today_change_pct": today_change_pct,
            }
        )

    out.sort(key=lambda h: (h["currency"], -(h["market_value"] or 0)))
    return out


def summarize(holdings: list[dict], db: Session) -> list[dict]:
    """Group holdings by currency and produce a summary per currency."""
    groups: dict[str, list[dict]] = defaultdict(list)
    for h in holdings:
        groups[h["currency"]].append(h)

    # Realized P/L from all trades (closed positions too)
    trades = db.query(Trade).all()
    states = compute_states(trades)
    realized_by_currency: dict[str, float] = defaultdict(float)
    for ticker, st in states.items():
        currency = quotes.detect_currency(quotes.resolve_symbol(ticker))
        realized_by_currency[currency] += st.realized_pl

    # Dividend income grouped by currency (derived from the ticker's market)
    dividends_by_currency: dict[str, float] = defaultdict(float)
    for div in db.query(Dividend).all():
        currency = quotes.detect_currency(quotes.resolve_symbol(div.ticker))
        dividends_by_currency[currency] += div.amount

    all_currencies = (
        set(groups)
        | set(realized_by_currency)
        | set(dividends_by_currency)
    )

    summaries: list[dict] = []
    for currency in all_currencies:
        items = groups.get(currency, [])
        total_value = sum((h["market_value"] or 0.0) for h in items)
        total_cost = sum(h["cost_basis"] for h in items)
        total_pl = total_value - total_cost
        total_pl_pct = (total_pl / total_cost * 100) if total_cost > 0 else 0.0
        today_pl = sum((h["today_change"] or 0.0) for h in items)
        prev_value = total_value - today_pl
        today_pl_pct = (today_pl / prev_value * 100) if prev_value > 0 else 0.0
        realized = realized_by_currency.get(currency, 0.0)
        dividends = dividends_by_currency.get(currency, 0.0)
        summaries.append(
            {
                "currency": currency,
                "total_value": total_value,
                "total_cost": total_cost,
                "total_pl": total_pl,
                "total_pl_pct": total_pl_pct,
                "today_pl": today_pl,
                "today_pl_pct": today_pl_pct,
                "realized_pl": realized,
                "dividends": dividends,
                "total_earned": realized + dividends,
                "holdings_count": len(items),
            }
        )

    # Stable order: TWD first then USD, then anything else alphabetically
    order = {"TWD": 0, "USD": 1}
    summaries.sort(key=lambda s: (order.get(s["currency"], 99), s["currency"]))
    return summaries


def build_value_history(db: Session, days: int = 180) -> dict[str, list[dict]]:
    """Daily portfolio market value per currency over the last ``days`` days.

    For each day we walk trades up to that day to find shares held, then
    multiply by that day's close price (carrying forward last known price).
    """
    end = date.today()
    start = end - timedelta(days=days)
    trades = sorted(db.query(Trade).all(), key=lambda t: (t.trade_date, t.id))
    if not trades:
        return {}

    tickers = sorted({t.ticker for t in trades})
    price_series: dict[str, dict[date, float]] = {}
    earliest = min(t.trade_date for t in trades)
    history_start = min(start, earliest)
    for ticker in tickers:
        series = quotes.get_price_history(ticker, history_start, end)
        price_series[ticker] = dict(series)

    out: dict[str, list[dict]] = defaultdict(list)
    cursor = start
    while cursor <= end:
        # holdings as of cursor
        shares: dict[str, float] = defaultdict(float)
        for tr in trades:
            if tr.trade_date > cursor:
                break
            if tr.type == "buy":
                shares[tr.ticker] += tr.shares
            else:
                shares[tr.ticker] -= tr.shares

        per_currency: dict[str, float] = defaultdict(float)
        for ticker, qty in shares.items():
            if qty <= 0:
                continue
            currency = quotes.detect_currency(quotes.resolve_symbol(ticker))
            price = _price_at_or_before(price_series.get(ticker, {}), cursor)
            if price is None:
                continue
            per_currency[currency] += qty * price

        for currency, value in per_currency.items():
            out[currency].append({"date": cursor, "value": value})

        cursor += timedelta(days=1)

    return out


def _price_at_or_before(series: dict[date, float], target: date) -> float | None:
    if not series:
        return None
    if target in series:
        return series[target]
    earlier = [d for d in series if d <= target]
    if not earlier:
        return None
    return series[max(earlier)]
