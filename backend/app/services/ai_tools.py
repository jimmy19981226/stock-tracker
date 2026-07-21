"""Tool-use layer for the AI assistant (modern function calling).

Instead of only reading a static context dump, the model can call typed tools
mid-conversation: portfolio reads, live quotes, price history, performance,
web search — and two write actions (add_trade / add_dividend) that never touch
the DB directly. Write tools emit an "action" proposal the app renders as an
in-chat confirm card; the records are saved through the normal REST endpoints
only after the user taps Add.

One neutral ``TOOLS`` spec drives all providers; small adapters translate it
to each API's schema. ``run_tool_loop`` is a generator yielding
``("chunk"|"status"|"action", payload)`` events so the SSE endpoint can
stream text, progress labels, and confirm cards with one protocol.
"""
from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone

from ..database import Dividend, SessionLocal, Trade
from . import ai_providers, fx, income, markets, performance, portfolio, quotes, stock_info

_TAIPEI = timezone(timedelta(hours=8))

_MARKET = {"type": "string", "enum": ["TW", "US"]}
_PERIOD = {"type": "string",
           "enum": ["5d", "1mo", "3mo", "6mo", "ytd", "1y", "2y", "5y", "max"]}

# name, description, parameters (JSON schema), label (status text shown in-app
# while the tool runs).
TOOLS: list[dict] = [
    {
        "name": "get_portfolio_summary",
        "description": (
            "Per-currency portfolio totals: market value, cost, unrealized and "
            "realized P/L, dividends collected, today's move, holdings count."
        ),
        "parameters": {"type": "object", "properties": {}},
        "label": "Checking portfolio totals…",
    },
    {
        "name": "get_holdings",
        "description": (
            "Current open positions with live prices and P/L. Optionally filter "
            "to one market (TW or US)."
        ),
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET},
        },
        "label": "Reading holdings…",
    },
    {
        "name": "get_trades",
        "description": (
            "Trade history (buys/sells), newest first, with FIFO open/closed "
            "status. Filter by ticker and/or market."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "market": _MARKET,
                "limit": {"type": "integer", "description": "Max rows (default 20, max 100)"},
            },
        },
        "label": "Reading trade history…",
    },
    {
        "name": "get_dividends",
        "description": "Dividend payments received, newest first. Filter by ticker and/or year.",
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "year": {"type": "integer"},
                "limit": {"type": "integer", "description": "Max rows (default 20, max 100)"},
            },
        },
        "label": "Reading dividends…",
    },
    {
        "name": "get_quote",
        "description": (
            "Live quote for ANY ticker (held or not): price, previous close, "
            "day range, volume. TW tickers are numeric codes like 2330; US are "
            "letter symbols like AAPL."
        ),
        "parameters": {
            "type": "object",
            "properties": {"ticker": {"type": "string"}},
            "required": ["ticker"],
        },
        "label": "Fetching live quote…",
    },
    {
        "name": "get_price_history",
        "description": "Daily closing prices for a ticker over a period (for trends/comparisons).",
        "parameters": {
            "type": "object",
            "properties": {"ticker": {"type": "string"}, "period": _PERIOD},
            "required": ["ticker"],
        },
        "label": "Fetching price history…",
    },
    {
        "name": "get_performance",
        "description": (
            "Performance metrics for one market's portfolio over a period: "
            "time-weighted return (TWR), money-weighted return (XIRR), "
            "benchmark comparison, monthly P&L."
        ),
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET, "period": _PERIOD},
            "required": ["market"],
        },
        "label": "Computing performance…",
    },
    {
        "name": "get_dividend_calendar",
        "description": (
            "Projected annual dividend income, 12-month forward payment "
            "calendar, and known upcoming ex-dividend dates (除權息)."
        ),
        "parameters": {"type": "object", "properties": {}},
        "label": "Building dividend calendar…",
    },
    {
        "name": "get_value_history",
        "description": "Daily total market value of one market's holdings (net-worth curve).",
        "parameters": {
            "type": "object",
            "properties": {"market": _MARKET, "period": _PERIOD},
            "required": ["market"],
        },
        "label": "Charting net worth…",
    },
    {
        "name": "get_fx_rate",
        "description": "Current USD/TWD exchange rate.",
        "parameters": {"type": "object", "properties": {}},
        "label": "Checking FX rate…",
    },
    {
        "name": "get_market_status",
        "description": "Whether the TW and US stock markets are open right now, with local times.",
        "parameters": {"type": "object", "properties": {}},
        "label": "Checking market hours…",
    },
    {
        "name": "search_web",
        "description": (
            "Web search (DuckDuckGo) for fresh information: news, earnings, "
            "dividend announcements, analyst views, macro events. For Taiwan "
            "stocks include both the ticker code and company name in queries."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "queries": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "1-3 concise search queries",
                },
            },
            "required": ["queries"],
        },
        "label": "Searching the web…",
    },
    {
        "name": "add_trade",
        "description": (
            "Propose recording a buy/sell trade. This does NOT save directly: "
            "the app shows the user a confirmation card and saves only after "
            "they tap Add. Use only when the user explicitly asks to record a "
            "trade and has given ticker, shares and price."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": ["buy", "sell"]},
                "ticker": {"type": "string"},
                "shares": {"type": "number"},
                "price": {"type": "number"},
                "date": {"type": "string", "description": "YYYY-MM-DD; default today"},
                "fee": {"type": "number"},
                "notes": {"type": "string"},
            },
            "required": ["type", "ticker", "shares", "price"],
        },
        "label": "Preparing trade for confirmation…",
    },
    {
        "name": "add_dividend",
        "description": (
            "Propose recording a received dividend. This does NOT save "
            "directly: the app shows a confirmation card and saves only after "
            "the user taps Add."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "ticker": {"type": "string"},
                "amount": {"type": "number"},
                "date": {"type": "string", "description": "YYYY-MM-DD; default today"},
                "notes": {"type": "string"},
            },
            "required": ["ticker", "amount"],
        },
        "label": "Preparing dividend for confirmation…",
    },
]

