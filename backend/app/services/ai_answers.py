"""Render quantitative answers from actual tool values, never model arithmetic.

Evidence lives only in one chat run. References cannot execute expressions or
read another user's data. Qualitative explanation is separate from checked facts.
"""
from __future__ import annotations

import json
import math
import re

_LABELS = {"period_pl": "Profit or loss", "twr_pct": "Time-weighted return", "xirr_pct": "Annualized money-weighted return",
           "currency": "Currency", "start_date": "Start date", "end_date": "End date",
           "requested_start_date": "Requested opening date", "requested_end_date": "Requested closing date",
           "opening_value": "Opening value", "closing_value": "Closing value", "realized_pl": "Realized profit or loss",
           "gross_trading_price_pl": "Trading and price gains before fees", "period_pl_change": "Profit change",
           "twr_change_percentage_points": "Return change", "cash_earned": "Realized gains plus dividends",
           "buy_cost": "Purchase costs", "sell_net_proceeds": "Net sale proceeds", "trade_count": "Trade count",
           "dividend_count": "Payment count", "reconciled": "Contributors match portfolio profit"}
_MONEY_FIELDS = {"amount", "price", "avg_cost", "current_price", "market_value", "cost_basis", "total_value",
                 "period_pl", "period_pl_change", "opening_value", "closing_value", "realized_pl", "unrealized_pl",
                 "cash_earned", "dividends", "fees", "buy_cost", "sell_net_proceeds", "gross_trading_price_pl",
                 "contributions", "withdrawals", "contributors_total_pl"}


def requested_json_fields(question: str) -> list[str] | None:
    """Recognize explicit simple JSON field lists, without interpreting prose."""
    match = re.search(r"\bJSON\s+(?:with|containing)\s+(.+?)(?:\.|$)", question, re.IGNORECASE)
    if not match:
        return None
    text = re.sub(r"\([^)]*\)", "", match.group(1)).strip()
    markets = re.match(r"(US\s+and\s+TW|TW\s+and\s+US)\s+objects?\s+(?:containing|with)\s+(.+)", text, re.IGNORECASE)
    if markets:
        text = markets.group(2)
    fields = [part.strip() for part in re.split(r",|\band\b", text) if part.strip()]
    if not fields or any(not re.fullmatch(r"[A-Za-z_]\w*", field) for field in fields):
        return None
    return [market + "." + field for market in ("US", "TW") for field in fields] if markets else fields


def _currency(source: dict, path: str) -> str | None:
    node, found = source, None
    for part in [None, *path.split(".")[:-1]]:
        if part is not None:
            node = node[int(part)] if isinstance(node, list) else node[part]
        if isinstance(node, dict):
            found = node.get("currency") or {"TW": "TWD", "US": "USD"}.get(node.get("market")) or found
    return found


def _value(source: dict, path: str):
    if not path or len(path) > 250:
        raise ValueError("Provide a scalar dot path from the tool result")
    node = source
    for part in path.split("."):
        if part.startswith("_"):
            raise ValueError("Internal fields cannot be answer facts")
        if isinstance(node, list) and part.isdecimal():
            node = node[int(part)]
        elif isinstance(node, dict) and part in node:
            node = node[part]
        else:
            raise ValueError(f"No source value at {path}")
    if isinstance(node, (dict, list)) or (isinstance(node, float) and not math.isfinite(node)):
        raise ValueError("Answer facts must reference finite scalar values")
    return node


def _assign(out: dict, name: str, value):
    if not re.fullmatch(r"[\w-]+(?:\.[\w-]+)*", name, re.UNICODE) or len(name) > 120:
        raise ValueError("Fact names must be simple labels or dotted JSON keys")
    parts = name.split(".")
    for part in parts[:-1]:
        if part not in out:
            out[part] = {}
        if not isinstance(out[part], dict):
            raise ValueError("Overlapping answer fields")
        out = out[part]
    if parts[-1] in out:
        raise ValueError("Duplicate answer fields")
    out[parts[-1]] = value


def display(value) -> str:
    if value is None:
        return "Unavailable"
    if isinstance(value, bool):
        return "Yes" if value else "No"
    if isinstance(value, (int, float)):
        # Fixed notation preserves full decimal numbers, even small fractions.
        from decimal import Decimal
        return format(Decimal(str(value)), ",f")
    return str(value).replace("|", "\\|").replace("\n", " ")


