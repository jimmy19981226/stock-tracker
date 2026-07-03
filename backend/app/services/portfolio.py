from __future__ import annotations

import math
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from datetime import date, timedelta
from threading import Lock
from typing import Iterable

from sqlalchemy.orm import Session

from ..database import Dividend, Trade
from . import fx, quotes


# --- TW exit-cost estimate ----------------------------------------------
# TW broker apps don't show the *gross* unrealized gain (市值 − 成本); their
# 損益試算 column shows what you'd actually pocket after paying to liquidate:
# the sell-side commission plus the securities transaction tax. Subtracting
# this is what makes our Unrealized P/L line up with the broker to the dollar.
SELL_FEE_RATE = 0.001425  # brokerage commission, full published rate


def _sell_tax_rate(ticker: str) -> float:
    """Securities transaction tax rate on the sell side.

    Ordinary listed shares pay 0.3%. ETFs (codes starting ``00``) pay 0.1%,
    except bond ETFs (trailing ``B``) which are tax-exempt.
    """
    t = ticker.strip().upper()
    if t.startswith("00"):
        return 0.0 if t.endswith("B") else 0.001
    return 0.003


def estimate_exit_cost(ticker: str, market_value: float, market: str = "TW") -> float:
    """Estimated commission + transaction tax to sell a position at
    ``market_value``. Each component is floored to the dollar, mirroring how
    TW brokers print 損益試算.

    US positions are treated as commission-free with no transaction tax (the
    norm at modern US brokers), so their exit cost is 0 and unrealized P/L is
    reported gross (market value − cost)."""
    if market_value <= 0:
        return 0.0
    if (market or "TW").upper() == "US":
        return 0.0
    fee = math.floor(market_value * SELL_FEE_RATE)
    tax = math.floor(market_value * _sell_tax_rate(ticker))
    return float(fee + tax)


@dataclass
class HoldingState:
    """Per-ticker position tracked as FIFO lots — first-in, first-out — so
    realized P/L matches how US brokers report cost basis on the 1099, and the
    remaining lots give the cost basis of the shares still held.

    Note: over a position's full life (bought and fully sold) FIFO and
    weighted-average produce the SAME total realized; they differ only in how
    profit is split between realized and still-open lots at a point in time, and
    in which tax year a partial sale's gain lands. Total Return is unaffected.
    """
    ticker: str
    # Open lots, oldest first. Each lot is a mutable ``[shares, cost_per_share]``
    # where any buy fee is folded into the per-share cost.
    lots: deque = field(default_factory=deque)
    realized_pl: float = 0.0

    @property
    def shares(self) -> float:
        return sum(lot[0] for lot in self.lots)

    @property
    def cost_basis(self) -> float:  # remaining cost on the open lots
        return sum(lot[0] * lot[1] for lot in self.lots)


def _apply_trade(state: HoldingState, trade: Trade) -> None:
    if trade.type == "buy":
        if trade.shares <= 0:
            return
        cost_per_share = (trade.shares * trade.price + trade.fee) / trade.shares
        state.lots.append([trade.shares, cost_per_share])
        return

    if trade.type == "sell":
        qty = trade.shares
        consumed = 0.0          # shares matched against open lots
        consumed_cost = 0.0     # their FIFO cost basis
        while qty > 1e-9 and state.lots:
            lot = state.lots[0]
            take = min(qty, lot[0])
            consumed += take
            consumed_cost += take * lot[1]
            lot[0] -= take
            qty -= take
            if lot[0] <= 1e-9:
                state.lots.popleft()
        # Realized on the shares that had cost basis, less the sell fee.
        state.realized_pl += consumed * trade.price - consumed_cost - trade.fee
        # Over-sell: shares sold beyond the open position have no cost basis, so
        # book their proceeds as pure realized gain (a sell-before-buy is a
        # data-entry error, but don't silently drop its P/L).
        if qty > 1e-9:
            state.realized_pl += qty * trade.price