_LABELS = {t["name"]: t["label"] for t in TOOLS}


def status_label(name: str) -> str:
    return _LABELS.get(name, "Working…")


# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------

# Rounded floats keep results compact; long series are downsampled so a "max"
# history can't blow the model's context.
_MAX_POINTS = 90


def _downsample(rows: list[dict], keys: tuple[str, ...]) -> list[dict]:
    slim = [{k: r.get(k) for k in keys} for r in rows]
    if len(slim) <= _MAX_POINTS:
        return slim
    step = len(slim) / _MAX_POINTS
    picked = [slim[int(i * step)] for i in range(_MAX_POINTS)]
    if picked[-1] is not slim[-1]:
        picked.append(slim[-1])  # always keep the latest point
    return picked


def _round(v, nd=2):
    return round(v, nd) if isinstance(v, float) else v


def execute(name: str, args: dict, user_id: str) -> tuple[dict, dict | None]:
    """Run one tool. Returns ``(result_for_model, action_or_None)`` where the
    action is a ParsedRecords-shaped proposal for the app's confirm card.
    Never raises — errors come back as ``{"error": ...}`` so the model can
    recover in-conversation."""
    try:
        return _execute(name, args or {}, user_id)
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"}, None


def _execute(name: str, args: dict, user_id: str) -> tuple[dict, dict | None]:
    today = datetime.now(_TAIPEI).date().isoformat()

    if name == "get_portfolio_summary":
        with SessionLocal() as db:
            holdings = portfolio.build_holdings(db, user_id)
            return {"summaries": portfolio.summarize(holdings, db, user_id)}, None

    if name == "get_holdings":
        with SessionLocal() as db:
            rows = portfolio.build_holdings(db, user_id)
        market = (args.get("market") or "").upper()
        if market:
            rows = [h for h in rows if h["market"] == market]
        keys = ("ticker", "name", "market", "shares", "avg_cost", "current_price",
                "market_value", "cost_basis", "unrealized_pl", "unrealized_pl_pct",
                "today_change", "today_change_pct")
        return {"holdings": [{k: _round(h.get(k)) for k in keys} for h in rows]}, None

    if name == "get_trades":
        from ..routers.trades import _compute_statuses  # lazy: avoid import cycle

        limit = max(1, min(int(args.get("limit") or 20), 100))
        with SessionLocal() as db:
            q = db.query(Trade).filter(Trade.user_id == user_id)
            if args.get("ticker"):
                q = q.filter(Trade.ticker == str(args["ticker"]).strip().upper())
            if args.get("market"):
                q = q.filter(Trade.market == str(args["market"]).upper())
            rows = q.order_by(Trade.trade_date.desc(), Trade.id.desc()).limit(limit).all()
            statuses = _compute_statuses(
                db.query(Trade).filter(Trade.user_id == user_id).all()
            )
        return {"trades": [
            {"type": t.type, "ticker": t.ticker, "shares": t.shares,
             "price": t.price, "date": t.trade_date.isoformat(), "fee": t.fee,
             "market": t.market, "status": statuses.get(t.id, "open"),
             "notes": t.notes}
            for t in rows
        ]}, None

    if name == "get_dividends":
        limit = max(1, min(int(args.get("limit") or 20), 100))
        with SessionLocal() as db:
            q = db.query(Dividend).filter(Dividend.user_id == user_id)
            if args.get("ticker"):
                q = q.filter(Dividend.ticker == str(args["ticker"]).strip().upper())
            rows = q.order_by(Dividend.pay_date.desc(), Dividend.id.desc()).all()
        if args.get("year"):
            rows = [d for d in rows if d.pay_date.year == int(args["year"])]
        return {"dividends": [
            {"ticker": d.ticker, "amount": d.amount,
             "date": d.pay_date.isoformat(), "market": d.market, "notes": d.notes}
            for d in rows[:limit]
        ]}, None

    if name == "get_quote":
        ticker = str(args.get("ticker") or "").strip()
        q = quotes.get_quote(ticker)
        if q is None:
            return {"error": f"No quote found for {ticker!r}"}, None
        return {"quote": {
            "ticker": ticker, "symbol": q.symbol, "name": q.name,
            "price": q.price, "previous_close": q.previous_close,
            "currency": q.currency, "day_open": q.day_open,
            "day_high": q.day_high, "day_low": q.day_low, "volume": q.volume,
        }}, None

    if name == "get_price_history":
        ticker = str(args.get("ticker") or "").strip()
        period = args.get("period") or "1y"
        bars = stock_info.get_history(ticker, period)
        return {"ticker": ticker, "period": period,
                "bars": _downsample(bars, ("date", "close"))}, None

    if name == "get_performance":
        market = (args.get("market") or "TW").upper()
        period = args.get("period") or "1y"
        with SessionLocal() as db:
            return {"performance": performance.build_performance(
                db, user_id, market=market, period=period)}, None

    if name == "get_dividend_calendar":
        with SessionLocal() as db:
            return {"calendar": income.build_dividend_calendar(db, user_id)}, None

    if name == "get_value_history":
        market = (args.get("market") or "TW").upper()
        period = args.get("period") or "1y"
        with SessionLocal() as db:
            rows = portfolio.build_value_history(db, user_id, market=market, period=period)
        return {"market": market, "period": period,
                "points": _downsample(rows, ("date", "total"))}, None

    if name == "get_fx_rate":
        rate, asof = fx.get_usd_twd()
        return {"usd_twd": rate, "asof": asof}, None

    if name == "get_market_status":
        now = datetime.now(_TAIPEI)
        return {
            "today": today,
            "tw_open": markets.is_market_open("TW"),
            "us_open": markets.is_market_open("US"),
            "taipei_time": now.strftime("%Y-%m-%d %H:%M"),
        }, None

    if name == "search_web":
        raw = args.get("queries") or []
        queries = [str(q).strip() for q in raw if str(q).strip()][:3]
        if not queries:
            return {"error": "No queries given"}, None
        return {"results": ai_providers.search_web(queries)}, None

    if name == "add_trade":
        row = {
            "type": str(args.get("type") or "buy").lower(),
            "ticker": str(args.get("ticker") or "").strip().upper(),
            "shares": float(args.get("shares") or 0),
            "price": float(args.get("price") or 0),
            "date": str(args.get("date") or today),
            "fee": float(args.get("fee") or 0),
            "notes": args.get("notes"),
        }
        if not row["ticker"] or row["shares"] <= 0 or row["price"] <= 0:
            return {"error": "add_trade needs ticker, shares > 0 and price > 0"}, None
        action = {"trades": [row], "dividends": [], "notes": ""}
        return {
            "status": "proposed",
            "note": ("A confirmation card is now shown to the user in the app. "
                     "Nothing is saved until they tap Add — tell them to review "
                     "the card and confirm."),
        }, action

    if name == "add_dividend":
        row = {
            "ticker": str(args.get("ticker") or "").strip().upper(),
            "amount": float(args.get("amount") or 0),
            "date": str(args.get("date") or today),
            "notes": args.get("notes"),
        }
        if not row["ticker"] or row["amount"] <= 0:
            return {"error": "add_dividend needs ticker and amount > 0"}, None
        action = {"trades": [], "dividends": [row], "notes": ""}
        return {
            "status": "proposed",
            "note": ("A confirmation card is now shown to the user in the app. "
                     "Nothing is saved until they tap Add — tell them to review "
                     "the card and confirm."),
        }, action

    return {"error": f"Unknown tool: {name}"}, None


