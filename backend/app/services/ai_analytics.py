"""Account-scoped, deterministic calculations for natural-language questions."""
from __future__ import annotations

from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from decimal import Decimal
import re

from ..database import Dividend, Trade
from . import performance, quotes, stock_info


def align_relative_window(tool: str, args: dict, message: str) -> dict:
    """Anchor unambiguous relative requests on the server's calendar.

    A model can misread 'last month' and still produce a valid date string.
    Explicit years/dates or multiple different periods are left to the tools.
    """
    if tool not in {"get_trades", "get_dividends", "get_record_summary", "get_performance",
                    "compare_performance", "get_performance_attribution"}:
        return args
    if re.search(r"\b(?:19|20)\d{2}\b|\d{4}-\d{2}-\d{2}", message):
        return args
    presets = {
        "last_month": r"\b(?:last|previous)\s+month\b|上個月|上个月|上月",
        "this_month": r"\bthis\s+month\b|本月|這個月|这个月",
        "last_year": r"\b(?:last|previous)\s+year\b|去年",
        "this_year": r"\bthis\s+year\b|\byear.to.date\b|今年",
        "2w": r"\b(?:last|past|this|these)\s+(?:two|2)\s*weeks?\b|\b(?:last|past)\s+fortnight\b|(?:最近|過去|过去|這|这)(?:兩|两|二|2)週|(?:最近|過去|过去)(?:兩|两|二|2)周",
        "7d": r"\b(?:last|past)\s+(?:seven|7)\s*days?\b",
    }
    found = [period for period, pattern in presets.items() if re.search(pattern, message, re.IGNORECASE)]
    if len(found) != 1:
        return args
    # A comparison may intentionally request its previous window separately.
    if tool == "get_performance" and re.search(r"\bcompare|\bversus\b|\bvs\b|\bpreceding\b|比較|比较", message, re.IGNORECASE):
        return args
    corrected = {k: v for k, v in args.items() if k not in {"start_date", "end_date", "year"}}
    corrected["period"] = found[0]
    if tool == "compare_performance":
        corrected.pop("previous_start_date", None)
        corrected.pop("previous_end_date", None)
    return corrected


def date_range(period: str = "all_time", *, kind: str = "records",
               start_date: str | None = None, end_date: str | None = None) -> dict:
    """Records include both dates; performance measures (opening, closing]."""
    today = date.today()
    if kind not in {"records", "performance"}:
        raise ValueError("kind must be records or performance")
    if start_date is not None or end_date is not None:
        if kind == "performance" and (not start_date or not end_date):
            raise ValueError("Performance needs both start_date and end_date")
        try:
            start = date.fromisoformat(start_date) if start_date else None
            end = date.fromisoformat(end_date) if end_date else today
        except (TypeError, ValueError) as exc:
            raise ValueError("Dates must use YYYY-MM-DD") from exc
        if start and (start > end or (kind == "performance" and start == end)):
            raise ValueError("Invalid date range: start must precede end")
        if kind == "performance" and not start:
            raise ValueError("Performance needs both start_date and end_date")
        if end > today:
            raise ValueError("end_date cannot be in the future")
    elif period in {"all_time", "max"}:
        start, end = None, today
    elif period in {"this_month", "last_month", "this_year", "last_year", "ytd"}:
        end = today
        if period == "this_month":
            start = today.replace(day=1)
        elif period == "last_month":
            end = today.replace(day=1) - timedelta(days=1)
            start = end.replace(day=1)
        elif period in {"this_year", "ytd"}:
            start = today.replace(month=1, day=1)
        else:
            start, end = date(today.year - 1, 1, 1), date(today.year - 1, 12, 31)
        if kind == "performance":
            start -= timedelta(days=1)
    else:
        days = {"5d": 5, "7d": 7, "2w": 14, "14d": 14, "1mo": 30,
                "3mo": 90, "6mo": 180, "1y": 365, "2y": 730, "5y": 1825}.get(period)
        if days is None:
            raise ValueError(f"Unsupported period: {period}")
        end = today
        start = today - timedelta(days=days if kind == "performance" else days - 1)
    return {"start_date": start.isoformat() if start else None, "end_date": end.isoformat(),
            "start_inclusive": kind == "records", "end_inclusive": True,
            "calendar_days": (end - start).days + (kind == "records") if start else None}


