from __future__ import annotations

import csv
import io
from datetime import date, datetime
from typing import Iterable

from sqlalchemy.orm import Session

from ..database import Dividend, Trade


TRADE_COLUMNS = ["type", "ticker", "shares", "price", "trade_date", "fee", "notes"]
DIVIDEND_COLUMNS = ["ticker", "amount", "pay_date", "notes"]
PORTFOLIO_COLUMNS = [
    "kind",
    "type",
    "ticker",
    "shares",
    "price",
    "date",
    "fee",
    "amount",
    "notes",
]


def trades_to_csv(trades: Iterable[Trade]) -> str:
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=TRADE_COLUMNS)
    writer.writeheader()
    for t in trades:
        writer.writerow(
            {
                "type": t.type,
                "ticker": t.ticker,
                "shares": t.shares,
                "price": t.price,
                "trade_date": t.trade_date.isoformat(),
                "fee": t.fee,
                "notes": t.notes or "",
            }
        )
    return buf.getvalue()


def dividends_to_csv(dividends: Iterable[Dividend]) -> str:
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=DIVIDEND_COLUMNS)
    writer.writeheader()
    for d in dividends:
        writer.writerow(
            {
                "ticker": d.ticker,
                "amount": d.amount,
                "pay_date": d.pay_date.isoformat(),
                "notes": d.notes or "",
            }
        )
    return buf.getvalue()


def _parse_date(s: str) -> date:
    s = s.strip()
    for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%m/%d/%Y"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    raise ValueError(f"Unrecognized date: {s!r}")


def _required(row: dict, key: str, line: int) -> str:
    val = row.get(key)
    if val is None or str(val).strip() == "":
        raise ValueError(f"Line {line}: missing required column '{key}'")
    return str(val).strip()


def parse_trades_csv(text: str) -> list[Trade]:
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None:
        raise ValueError("CSV is empty or missing a header row")
    missing = {"type", "ticker", "shares", "price", "trade_date"} - set(reader.fieldnames)
    if missing:
        raise ValueError(f"CSV is missing required columns: {sorted(missing)}")

    out: list[Trade] = []
    for i, row in enumerate(reader, start=2):
        if not any((row.get(c) or "").strip() for c in row):
            continue  # skip blank lines
        type_ = _required(row, "type", i).lower()
        if type_ not in ("buy", "sell"):
            raise ValueError(f"Line {i}: type must be 'buy' or 'sell', got {type_!r}")
        ticker = _required(row, "ticker", i).upper()
        try:
            shares = float(_required(row, "shares", i))
            price = float(_required(row, "price", i))
        except ValueError as e:
            raise ValueError(f"Line {i}: invalid number ({e})")
        if shares <= 0 or price <= 0:
            raise ValueError(f"Line {i}: shares and price must be > 0")
        fee_raw = (row.get("fee") or "0").strip()
        try:
            fee = float(fee_raw) if fee_raw else 0.0
        except ValueError:
            raise ValueError(f"Line {i}: invalid fee {fee_raw!r}")
        if fee < 0:
            raise ValueError(f"Line {i}: fee must be >= 0")
        notes = (row.get("notes") or "").strip() or None
        out.append(
            Trade(
                type=type_,
                ticker=ticker,
                shares=shares,
                price=price,
                trade_date=_parse_date(_required(row, "trade_date", i)),
                fee=fee,
                notes=notes,
            )
        )
    return out


def parse_dividends_csv(text: str) -> list[Dividend]:
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None:
        raise ValueError("CSV is empty or missing a header row")
    missing = {"ticker", "amount", "pay_date"} - set(reader.fieldnames)
    if missing:
        raise ValueError(f"CSV is missing required columns: {sorted(missing)}")

    out: list[Dividend] = []
    for i, row in enumerate(reader, start=2):
        if not any((row.get(c) or "").strip() for c in row):
            continue
        ticker = _required(row, "ticker", i).upper()
        try:
            amount = float(_required(row, "amount", i))
        except ValueError as e:
            raise ValueError(f"Line {i}: invalid amount ({e})")
        if amount <= 0:
            raise ValueError(f"Line {i}: amount must be > 0")
        notes = (row.get("notes") or "").strip() or None
        out.append(
            Dividend(
                ticker=ticker,
                amount=amount,
                pay_date=_parse_date(_required(row, "pay_date", i)),
                notes=notes,
            )
        )
    return out