def compute_states(trades: Iterable[Trade]) -> dict[str, HoldingState]:
    sorted_trades = sorted(trades, key=lambda t: (t.trade_date, t.id))
    states: dict[str, HoldingState] = {}
    for tr in sorted_trades:
        state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
        _apply_trade(state, tr)
    return states


def _ticker_markets(db: Session, user_id: str) -> dict[str, str]:
    """Map each ticker the user has traded to its stored market ("TW"/"US").

    The stored market is authoritative (it respects a user's explicit pick in
    the form); fall back to inferring from the ticker format if absent."""
    out: dict[str, str] = {}
    rows = (
        db.query(Trade.ticker, Trade.market)
        .filter(Trade.user_id == user_id)
        .distinct()
    )
    for ticker, market in rows:
        out[ticker] = market or quotes.market_of(ticker)
    return out


def build_holdings(db: Session, user_id: str) -> list[dict]:
    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    states = compute_states(trades)
    ticker_market = {t.ticker: (t.market or quotes.market_of(t.ticker)) for t in trades}

    open_tickers = [t for t, st in states.items() if st.shares > 1e-9]
    quote_map = quotes.get_quotes(open_tickers)

    out: list[dict] = []
    for ticker, st in states.items():
        if st.shares <= 1e-9:
            continue
        avg_cost = st.cost_basis / st.shares if st.shares else 0.0
        quote = quote_map.get(ticker)
        market = ticker_market.get(ticker) or quotes.market_of(ticker)
        # Group by the stored market's currency so holdings and the per-market
        # summaries always agree (don't trust a stray quote currency mismatch).
        currency = quotes.currency_of(market)
        current_price = quote.price if quote else None
        prev_close = quote.previous_close if quote else None
        # Gross market value (price × shares) — matches the broker's 資產市值.
        market_value = current_price * st.shares if current_price is not None else None
        # Estimated cost to liquidate, so unrealized P/L matches 損益試算 (0 for US).
        exit_cost = (
            estimate_exit_cost(ticker, market_value, market)
            if market_value is not None
            else None
        )
        unrealized = (
            market_value - st.cost_basis - exit_cost
            if market_value is not None
            else None
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
                "market": market,
                "shares": st.shares,
                "avg_cost": avg_cost,
                "current_price": current_price,
                "market_value": market_value,
                "cost_basis": st.cost_basis,
                "exit_cost": exit_cost,
                "unrealized_pl": unrealized,
                "unrealized_pl_pct": unrealized_pct,
                "today_change": today_change,
                "today_change_pct": today_change_pct,
            }
        )

    out.sort(key=lambda h: (h["currency"], -(h["market_value"] or 0)))
    return out