# ---------------------------------------------------------------------------
# Provider schema adapters
# ---------------------------------------------------------------------------

def openai_tools() -> list[dict]:
    return [
        {"type": "function",
         "function": {"name": t["name"], "description": t["description"],
                      "parameters": t["parameters"]}}
        for t in TOOLS
    ]


def claude_tools() -> list[dict]:
    return [
        {"name": t["name"], "description": t["description"],
         "input_schema": t["parameters"]}
        for t in TOOLS
    ]


def gemini_declarations(types) -> list:
    decls = []
    for t in TOOLS:
        params = t["parameters"]
        # Gemini rejects an object schema with zero properties — omit instead.
        decls.append(types.FunctionDeclaration(
            name=t["name"],
            description=t["description"],
            parameters=params if params.get("properties") else None,
        ))
    return decls


# ---------------------------------------------------------------------------
# Tool loops — one generator per provider API shape. Each yields
# ("chunk", text) / ("status", label) / ("action", records-dict) /
# ("thinking", text) — reasoning deltas, where the provider exposes them
# (Claude extended thinking, Gemini thought summaries; OpenAI/NIM don't).
# ---------------------------------------------------------------------------

MAX_TOOL_ROUNDS = 6
_RESULT_CAP = 8000  # chars of JSON per tool result fed back to the model