def filtered_records(db, user_id: str, model, args: dict):
    bounds = date_range(args.get("period") or "all_time",
                        start_date=args.get("start_date"), end_date=args.get("end_date"))
    if args.get("year") is not None:
        year = int(args["year"])
        start = max(date.fromisoformat(bounds["start_date"]) if bounds["start_date"] else date(year, 1, 1), date(year, 1, 1))
        end = min(date.fromisoformat(bounds["end_date"]), date(year, 12, 31))
        if start > end:
            raise ValueError("year and date filters do not overlap or refer to future records")
        bounds = {**bounds, "start_date": start.isoformat(), "end_date": end.isoformat(), "calendar_days": (end - start).days + 1}
    field = model.trade_date if model is Trade else model.pay_date
    query = db.query(model).filter(model.user_id == user_id)
    if args.get("market"):
        market = str(args["market"]).upper()
        if market not in {"TW", "US"}:
            raise ValueError("market must be TW or US")
        query = query.filter(model.market == market)
    if args.get("ticker"):
        query = query.filter(model.ticker == str(args["ticker"]).strip().upper())
    if model is Trade and args.get("type"):
        side = str(args["type"]).lower()
        if side not in {"buy", "sell"}:
            raise ValueError("type must be buy or sell")
        query = query.filter(Trade.type == side)
    if bounds["start_date"]:
        query = query.filter(field >= date.fromisoformat(bounds["start_date"]))
    query = query.filter(field <= date.fromisoformat(bounds["end_date"]))
    return query.order_by(field.desc(), model.id.desc()).all(), bounds


def _decimal(value) -> Decimal:
    return Decimal(str(value or 0))


def record_summary(db, user_id: str, args: dict, realized_by_sell) -> dict:
    group_by = args.get("group_by") or "market"
    if group_by not in {"market", "ticker", "month"}:
        raise ValueError("group_by must be market, ticker or month")
    # record_type limits the metrics, not just the returned rows.
    record_type = args.get("record_type") or "all"
    if record_type not in {"all", "trades", "dividends"}:
        raise ValueError("record_type must be all, trades or dividends")
    trades, bounds = filtered_records(db, user_id, Trade, args)
    dividends, _ = filtered_records(db, user_id, Dividend, args)
    if record_type == "dividends":
        trades = []
    if record_type == "trades":
        dividends = []
    # Cost basis needs the entire ledger, including purchases before the filter.
    realized = realized_by_sell(db.query(Trade).filter(Trade.user_id == user_id).all())
    buckets, totals = {}, {}

    def bucket(store, key, market, group=None):
        if key not in store:
            store[key] = {"market": market, "currency": quotes.currency_of(market),
                          "trade_count": 0, "dividend_count": 0, "buy_count": 0, "sell_count": 0,
                          **{k: Decimal(0) for k in ("buy_cost", "sell_net_proceeds", "fees",
                                                     "realized_pl", "dividends", "cash_earned")}}
            if group_by != "market" and group is not None:
                store[key][group_by] = group
        return store[key]

    # An empty filter is a known zero, rather than an absent money field that
    # tempts the model to use a row count as an amount.
    known_markets = {args["market"].upper()} if args.get("market") else {
        row[0] for model in (Trade, Dividend)
        for row in db.query(model.market).filter(model.user_id == user_id).distinct().all()}
    for market in known_markets:
        bucket(totals, market, market)

    for row in [*trades, *dividends]:
        market = row.market or quotes.market_of(row.ticker)
        day = row.trade_date if isinstance(row, Trade) else row.pay_date
        group = row.ticker if group_by == "ticker" else day.strftime("%Y-%m") if group_by == "month" else market
        for target in (bucket(buckets, (market, group), market, group), bucket(totals, market, market)):
            if isinstance(row, Trade):
                target["trade_count"] += 1
                target[f"{row.type}_count"] += 1
                gross, fee = _decimal(row.shares) * _decimal(row.price), _decimal(row.fee)
                target["fees"] += fee
                if row.type == "buy":
                    target["buy_cost"] += gross + fee
                else:
                    target["sell_net_proceeds"] += gross - fee
                    target["realized_pl"] += _decimal(realized.get(row.id))
            else:
                target["dividend_count"] += 1
                target["dividends"] += _decimal(row.amount)

    def finish(row):
        row["cash_earned"] = row["realized_pl"] + row["dividends"]
        return {k: float(v.quantize(Decimal("0.01"))) if isinstance(v, Decimal) else v
                for k, v in row.items()}

    groups = [finish(row) for _, row in sorted(buckets.items())]
    offset, limit = max(0, int(args.get("offset") or 0)), max(1, min(int(args.get("limit") or 50), 100))
    page = groups[offset:offset + limit]
    return {"date_range": bounds, "record_type": record_type, "group_by": group_by,
            "totals": [finish(row) for _, row in sorted(totals.items())], "groups": page,
            "matching_trade_count": len(trades), "matching_dividend_count": len(dividends),
            "total_group_count": len(groups), "has_more": offset + len(page) < len(groups),
            "next_offset": offset + len(page) if offset + len(page) < len(groups) else None,
            "complete_totals": True,
            "basis": "Inclusive record dates. Cash earned = FIFO realized P/L + paid dividends; "
                     "not unrealized gains or total portfolio performance. Currencies are separate."}