def insert_trades(db: Session, trades: list[Trade]) -> int:
    for t in trades:
        db.add(t)
    db.commit()
    return len(trades)


def insert_dividends(db: Session, dividends: list[Dividend]) -> int:
    for d in dividends:
        db.add(d)
    db.commit()
    return len(dividends)


def portfolio_to_csv(
    trades: Iterable[Trade], dividends: Iterable[Dividend]
) -> str:
    """One unified CSV with a ``kind`` column. Trades first, then dividends,
    each section sorted newest-first."""
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=PORTFOLIO_COLUMNS)
    writer.writeheader()
    for t in trades:
        writer.writerow(
            {
                "kind": "trade",
                "type": t.type,
                "ticker": t.ticker,
                "shares": t.shares,
                "price": t.price,
                "date": t.trade_date.isoformat(),
                "fee": t.fee,
                "amount": "",
                "notes": t.notes or "",
            }
        )
    for d in dividends:
        writer.writerow(
            {
                "kind": "dividend",
                "type": "",
                "ticker": d.ticker,
                "shares": "",
                "price": "",
                "date": d.pay_date.isoformat(),
                "fee": "",
                "amount": d.amount,
                "notes": d.notes or "",
            }
        )
    return buf.getvalue()


def parse_portfolio_csv(text: str) -> tuple[list[Trade], list[Dividend]]:
    """Parse the unified portfolio CSV.

    Each row's ``kind`` column dispatches to a Trade or Dividend record.
    Returns (trades, dividends) ready to be inserted.

    Trades come back sorted by (date asc, buy-before-sell). This is the
    canonical order avg-cost / FIFO calculations expect: when a CSV is
    re-imported, auto-increment IDs end up in the right order so the
    matching logic produces the same realized P/L as before.
    """
    reader = csv.DictReader(io.StringIO(text))
    if reader.fieldnames is None:
        raise ValueError("CSV is empty or missing a header row")
    if "kind" not in reader.fieldnames:
        raise ValueError(
            "CSV is missing the 'kind' column. Header must include "
            "kind, ticker, date plus the kind-specific fields."
        )

    trades: list[Trade] = []
    dividends: list[Dividend] = []
    for i, row in enumerate(reader, start=2):
        if not any((row.get(c) or "").strip() for c in row):
            continue
        kind = (row.get("kind") or "").strip().lower()
        ticker = _required(row, "ticker", i).upper()
        date_str = _required(row, "date", i)
        notes = (row.get("notes") or "").strip() or None

        if kind == "trade":
            type_ = _required(row, "type", i).lower()
            if type_ not in ("buy", "sell"):
                raise ValueError(
                    f"Line {i}: trade type must be 'buy' or 'sell', got {type_!r}"
                )
            try:
                shares = float(_required(row, "shares", i))
                price = float(_required(row, "price", i))
            except ValueError as e:
                raise ValueError(f"Line {i}: invalid number ({e})")
            if shares <= 0 or price <= 0:
                raise ValueError(f"Line {i}: shares and price must be > 0")
            fee_raw = (row.get("fee") or "0").strip()
            try:
                fee = float(fee_raw) if fee_raw else 0.0
            except ValueError:
                raise ValueError(f"Line {i}: invalid fee {fee_raw!r}")
            if fee < 0:
                raise ValueError(f"Line {i}: fee must be >= 0")
            trades.append(
                Trade(
                    type=type_,
                    ticker=ticker,
                    shares=shares,
                    price=price,
                    trade_date=_parse_date(date_str),
                    fee=fee,
                    notes=notes,
                )
            )
        elif kind == "dividend":
            try:
                amount = float(_required(row, "amount", i))
            except ValueError as e:
                raise ValueError(f"Line {i}: invalid amount ({e})")
            if amount <= 0:
                raise ValueError(f"Line {i}: amount must be > 0")
            dividends.append(
                Dividend(
                    ticker=ticker,
                    amount=amount,
                    pay_date=_parse_date(date_str),
                    notes=notes,
                )
            )
        else:
            raise ValueError(
                f"Line {i}: kind must be 'trade' or 'dividend', got {kind!r}"
            )

    # Canonical ordering for FIFO/avg-cost correctness on re-import:
    # within a single trade_date, buys must precede sells.
    trades.sort(key=lambda t: (t.trade_date, 0 if t.type == "buy" else 1))
    dividends.sort(key=lambda d: d.pay_date)
    return trades, dividends