def render(args: dict, sources: dict[int, dict], question: str = "") -> str:
    facts = args.get("facts")
    if not isinstance(facts, list) or not 1 <= len(facts) <= 60:
        raise ValueError("Provide between 1 and 60 source-backed facts")
    required_fields = requested_json_fields(question)
    style = "json" if required_fields else args.get("format") or "table"
    if style not in {"json", "table"}:
        raise ValueError("format must be json or table")
    explanation = str(args.get("explanation") or "").strip()
    if len(explanation) > 2000 or re.search(r"\d", explanation):
        raise ValueError("Keep explanation qualitative; put all numeric figures in source-backed facts")
    out, rows, used = {}, [], set()
    actual_fields = []
    for fact in facts:
        source_id = fact.get("source_id")
        if isinstance(source_id, bool) or not isinstance(source_id, int) or source_id not in sources:
            raise ValueError("Unknown source_id; use _evidence.source_id from this conversation turn")
        source = sources[source_id]
        if "error" in source:
            raise ValueError("A failed tool result cannot supply answer facts")
        path = str(fact.get("path") or "")
        value = _value(source, path)
        name = str(fact.get("name") or "")
        if re.search(r"\bboth\s+markets\b", question, re.IGNORECASE) and name in {"trade_count", "dividend_count"}:
            scope = source.get("_evidence", {}).get("filters", {})
            if scope.get("market") or scope.get("ticker"):
                raise ValueError("Whole-account counts require get_record_summary or history tools without market/ticker filters")
        _assign(out, name, value)
        actual_fields.append(name)
        field = path.rsplit(".", 1)[-1]
        label = _LABELS.get(field, name.replace("_", " ").replace(".", " · ").capitalize())
        if field in {"start_date", "end_date"} and path.split(".")[0] in {"performance", "current", "previous"}:
            label = "Opening valuation date" if field == "start_date" else "Closing valuation date"
        if name.startswith(("US.", "TW.", "US_", "TW_")):
            label = name[:2] + " · " + label
        formatted = display(value)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            currency = _currency(source, path)
            if field in _MONEY_FIELDS and currency:
                from decimal import Decimal
                amount = Decimal(str(value))
                formatted = currency + " " + (format(amount, ",.2f") if amount.as_tuple().exponent >= -2 else format(amount, ",f"))
            elif field.endswith("percentage_points"):
                formatted += " percentage points"
            elif field.endswith("_pct") or field.startswith("pct_"):
                formatted += "%"
        rows.append((label, formatted))
        used.add(source_id)
    if style == "json":
        if required_fields and set(actual_fields) != set(required_fields):
            raise ValueError("Use exactly these requested JSON fact names: " + ", ".join(required_fields))
        return json.dumps(out, ensure_ascii=False, allow_nan=False)
    answer = (explanation + "\n\n" if explanation else "") + "| Metric | Value |\n| --- | --- |\n"
    answer += "\n".join(f"| {label} | {value} |" for label, value in rows)
    checked_at = max(sources[s]["_evidence"]["retrieved_at"] for s in used)
    return answer + f"\n\nFigures checked against your app data. Retrieved {checked_at}."


def fallback(sources: dict[int, dict], reason: str) -> str:
    """A bounded, truthful partial answer when the model/loop cannot finish."""
    rows = []
    skip = {"portfolio_series", "series", "bars", "points", "lots", "notes", "_evidence", "_sampling", "basis"}

    def collect(node, prefix, depth=0):
        if len(rows) >= 45 or depth > 4:
            return
        if isinstance(node, dict):
            for key, value in node.items():
                if key not in skip:
                    collect(value, f"{prefix} · {key.replace('_', ' ')}", depth + 1)
        elif isinstance(node, list):
            for i, item in enumerate(node[:3]):
                collect(item, f"{prefix} · {i + 1}", depth + 1)
        elif node is not None:
            rows.append((prefix, node))

    names = {"get_portfolio_summary": "Portfolio totals", "get_holdings": "Holdings",
             "get_trades": "Trades", "get_dividends": "Dividends", "get_performance": "Performance",
             "get_record_summary": "Record totals", "compare_performance": "Period comparison",
             "get_performance_attribution": "Performance contributors", "get_stock_info": "Company data"}
    seen = set()
    for source in sources.values():
        if "error" not in source:
            identity = json.dumps({k: v for k, v in source.items() if k != "_evidence"}, sort_keys=True, default=str)
            if identity in seen:
                continue
            seen.add(identity)
            collect(source, names.get(source.get("_evidence", {}).get("tool"), "Available data"))
    if not rows:
        return reason + " Please try again or ask about a smaller date range."
    return reason + " Here is the available data:\n\n| Metric | Value |\n| --- | --- |\n" + "\n".join(
        f"| {label} | {display(value)} |" for label, value in rows)
