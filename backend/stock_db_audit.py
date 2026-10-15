"""Read-only consistency audit for the stock tracker's TW and US trades.

Run from the repository root: python backend/stock_db_audit.py
Use --sqlite backend/data/trades.db to inspect a local snapshot instead.
No database records are created, updated, or deleted.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import date
from pathlib import Path
import sys

from sqlalchemy import create_engine, text


def audit(rows: list[dict]) -> list[str]:
    problems: list[str] = []
    seen: dict[tuple, int] = {}
    grouped: dict[tuple[str, str, str], list[dict]] = defaultdict(list)
    ticker_markets: dict[tuple[str, str], set[str]] = defaultdict(set)
    today = date.today()

    for row in rows:
        if isinstance(row["trade_date"], str):
            row["trade_date"] = date.fromisoformat(row["trade_date"])
        user = row["user_id"]
        market = (row["market"] or "").upper()
        ticker = (row["ticker"] or "").strip().upper()
        label = f"trade #{row['id']} ({market}/{ticker})"
        if market not in {"TW", "US"}:
            problems.append(f"{label}: invalid market")
        if not ticker or ticker != row["ticker"]:
            problems.append(f"{label}: empty or noncanonical ticker")
        if row["type"] not in {"buy", "sell"}:
            problems.append(f"{label}: invalid trade type")
        if row["shares"] is None or row["shares"] <= 0:
            problems.append(f"{label}: shares must be positive")
        if row["price"] is None or row["price"] <= 0:
            problems.append(f"{label}: price must be positive")
        if row["fee"] is not None and row["fee"] < 0:
            problems.append(f"{label}: negative fee")
        if row["trade_date"] is None or row["trade_date"] > today:
            problems.append(f"{label}: missing or future trade date")
        key = (user, market, ticker, row["type"], row["shares"],
               row["price"], row["trade_date"], row["fee"])
        if key in seen:
            problems.append(f"{label}: possible duplicate of trade #{seen[key]}")
        else:
            seen[key] = row["id"]
        grouped[(user, market, ticker)].append(row)
        ticker_markets[(user, ticker)].add(market)

    for (user, ticker), markets in ticker_markets.items():
        if len(markets) > 1:
            problems.append(f"{ticker}: recorded in multiple markets {sorted(markets)} for one user")

    for (_, market, ticker), trades in grouped.items():
        balance = 0.0
        for row in sorted(trades, key=lambda r: (r["trade_date"] or date.min, r["id"])):
            if row["type"] not in {"buy", "sell"} or not row["shares"] or row["shares"] <= 0:
                continue
            balance += row["shares"] if row["type"] == "buy" else -row["shares"]
            if balance < -1e-8:
                problems.append(f"trade #{row['id']} ({market}/{ticker}): sale exceeds recorded shares by {-balance:g}")
        print(f"  {market:2} {ticker:12} {balance:,.6f} shares")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sqlite", type=Path, help="inspect a local SQLite file instead of DATABASE_URL")
    args = parser.parse_args()

    if args.sqlite:
        db_file = args.sqlite.resolve()
        if not db_file.is_file():
            parser.error(f"file does not exist: {db_file}")
        engine = create_engine(f"sqlite:///file:{db_file}?mode=ro&uri=true")
    else:
        from dotenv import load_dotenv
        import os
        load_dotenv(Path(__file__).resolve().parent / ".env")
        url = os.getenv("DATABASE_URL", "")
        if not url:
            parser.error("DATABASE_URL is unset; pass --sqlite for a local snapshot")
        if url.startswith("postgres://"):
            url = "postgresql+psycopg://" + url[len("postgres://"):]
        elif url.startswith("postgresql://"):
            url = "postgresql+psycopg://" + url[len("postgresql://"):]
        engine = create_engine(url, connect_args={"connect_timeout": 8})

    try:
        with engine.connect() as connection:
            if not args.sqlite:
                connection.execute(text("SET TRANSACTION READ ONLY"))
            rows = [dict(r) for r in connection.execute(text(
                "SELECT id, user_id, market, ticker, type, shares, price, "
                "trade_date, fee FROM trades ORDER BY user_id, market, ticker, trade_date, id"
            )).mappings()]
            dividends = [dict(r) for r in connection.execute(text(
                "SELECT user_id, market, ticker, COUNT(*) AS n FROM dividends "
                "GROUP BY user_id, market, ticker"
            )).mappings()]
    except Exception as exc:
        print(f"Database unavailable: {type(exc).__name__}: {str(exc).splitlines()[0]}", file=sys.stderr)
        return 2
    finally:
        engine.dispose()

    print(f"Auditing {len(rows)} trades and {sum(d['n'] for d in dividends)} dividends")
    print("Positions computed from recorded trades:")
    problems = audit(rows)
    for d in dividends:
        if d["market"] not in {"TW", "US"}:
            problems.append(f"dividends for {d['ticker']}: invalid market {d['market']}")
    print(f"\n{len(problems)} potential issue(s)")
    for problem in problems:
        print(f"- {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