def performance_report(db, user_id, args):
    bounds = date_range(args.get("period") or "2w", kind="performance",
                        start_date=args.get("start_date"), end_date=args.get("end_date"))
    return performance.build_performance(db, user_id, args["market"], "max" if bounds["start_date"] is None else "custom",
                                         start_date=bounds["start_date"], end_date=bounds["end_date"] if bounds["start_date"] else None)


def compare_performance(db, user_id, args) -> dict:
    current = performance_report(db, user_id, args)
    start, end = current["requested_start_date"], current["requested_end_date"]
    if not start:
        raise ValueError("Choose a bounded period to compare")
    if args.get("previous_start_date") or args.get("previous_end_date"):
        previous_start, previous_end = args.get("previous_start_date"), args.get("previous_end_date")
        if not previous_start or not previous_end:
            raise ValueError("Provide both previous_start_date and previous_end_date")
    else:
        start_day, end_day = date.fromisoformat(start), date.fromisoformat(end)
        period = args.get("period")
        if not args.get("start_date") and period == "last_month":
            previous_start, previous_end = (start_day.replace(day=1) - timedelta(days=1)).isoformat(), start
        elif not args.get("start_date") and period == "this_month":
            previous_base = start_day.replace(day=1) - timedelta(days=1)
            previous_start = previous_base.isoformat()
            previous_end = min(previous_base + (end_day - start_day), start_day).isoformat()
        elif not args.get("start_date") and period in {"this_year", "last_year", "ytd"}:
            from dateutil.relativedelta import relativedelta
            previous_start, previous_end = (start_day - relativedelta(years=1)).isoformat(), (end_day - relativedelta(years=1)).isoformat()
        else:
            previous_start, previous_end = (start_day - (end_day - start_day)).isoformat(), start
    previous = performance.build_performance(db, user_id, args["market"], "custom",
                                             start_date=previous_start, end_date=previous_end)
    available = current["status"] == previous["status"] == "ok"
    return {"current": current, "previous": previous,
            "period_pl_change": round(current["period_pl"] - previous["period_pl"], 2) if available else None,
            "twr_change_percentage_points": round(current["twr_pct"] - previous["twr_pct"], 2) if available else None,
            "comparison_available": available,
            "basis": "Rolling windows compare equal duration; month/year periods compare the previous calendar period (to-date when applicable). "
                     "TWR differences are percentage points, not percentage growth."}