def _result_json(result: dict) -> str:
    return json.dumps(result, ensure_ascii=False, default=str)[:_RESULT_CAP]


def run_tool_loop(provider: str, api_key: str, model: str, system_prompt: str,
                  history, user_id: str):
    if provider == "gemini":
        return _gemini_loop(api_key, model, system_prompt, history, user_id)
    if provider == "claude":
        return _claude_loop(api_key, model, system_prompt, history, user_id)
    return _openai_loop(provider, api_key, model, system_prompt, history, user_id)


def _openai_user_content(content: str, image: bytes | None, mime: str | None,
                         vision: bool):
    """Plain text, or an OpenAI-style multipart content list when an image is
    attached. ``vision=False`` (NVIDIA NIM's free-tier text models) drops the
    image and tells the model one was attached, rather than sending bytes it
    can't understand."""
    if not image:
        return content
    if not vision:
        note = "[The user attached an image, but this model can't view images." \
               " Ask them to describe it, or switch to Gemini/OpenAI/Claude.]"
        return f"{content}\n{note}" if content else note
    parts: list[dict] = []
    if content:
        parts.append({"type": "text", "text": content})
    b64 = base64.b64encode(image).decode()
    parts.append({"type": "image_url",
                 "image_url": {"url": f"data:{mime or 'image/jpeg'};base64,{b64}"}})
    return parts


