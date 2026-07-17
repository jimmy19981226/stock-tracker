"""Dividend calendar — 除權息行事曆 + projected income.

Builds, from the user's current holdings:

  * projected annual dividend income per currency (trailing-12-month
    per-share payouts × shares held now, falling back to Yahoo's forward
    ``dividendRate`` for tickers with no payment history),
  * a 12-month forward calendar: each historical payment inside the last
    year is projected onto its month's next occurrence (handles TW's
    annual 除息, US quarterlies, and monthly-pay ETFs alike), and
  * upcoming ex-dividend dates Yahoo already knows about.

Everything reads through stock_info's caches, so repeat requests are cheap.
"""
from __future__ import annotations

from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta

from sqlalchemy.orm import Session

from ..database import Trade
from . import portfolio, quotes, stock_info


def build_dividend_calendar(db: Session, user_id: str) -> dict:
    trades = db.query(Trade).filter(Trade.user_id == user_id).all()
    states = portfolio.compute_states(trades)
    ticker_market = {
        t.ticker: (t.market or quotes.market_of(t.ticker)) for t in trades
    }
    held = {tk: st.shares for tk, st in states.items() if st.shares > 1e-9}
    if not held:
        return {"projected_annual": [], "months": [], "upcoming": []}

    tickers = sorted(held)
    with ThreadPoolExecutor(max_workers=8) as ex:
        div_hist = dict(zip(tickers, ex.map(stock_info.get_dividend_history, tickers)))
        fundamentals = dict(zip(tickers, ex.map(stock_info.get_fundamentals, tickers)))

    today = date.today()
    year_ago = (today - timedelta(days=365)).isoformat()

    annual_by_currency: dict[str, float] = defaultdict(float)
    month_items: dict[str, list[dict]] = defaultdict(list)
    upcoming: list[dict] = []

    for tk in tickers:
        shares = held[tk]
        market = ticker_market.get(tk) or quotes.market_of(tk)
        currency = quotes.currency_of(market)
        recent = [p for p in div_hist.get(tk, []) if p["date"] > year_ago]

        # Trailing 12m per-share payout; forward dividendRate as fallback for
        # tickers whose history Yahoo doesn't carry.
        annual_ps = sum(p["amount"] for p in recent)
        if annual_ps <= 0:
            rate = (fundamentals.get(tk) or {}).get("dividend_rate")
            annual_ps = float(rate) if rate else 0.0
        if annual_ps > 0:
            annual_by_currency[currency] += annual_ps * shares

        # Project each of last year's payments onto that month's next
        # occurrence within the coming 12 months.
        for p in recent:
            pay_month = int(p["date"][5:7])
            year = today.year if pay_month >= today.month else today.year + 1
            month_key = f"{year:04d}-{pay_month:02d}"
            month_items[month_key].append(
                {
                    "ticker": tk,
                    "market": market,
                    "currency": currency,
                    "amount": round(p["amount"] * shares, 2),
                    "per_share": p["amount"],
                }
            )

        # A future ex-date Yahoo has announced beats any projection.
        ex_date = (fundamentals.get(tk) or {}).get("ex_dividend_date")
        if ex_date and ex_date >= today.isoformat():
            last_ps = recent[-1]["amount"] if recent else None
            upcoming.append(
                {
                    "ticker": tk,
                    "market": market,
                    "currency": currency,
                    "ex_date": ex_date,
                    "amount": round(last_ps * shares, 2) if last_ps else None,
                    "per_share": last_ps,
                }
            )

    months = []
    for i in range(12):
        m = today.month + i
        key = f"{today.year + (m - 1) // 12:04d}-{(m - 1) % 12 + 1:02d}"
        items = sorted(month_items.get(key, []), key=lambda r: -r["amount"])
        totals: dict[str, float] = defaultdict(float)
        for it in items:
            totals[it["currency"]] += it["amount"]
        months.append(
            {
                "month": key,
                "items": items,
                "totals": [
                    {"currency": c, "amount": round(v, 2)}
                    for c, v in sorted(totals.items())
                ],
            }
        )

    upcoming.sort(key=lambda r: r["ex_date"])
    return {
        "projected_annual": [
            {"currency": c, "amount": round(v, 2)}
            for c, v in sorted(annual_by_currency.items())
        ],
        "months": months,
        "upcoming": upcoming,
    }