def summarize(holdings: list[dict], db: Session, user_id: str) -> list[dict]:
    """Group holdings by currency and produce a summary per currency."""
    groups: dict[str, list[dict]] = defaultdict(list)
    for h in holdings:
        groups[h["currency"]].append(h)

    # Realized P/L from all trades (closed positions too)
    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    states = compute_states(trades)
    ticker_market = {t.ticker: (t.market or quotes.market_of(t.ticker)) for t in trades}
    realized_by_currency: dict[str, float] = defaultdict(float)
    for ticker, st in states.items():
        currency = quotes.currency_of(ticker_market.get(ticker) or quotes.market_of(ticker))
        realized_by_currency[currency] += st.realized_pl

    # Current-year ("this year") realized P/L: replay trades chronologically and
    # count only the realized delta from sells dated in the current year.
    current_year = date.today().year
    year_realized_by_currency: dict[str, float] = defaultdict(float)
    yr_states: dict[str, HoldingState] = {}
    for tr in sorted(trades, key=lambda t: (t.trade_date, t.id)):
        st = yr_states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
        before = st.realized_pl
        _apply_trade(st, tr)
        if tr.trade_date.year == current_year:
            currency = quotes.currency_of(tr.market or quotes.market_of(tr.ticker))
            year_realized_by_currency[currency] += st.realized_pl - before

    # Dividend income grouped by currency — total and current-year.
    dividends_by_currency: dict[str, float] = defaultdict(float)
    year_dividends_by_currency: dict[str, float] = defaultdict(float)
    for div in db.query(Dividend).filter(Dividend.user_id == user_id).all():
        currency = quotes.currency_of(div.market or quotes.market_of(div.ticker))
        dividends_by_currency[currency] += div.amount
        if div.pay_date.year == current_year:
            year_dividends_by_currency[currency] += div.amount

    all_currencies = (
        set(groups)
        | set(realized_by_currency)
        | set(dividends_by_currency)
    )

    summaries: list[dict] = []
    for currency in all_currencies:
        items = groups.get(currency, [])
        total_cost = sum(h["cost_basis"] for h in items)
        # When MIS returns no price for ANY position (transient failure),
        # report null for live-data fields so the UI shows "—" instead of a
        # fake -100% loss. Cost / realized / dividends still render normally.
        priced = [h for h in items if h["market_value"] is not None]
        if items and not priced:
            total_value: float | None = None
            total_pl: float | None = None
            total_pl_pct: float | None = None
            today_pl: float | None = None
            today_pl_pct: float | None = None
        else:
            total_value = sum((h["market_value"] or 0.0) for h in items)
            # Net of estimated exit costs, so it equals the sum of each
            # position's 損益試算 (not the gross 市值 − 成本).
            total_pl = sum((h["unrealized_pl"] or 0.0) for h in items)
            total_pl_pct = (total_pl / total_cost * 100) if total_cost > 0 else 0.0
            today_pl = sum((h["today_change"] or 0.0) for h in items)
            prev_value = total_value - today_pl
            # None (not 0%) when there's no positive prior value to divide by,
            # so a real today's move isn't misreported as a flat 0%.
            today_pl_pct = (today_pl / prev_value * 100) if prev_value > 0 else None
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
                "year_earned": (
                    year_realized_by_currency.get(currency, 0.0)
                    + year_dividends_by_currency.get(currency, 0.0)
                ),
                "year": current_year,
                "holdings_count": len(items),
            }
        )

    # Stable order: TWD first then USD, then anything else alphabetically
    order = {"TWD": 0, "USD": 1}
    summaries.sort(key=lambda s: (order.get(s["currency"], 99), s["currency"]))
    return summaries


def build_overview(db: Session, user_id: str) -> dict:
    """Per-market summary cards (TW + US) plus a combined net worth in both
    NT$ and US$. The combined figures are null when the FX rate is unavailable,
    or while a market that holds positions has no live quote (so we never show a
    fabricated total). Shared by the iOS overview endpoint and the web dashboard.
    """
    holdings = build_holdings(db, user_id)
    summaries = summarize(holdings, db, user_id)
    by_currency = {s["currency"]: s for s in summaries}
    tw = by_currency.get("TWD")
    us = by_currency.get("USD")

    rate, asof = fx.get_usd_twd()
    tw_value = tw["total_value"] if tw else None
    us_value = us["total_value"] if us else None

    combined_twd: float | None = None
    combined_usd: float | None = None
    tw_missing = tw is not None and tw_value is None
    us_missing = us is not None and us_value is None
    if rate and not tw_missing and not us_missing:
        t = tw_value or 0.0
        u = us_value or 0.0
        combined_twd = t + u * rate
        combined_usd = u + t / rate

    return {
        "tw": tw,
        "us": us,
        "fx": {"usd_twd": rate, "asof": asof},
        "combined": {"twd": combined_twd, "usd": combined_usd},
    }


