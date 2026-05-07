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


def _tw_sell_cost_rate(ticker: str) -> float:
    """Estimated TW sell-side cost rate (transaction tax + broker fee).
    Matches the convention TW broker apps use to display "if you sold
    now" net P/L. Uses the standard published rates (no broker discount):

      - Bond ETF (xxxxxB):  0.1425%  (broker fee only, no tax)
      - Regular ETF (00xxx): 0.2425%  (0.1% tax + 0.1425% fee)
      - Common stock:        0.4425%  (0.3% tax + 0.1425% fee)
    """
    t = ticker.strip().upper()
    if t.endswith("B"):
        return 0.001425
    if t.startswith("00"):
        return 0.002425
    return 0.004425


def build_holdings(db: Session) -> list[dict]:
    trades = db.query(Trade).all()
    states = compute_states(trades)

    open_tickers = [t for t, st in states.items() if st.shares > 0]
    quote_map = quotes.get_quotes(open_tickers)

    out: list[dict] = []
    for ticker, st in states.items():
        if st.shares <= 0:
            continue
        avg_cost = st.cost_basis / st.shares if st.shares else 0.0
        quote = quote_map.get(ticker)
        currency = quote.currency if quote else quotes.detect_currency(
            quotes.resolve_symbol(ticker)
        )
        current_price = quote.price if quote else None
        prev_close = quote.previous_close if quote else None
        gross_mv = current_price * st.shares if current_price is not None else None
        # For TWD, show "estimated net value if sold today" so the dashboard
        # totals (Market Value, Unrealized P/L) line up with what TW broker
        # apps display under 總現值 / 損益試算. US prices carry no transaction
        # tax so we leave them at gross.
        if currency == "TWD" and gross_mv is not None:
            market_value = gross_mv * (1 - _tw_sell_cost_rate(ticker))
        else:
            market_value = gross_mv
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
                "name": quote.name if quote else "",
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


def build_realized_history(db: Session, days: int = 180) -> dict[str, list[dict]]:
    """Daily cumulative realized P/L per currency.

    Walks trades chronologically and accumulates the realized P/L delta from
    each sell. Trades that happened *before* the visible window are folded
    into the starting balance so the chart picks up at the right level.
    """
    end = date.today()
    start = end - timedelta(days=days)
    trades = sorted(db.query(Trade).all(), key=lambda t: (t.trade_date, t.id))
    if not trades:
        return {}

    states: dict[str, HoldingState] = {}
    cumulative: dict[str, float] = defaultdict(float)
    daily: dict[str, list[dict]] = defaultdict(list)

    # Seed every currency that has any trades, so a flat line shows up
    # even before its first event in the visible window.
    for tr in trades:
        currency = quotes.detect_currency(quotes.resolve_symbol(tr.ticker))
        cumulative.setdefault(currency, 0.0)

    idx = 0
    # Fold pre-window history into the starting balance.
    while idx < len(trades) and trades[idx].trade_date < start:
        tr = trades[idx]
        state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
        before = state.realized_pl
        _apply_trade(state, tr)
        currency = quotes.detect_currency(quotes.resolve_symbol(tr.ticker))
        cumulative[currency] += state.realized_pl - before
        idx += 1

    cursor = start
    while cursor <= end:
        while idx < len(trades) and trades[idx].trade_date == cursor:
            tr = trades[idx]
            state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
            before = state.realized_pl
            _apply_trade(state, tr)
            currency = quotes.detect_currency(quotes.resolve_symbol(tr.ticker))
            cumulative[currency] += state.realized_pl - before
            idx += 1

        for currency, total in cumulative.items():
            daily[currency].append({"date": cursor, "value": total})
        cursor += timedelta(days=1)

    return dict(daily)


def build_earnings_history(db: Session, days: int = 180) -> dict[str, list[dict]]:
    """Daily cumulative realized P/L, dividends, and total earned per currency.

    Walks both trades and dividends chronologically, accumulating per-currency
    deltas. Events before the visible window are folded into the starting
    balance so the chart picks up at the right level.
    """
    end = date.today()
    start = end - timedelta(days=days)

    trades = sorted(db.query(Trade).all(), key=lambda t: (t.trade_date, t.id))
    dividends = sorted(
        db.query(Dividend).all(), key=lambda d: (d.pay_date, d.id)
    )
    if not trades and not dividends:
        return {}

    states: dict[str, HoldingState] = {}
    cum_realized: dict[str, float] = defaultdict(float)
    cum_dividends: dict[str, float] = defaultdict(float)
    daily: dict[str, list[dict]] = defaultdict(list)

    # Discover currencies up front so flat-line series show up before
    # their first event in the visible window.
    currencies: set[str] = set()
    for tr in trades:
        currencies.add(quotes.detect_currency(quotes.resolve_symbol(tr.ticker)))
    for d in dividends:
        currencies.add(quotes.detect_currency(quotes.resolve_symbol(d.ticker)))
    for c in currencies:
        cum_realized.setdefault(c, 0.0)
        cum_dividends.setdefault(c, 0.0)

    t_idx = 0
    d_idx = 0
    while t_idx < len(trades) and trades[t_idx].trade_date < start:
        tr = trades[t_idx]
        state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
        before = state.realized_pl
        _apply_trade(state, tr)
        currency = quotes.detect_currency(quotes.resolve_symbol(tr.ticker))
        cum_realized[currency] += state.realized_pl - before
        t_idx += 1
    while d_idx < len(dividends) and dividends[d_idx].pay_date < start:
        d = dividends[d_idx]
        currency = quotes.detect_currency(quotes.resolve_symbol(d.ticker))
        cum_dividends[currency] += d.amount
        d_idx += 1

    cursor = start
    while cursor <= end:
        while t_idx < len(trades) and trades[t_idx].trade_date == cursor:
            tr = trades[t_idx]
            state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
            before = state.realized_pl
            _apply_trade(state, tr)
            currency = quotes.detect_currency(quotes.resolve_symbol(tr.ticker))
            cum_realized[currency] += state.realized_pl - before
            t_idx += 1
        while d_idx < len(dividends) and dividends[d_idx].pay_date == cursor:
            d = dividends[d_idx]
            currency = quotes.detect_currency(quotes.resolve_symbol(d.ticker))
            cum_dividends[currency] += d.amount
            d_idx += 1

        for c in currencies:
            r = cum_realized[c]
            div = cum_dividends[c]
            daily[c].append(
                {
                    "date": cursor,
                    "realized": r,
                    "dividends": div,
                    "total": r + div,
                }
            )
        cursor += timedelta(days=1)

    return dict(daily)


def _price_at_or_before(series: dict[date, float], target: date) -> float | None:
    if not series:
        return None
    if target in series:
        return series[target]
    earlier = [d for d in series if d <= target]
    if not earlier:
        return None
    return series[max(earlier)]