def performance_attribution(db, user_id, args) -> dict:
    report = performance_report(db, user_id, args)
    out = {"performance": report, "contributors": [], "reconciled": False,
           "basis": "Security-only portfolio in its native currency. Contributions are buy costs; "
                    "withdrawals are net sales plus paid dividends. Gross trading/price P/L less recorded "
                    "fees plus dividends equals net period P/L. No historical FX attribution."}
    if report["status"] != "ok":
        return out
    opening, closing = date.fromisoformat(report["start_date"]), date.fromisoformat(report["end_date"])
    market = report["market"]
    trades = [t for t in db.query(Trade).filter(Trade.user_id == user_id).all()
              if (t.market or quotes.market_of(t.ticker)) == market and t.trade_date <= closing]
    dividends = [d for d in db.query(Dividend).filter(Dividend.user_id == user_id).all()
                 if (d.market or quotes.market_of(d.ticker)) == market and opening < d.pay_date <= closing]
    by_ticker = defaultdict(list)
    for t in trades:
        by_ticker[t.ticker].append(t)
    tickers = sorted(set(by_ticker) | {d.ticker for d in dividends})
    positions = {}
    for ticker in tickers:
        rows = by_ticker[ticker]
        held = lambda day: max(0, sum(t.shares if t.type == "buy" else -t.shares for t in rows if t.trade_date <= day))
        if held(opening) or held(closing) or any(opening < t.trade_date <= closing for t in rows) or any(d.ticker == ticker for d in dividends):
            positions[ticker] = (held(opening), held(closing))

    def history(ticker):
        return stock_info.get_history(ticker, start_date=(opening - timedelta(days=14)).isoformat(), end_date=closing.isoformat())

    priced = [ticker for ticker, amounts in positions.items() if any(amounts)]
    with ThreadPoolExecutor(max_workers=6) as executor:
        histories = dict(zip(priced, executor.map(history, priced)))
    for ticker, (open_shares, close_shares) in positions.items():
        bars = histories.get(ticker, [])

        def valuation(shares, day):
            if not shares:
                return 0.0, None
            available = sorted((b for b in bars if b["date"] <= day.isoformat() and b.get("close")), key=lambda b: b["date"])
            if not available:
                raise ValueError(f"Attribution price unavailable for {ticker} on {day}")
            return shares * available[-1]["close"], available[-1]["date"]

        open_value, open_asof = valuation(open_shares, opening)
        close_value, close_asof = valuation(close_shares, closing)
        rows = [t for t in by_ticker[ticker] if opening < t.trade_date <= closing]
        buys = sum(t.shares * t.price + t.fee for t in rows if t.type == "buy")
        sales = sum(t.shares * t.price - t.fee for t in rows if t.type == "sell")
        fees = sum(t.fee for t in rows)
        paid = sum(d.amount for d in dividends if d.ticker == ticker)
        net = close_value - open_value - buys + sales + paid
        out["contributors"].append({"ticker": ticker, "currency": report["currency"],
                                    "opening_value": round(open_value, 2), "closing_value": round(close_value, 2),
                                    "opening_price_date": open_asof, "closing_price_date": close_asof,
                                    "buy_cost": round(buys, 2), "sell_net_proceeds": round(sales, 2),
                                    "fees": round(fees, 2), "dividends": round(paid, 2),
                                    "gross_trading_price_pl": round(net - paid + fees, 2), "period_pl": round(net, 2)})
    out["contributors"].sort(key=lambda row: -row["period_pl"])
    out["contributors_total_pl"] = round(sum(row["period_pl"] for row in out["contributors"]), 2)
    out["reconciliation_difference"] = round(out["contributors_total_pl"] - report["period_pl"], 2)
    out["reconciled"] = abs(out["reconciliation_difference"]) <= max(0.02, 0.01 * len(positions))
    if not out["reconciled"]:
        out["contributors"] = []
        out["contributors_total_pl"] = None
        out["reason"] = "Contributor prices do not reconcile with portfolio valuations; retry when history is consistent."
    return out