def build_realized_history(db: Session, user_id: str, days: int = 180) -> dict[str, list[dict]]:
    """Daily cumulative realized P/L per currency.

    Walks trades chronologically and accumulates the realized P/L delta from
    each sell. Trades that happened *before* the visible window are folded
    into the starting balance so the chart picks up at the right level.
    """
    end = date.today()
    start = end - timedelta(days=days)
    trades = sorted(
        db.query(Trade).filter(Trade.user_id == user_id).all(),
        key=lambda t: (t.trade_date, t.id),
    )
    if not trades:
        return {}

    states: dict[str, HoldingState] = {}
    cumulative: dict[str, float] = defaultdict(float)
    daily: dict[str, list[dict]] = defaultdict(list)

    # Seed every currency that has any trades, so a flat line shows up
    # even before its first event in the visible window.
    for tr in trades:
        currency = quotes.currency_of(tr.market or quotes.market_of(tr.ticker))
        cumulative.setdefault(currency, 0.0)

    idx = 0
    # Fold pre-window history into the starting balance.
    while idx < len(trades) and trades[idx].trade_date < start:
        tr = trades[idx]
        state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
        before = state.realized_pl
        _apply_trade(state, tr)
        currency = quotes.currency_of(tr.market or quotes.market_of(tr.ticker))
        cumulative[currency] += state.realized_pl - before
        idx += 1

    cursor = start
    while cursor <= end:
        while idx < len(trades) and trades[idx].trade_date == cursor:
            tr = trades[idx]
            state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
            before = state.realized_pl
            _apply_trade(state, tr)
            currency = quotes.currency_of(tr.market or quotes.market_of(tr.ticker))
            cumulative[currency] += state.realized_pl - before
            idx += 1

        for currency, total in cumulative.items():
            daily[currency].append({"date": cursor, "value": total})
        cursor += timedelta(days=1)

    return dict(daily)