def _openai_loop(provider: str, api_key: str, model: str, system_prompt: str,
                 history, user_id: str):
    """OpenAI and NVIDIA NIM (OpenAI-compatible). NVIDIA's free-tier models are
    text-only, so images are only forwarded for the real OpenAI provider."""
    base_url = ai_providers.NVIDIA_BASE_URL if provider == "nvidia" else None
    client = ai_providers._openai_client(api_key, base_url=base_url, timeout=120.0)
    extra = ai_providers._nim_extra_body(model) if provider == "nvidia" else None
    vision = provider == "openai"

    messages: list[dict] = [{"role": "system", "content": system_prompt}]
    for role, content, image, mime in history:
        messages.append({
            "role": "assistant" if role == "assistant" else "user",
            "content": _openai_user_content(content, image, mime, vision),
        })

    for _ in range(MAX_TOOL_ROUNDS):
        stream = client.chat.completions.create(
            model=model, messages=messages, stream=True, max_tokens=1500,
            temperature=0.4, tools=openai_tools(), extra_body=extra,
        )
        calls: dict[int, dict] = {}
        for event in stream:
            choices = getattr(event, "choices", None) or []
            if not choices:
                continue
            delta = choices[0].delta
            if getattr(delta, "content", None):
                yield ("chunk", delta.content)
            for tc in getattr(delta, "tool_calls", None) or []:
                slot = calls.setdefault(tc.index, {"id": "", "name": "", "args": ""})
                if tc.id:
                    slot["id"] = tc.id
                if tc.function and tc.function.name:
                    slot["name"] = tc.function.name
                if tc.function and tc.function.arguments:
                    slot["args"] += tc.function.arguments

        if not calls:
            return
        ordered = [calls[i] for i in sorted(calls)]
        messages.append({
            "role": "assistant",
            "tool_calls": [
                {"id": c["id"], "type": "function",
                 "function": {"name": c["name"], "arguments": c["args"] or "{}"}}
                for c in ordered
            ],
        })
        for c in ordered:
            yield ("status", status_label(c["name"]))
            try:
                parsed = json.loads(c["args"] or "{}")
            except json.JSONDecodeError:
                parsed = {}
            result, action = execute(c["name"], parsed, user_id)
            if action:
                yield ("action", action)
            messages.append({"role": "tool", "tool_call_id": c["id"],
                             "content": _result_json(result)})


def _claude_content(content: str, image: bytes | None, mime: str | None):
    """Plain text, or an Anthropic-style content block list with the image
    first (Claude reads images best when they precede the caption text)."""
    if not image:
        return content
    parts: list[dict] = [{
        "type": "image",
        "source": {"type": "base64", "media_type": mime or "image/jpeg",
                   "data": base64.b64encode(image).decode()},
    }]
    if content:
        parts.append({"type": "text", "text": content})
    return parts