def build_earnings_history(db: Session, user_id: str, days: int = 180) -> dict[str, list[dict]]:
    """Daily cumulative realized P/L, dividends, and total earned per currency.

    Walks both trades and dividends chronologically, accumulating per-currency
    deltas. Events before the visible window are folded into the starting
    balance so the chart picks up at the right level.
    """
    end = date.today()
    start = end - timedelta(days=days)

    trades = sorted(
        db.query(Trade).filter(Trade.user_id == user_id).all(),
        key=lambda t: (t.trade_date, t.id),
    )
    dividends = sorted(
        db.query(Dividend).filter(Dividend.user_id == user_id).all(),
        key=lambda d: (d.pay_date, d.id),
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
        currencies.add(quotes.currency_of(tr.market or quotes.market_of(tr.ticker)))
    for d in dividends:
        currencies.add(quotes.currency_of(d.market or quotes.market_of(d.ticker)))
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
        currency = quotes.currency_of(tr.market or quotes.market_of(tr.ticker))
        cum_realized[currency] += state.realized_pl - before
        t_idx += 1
    while d_idx < len(dividends) and dividends[d_idx].pay_date < start:
        d = dividends[d_idx]
        currency = quotes.currency_of(d.market or quotes.market_of(d.ticker))
        cum_dividends[currency] += d.amount
        d_idx += 1

    cursor = start
    while cursor <= end:
        while t_idx < len(trades) and trades[t_idx].trade_date == cursor:
            tr = trades[t_idx]
            state = states.setdefault(tr.ticker, HoldingState(ticker=tr.ticker))
            before = state.realized_pl
            _apply_trade(state, tr)
            currency = quotes.currency_of(tr.market or quotes.market_of(tr.ticker))
            cum_realized[currency] += state.realized_pl - before
            t_idx += 1
        while d_idx < len(dividends) and dividends[d_idx].pay_date == cursor:
            d = dividends[d_idx]
            currency = quotes.currency_of(d.market or quotes.market_of(d.ticker))
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


# Computed value-history series cached per (user, market, period): the build
# sweeps yfinance history for every relevant ticker, which is seconds of work
# even warm — far too slow to redo on every poll or tab switch.
_VALUE_HISTORY_TTL = 600.0
_value_history_cache: dict[tuple[str, str, str], tuple[float, list[dict]]] = {}
_value_history_lock = Lock()


def _window_start(period: str) -> str:
    """Approximate first charted day for a period tab (ISO). Used to skip
    tickers whose position was closed before the window — fetching their
    price history is pure waste. MAX keeps every ticker."""
    days = {"5d": 7, "1mo": 32, "3mo": 93, "6mo": 184,
            "1y": 366, "2y": 731, "5y": 1827}
    if period == "ytd":
        return date(date.today().year, 1, 1).isoformat()
    if period in days:
        return (date.today() - timedelta(days=days[period])).isoformat()
    return "1900-01-01"  # max


def build_value_history(
    db: Session, user_id: str, market: str, period: str = "1y"
) -> list[dict]:
    """Total market value of the user's holdings in one market per trading
    day — the net-worth curve the mobile app charts with period tabs.

    For each ticker ever traded in the market, shares held on each day are
    replayed from the trade log and priced at that day's close (cached
    yfinance history). Days where a ticker has no bar — holiday, IPO gap,
    suspension — carry its last known close forward. Days before the first
    position existed are trimmed so short periods aren't a flat zero line.
    """
    from concurrent.futures import ThreadPoolExecutor

    from . import stock_info

    cache_key = (user_id, market, period)
    now = time.time()
    with _value_history_lock:
        hit = _value_history_cache.get(cache_key)
        if hit and now - hit[0] < _VALUE_HISTORY_TTL:
            return hit[1]

    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    mtrades = [
        t for t in trades if (t.market or quotes.market_of(t.ticker)) == market
    ]
    if not mtrades:
        return []

    # Per-ticker signed share deltas in trade order.
    deltas: dict[str, list[tuple[date, float]]] = defaultdict(list)
    for t in sorted(mtrades, key=lambda t: (t.trade_date, t.id)):
        deltas[t.ticker].append(
            (t.trade_date, t.shares if t.type == "buy" else -t.shares)
        )

    # Drop tickers that can't touch the window: no shares held entering it
    # and no trades inside it. (Deltas are date-ordered, so the first delta
    # past the window start means the ticker traded within the window.)
    win_start = _window_start(period)

    def _active(tdeltas: list[tuple[date, float]]) -> bool:
        shares = 0.0
        for d, delta in tdeltas:
            if d.isoformat() > win_start:
                return True
            shares += delta
        return shares > 1e-9

    deltas = {tk: td for tk, td in deltas.items() if _active(td)}
    if not deltas:
        return []

    # Daily closes per ticker, fetched concurrently (each call is cached with
    # a 30-minute TTL in stock_info, so repeat polls are cheap).
    with ThreadPoolExecutor(max_workers=8) as ex:
        hist = dict(
            zip(deltas, ex.map(lambda tk: stock_info.get_history(tk, period), deltas))
        )

    # Union of bar dates across the market's tickers, as ISO strings, starting
    # at this market's first trade — with period=max the bars reach back to
    # each ticker's IPO, decades before the user held anything.
    first_trade = min(d for td in deltas.values() for d, _ in td).isoformat()
    dates = sorted(
        d
        for d in {b["date"] for bars in hist.values() for b in bars}
        if d >= first_trade
    )
    if not dates:
        return []

    totals = dict.fromkeys(dates, 0.0)
    for ticker, tdeltas in deltas.items():
        close_by_date = {
            b["date"]: b["close"] for b in hist[ticker] if b.get("close") is not None
        }
        shares = 0.0
        last_close = None
        i = 0
        for d in dates:
            # Deltas dated on/before d (including any before the window) apply.
            while i < len(tdeltas) and tdeltas[i][0].isoformat() <= d:
                shares += tdeltas[i][1]
                i += 1
            last_close = close_by_date.get(d, last_close)
            if shares > 1e-9 and last_close:
                totals[d] += shares * last_close

    out = [{"date": d, "total": round(totals[d], 2)} for d in dates]
    first = next((i for i, row in enumerate(out) if row["total"] > 0), None)
    result = out[first:] if first is not None else []
    with _value_history_lock:
        _value_history_cache[cache_key] = (now, result)
    return result