def _claude_loop(api_key: str, model: str, system_prompt: str,
                 history, user_id: str):
    import anthropic

    client = anthropic.Anthropic(api_key=api_key)
    messages = [
        {"role": "assistant" if role == "assistant" else "user",
         "content": _claude_content(content, image, mime)}
        for role, content, image, mime in history
    ]
    if not messages:
        return

    # Extended thinking streams the model's reasoning as it happens (the app
    # shows it in a collapsible section, like Claude's own UI). Models that
    # reject the parameter fall back to plain streaming once, permanently.
    thinking: dict | None = {"type": "enabled", "budget_tokens": 2000}

    for _ in range(MAX_TOOL_ROUNDS):
        kwargs = dict(model=model, max_tokens=4096, system=system_prompt,
                      messages=messages, tools=claude_tools())
        if thinking:
            kwargs["thinking"] = thinking
        try:
            stream_cm = client.messages.stream(**kwargs)
            stream_cm.__enter__()
        except anthropic.BadRequestError:
            if not thinking:
                raise
            thinking = None
            kwargs.pop("thinking", None)
            stream_cm = client.messages.stream(**kwargs)
            stream_cm.__enter__()
        try:
            for event in stream_cm:
                if getattr(event, "type", "") == "content_block_delta":
                    delta = event.delta
                    dtype = getattr(delta, "type", "")
                    if dtype == "text_delta" and delta.text:
                        yield ("chunk", delta.text)
                    elif dtype == "thinking_delta" and getattr(delta, "thinking", ""):
                        yield ("thinking", delta.thinking)
            final = stream_cm.get_final_message()
        finally:
            stream_cm.__exit__(None, None, None)

        tool_uses = [b for b in final.content if b.type == "tool_use"]
        if not tool_uses:
            return
        messages.append({"role": "assistant", "content": final.content})
        results = []
        for block in tool_uses:
            yield ("status", status_label(block.name))
            result, action = execute(block.name, dict(block.input or {}), user_id)
            if action:
                yield ("action", action)
            results.append({"type": "tool_result", "tool_use_id": block.id,
                            "content": _result_json(result)})
        messages.append({"role": "user", "content": results})


def _gemini_loop(api_key: str, model: str, system_prompt: str,
                 history, user_id: str):
    """Gemini function calling. Note: Gemini cannot mix google_search with
    function declarations in one request, so web needs go through the
    search_web tool here."""
    from google import genai
    from google.genai import types

    client = genai.Client(api_key=api_key)

    def _parts(content: str, image: bytes | None, mime: str | None):
        parts = []
        if content:
            parts.append(types.Part(text=content))
        if image:
            parts.append(types.Part.from_bytes(data=image, mime_type=mime or "image/jpeg"))
        return parts

    contents = [
        types.Content(role="user" if role == "user" else "model",
                      parts=_parts(content, image, mime))
        for role, content, image, mime in history
    ]

    def _config(with_thoughts: bool):
        kwargs = dict(
            system_instruction=system_prompt,
            temperature=0.4,
            max_output_tokens=1500,
            tools=[types.Tool(function_declarations=gemini_declarations(types))],
        )
        if with_thoughts:
            # Thought summaries stream the model's reasoning for the app's
            # collapsible "Thinking" section.
            kwargs["thinking_config"] = types.ThinkingConfig(include_thoughts=True)
        return types.GenerateContentConfig(**kwargs)

    with_thoughts = True
    for _ in range(MAX_TOOL_ROUNDS):
        fcalls = []
        emitted_any = False
        try:
            stream = client.models.generate_content_stream(
                model=model, config=_config(with_thoughts), contents=contents,
            )
            for chunk in stream:
                for cand in getattr(chunk, "candidates", None) or []:
                    content = getattr(cand, "content", None)
                    for part in (getattr(content, "parts", None) or []):
                        fc = getattr(part, "function_call", None)
                        if fc is not None and fc.name:
                            fcalls.append(fc)
                        elif getattr(part, "text", None):
                            emitted_any = True
                            if getattr(part, "thought", False):
                                yield ("thinking", part.text)
                            else:
                                yield ("chunk", part.text)
        except Exception:
            # Models without thinking support can reject the config — retry
            # this round once without thought summaries, then stay off.
            if not with_thoughts or emitted_any or fcalls:
                raise
            with_thoughts = False
            continue

        if not fcalls:
            return
        contents.append(types.Content(
            role="model", parts=[types.Part(function_call=fc) for fc in fcalls]))
        resp_parts = []
        for fc in fcalls:
            yield ("status", status_label(fc.name))
            result, action = execute(fc.name, dict(fc.args or {}), user_id)
            if action:
                yield ("action", action)
            resp_parts.append(types.Part.from_function_response(
                name=fc.name, response={"result": result}))
        contents.append(types.Content(role="user", parts=resp_parts))
