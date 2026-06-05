"""Natural-language Q&A over the user's portfolio.

Uses Google Gemini (default ``gemini-2.5-flash``). The API key is read
from the ``GOOGLE_AI_API_KEY`` environment variable; without it the
``/api/ai/chat`` endpoint returns 503 so the frontend can show a setup
hint.

Conversations are persisted in the ``chats`` and ``chat_messages``
tables so users can revisit, rename, and delete past threads.

The model only sees the user's local portfolio JSON as context. We
explicitly instruct it not to give investment advice, predictions, or
buy/sell recommendations -- it acts as a read-only narrator over your
data.
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from ..database import Chat, ChatMessage, Dividend, SessionLocal, Trade, get_db
from ..services import portfolio, quotes, stock_info


_TICKER_PATTERN = re.compile(r"\b(\d{4,6}[A-Za-z]?)\b")


router = APIRouter(prefix="/api/ai", tags=["ai"])

DEFAULT_MODEL = os.environ.get("GOOGLE_AI_MODEL", "gemini-2.5-flash")
MAX_HISTORY_TURNS = 20  # cap conversation length sent to the model
MAX_TITLE_LEN = 60


class Message(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class ChatRequest(BaseModel):
    chat_id: int | None = None
    message: str = Field(..., min_length=1)


class ChatSummary(BaseModel):
    id: int
    title: str
    created_at: datetime
    updated_at: datetime
    message_count: int


class ChatDetail(BaseModel):
    id: int
    title: str
    created_at: datetime
    updated_at: datetime
    messages: list[Message]


class ChatRename(BaseModel):
    title: str = Field(..., min_length=1, max_length=MAX_TITLE_LEN)


class ChatReply(BaseModel):
    chat_id: int
    title: str
    message: Message


@router.get("/status")
def ai_status():
    """Whether the AI assistant is configured. The frontend calls this
    on load to decide whether to surface the chat UI."""
    return {
        "configured": bool(os.environ.get("GOOGLE_AI_API_KEY")),
        "model": DEFAULT_MODEL,
    }


@router.get("/chats", response_model=list[ChatSummary])
def list_chats(db: Session = Depends(get_db)):
    chats = db.query(Chat).order_by(Chat.updated_at.desc()).all()
    return [
        ChatSummary(
            id=c.id,
            title=c.title,
            created_at=c.created_at,
            updated_at=c.updated_at,
            message_count=len(c.messages),
        )
        for c in chats
    ]


@router.get("/chats/{chat_id}", response_model=ChatDetail)
def get_chat(chat_id: int, db: Session = Depends(get_db)):
    chat = db.get(Chat, chat_id)
    if chat is None:
        raise HTTPException(status_code=404, detail="Chat not found")
    return ChatDetail(
        id=chat.id,
        title=chat.title,
        created_at=chat.created_at,
        updated_at=chat.updated_at,
        messages=[Message(role=m.role, content=m.content) for m in chat.messages],
    )


@router.patch("/chats/{chat_id}", response_model=ChatSummary)
def rename_chat(chat_id: int, body: ChatRename, db: Session = Depends(get_db)):
    chat = db.get(Chat, chat_id)
    if chat is None:
        raise HTTPException(status_code=404, detail="Chat not found")
    chat.title = body.title.strip()[:MAX_TITLE_LEN]
    db.commit()
    db.refresh(chat)
    return ChatSummary(
        id=chat.id,
        title=chat.title,
        created_at=chat.created_at,
        updated_at=chat.updated_at,
        message_count=len(chat.messages),
    )


@router.delete("/chats/{chat_id}", status_code=204)
def delete_chat(chat_id: int, db: Session = Depends(get_db)):
    chat = db.get(Chat, chat_id)
    if chat is None:
        raise HTTPException(status_code=404, detail="Chat not found")
    db.delete(chat)
    db.commit()


@router.post("/chat")
def chat(req: ChatRequest):
    """Stream the assistant's reply as Server-Sent Events.

    Event payloads (each is one ``data: {json}\\n\\n`` block):
    - ``init``  → ``{chat_id, title}`` (sent once before generation begins)
    - ``chunk`` → ``{delta}`` (raw text chunk as the model emits it)
    - ``done``  → ``{content, queries, duration_ms}`` (final canonical content
      with inline ``[N]`` markers + Sources block; replaces the streamed
      deltas; the persisted DB value is also this final content)
    - ``error`` → ``{detail}``

    Each chunk's ``delta`` is the raw text the model emitted in that step;
    the ``done`` event ships the full content with grounding-metadata-derived
    inline citation markers and a trailing Sources list, which is what gets
    persisted. Frontend swaps the streamed buffer for ``done.content``.
    """
    api_key = os.environ.get("GOOGLE_AI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail=(
                "GOOGLE_AI_API_KEY environment variable is not set. "
                "Get a free key at https://aistudio.google.com/apikey "
                "and start the backend with the variable set."
            ),
        )

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        raise HTTPException(
            status_code=503,
            detail="google-genai not installed. Run `pip install -r requirements.txt`.",
        )

    user_text = req.message.strip()
    if not user_text:
        raise HTTPException(status_code=400, detail="Message cannot be empty")

    # Phase 1: persist the user message and snapshot what the generator needs.
    # Done synchronously so the user message survives even if streaming aborts.
    with SessionLocal() as db:
        if req.chat_id is None:
            chat_obj = Chat(title=_derive_title(user_text))
            db.add(chat_obj)
            db.flush()
        else:
            chat_obj = db.get(Chat, req.chat_id)
            if chat_obj is None:
                raise HTTPException(status_code=404, detail="Chat not found")
            if chat_obj.title == "New chat" and not chat_obj.messages:
                chat_obj.title = _derive_title(user_text)

        db.add(ChatMessage(chat_id=chat_obj.id, role="user", content=user_text))
        db.flush()

        history_msgs = [
            (m.role, m.content)
            for m in list(chat_obj.messages)[-MAX_HISTORY_TURNS:]
        ]
        focus_tickers = _detect_tickers([c for _, c in history_msgs])[:3]
        portfolio_context = _build_context(db, focus_tickers=focus_tickers)
        chat_id = chat_obj.id
        chat_title = chat_obj.title
        db.commit()

    system_prompt = _system_prompt(portfolio_context)
    contents = [
        types.Content(
            role="user" if role == "user" else "model",
            parts=[types.Part(text=content)],
        )
        for role, content in history_msgs
    ]

    def event_stream():
        accumulated_text = ""
        last_chunk = None
        start_ts = time.time()
        persisted = False

        def persist(final_content: str) -> None:
            nonlocal persisted
            if persisted:
                return
            persisted = True
            try:
                with SessionLocal() as db_local:
                    db_local.add(
                        ChatMessage(
                            chat_id=chat_id,
                            role="assistant",
                            content=final_content,
                        )
                    )
                    chat_db = db_local.get(Chat, chat_id)
                    if chat_db is not None:
                        chat_db.updated_at = datetime.utcnow()
                    db_local.commit()
            except Exception:
                # Persistence failure shouldn't break the user-facing stream.
                pass

        def sse(payload: dict) -> str:
            return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"

        try:
            yield sse({"type": "init", "chat_id": chat_id, "title": chat_title})

            client = genai.Client(api_key=api_key)
            stream_iter = client.models.generate_content_stream(
                model=DEFAULT_MODEL,
                config=types.GenerateContentConfig(
                    system_instruction=system_prompt,
                    temperature=0.4,
                    max_output_tokens=1500,
                    tools=[types.Tool(google_search=types.GoogleSearch())],
                ),
                contents=contents,
            )

            for chunk in stream_iter:
                last_chunk = chunk
                delta = getattr(chunk, "text", None) or ""
                if delta:
                    accumulated_text += delta
                    yield sse({"type": "chunk", "delta": delta})

            # Apply grounding metadata to the assembled text. Byte indices in
            # ``grounding_supports`` are positions in the cumulative response,
            # which is exactly what ``accumulated_text`` is.
            meta = None
            try:
                cands = getattr(last_chunk, "candidates", None) or []
                if cands:
                    meta = getattr(cands[0], "grounding_metadata", None)
            except Exception:
                meta = None

            final_text, sources_block = _apply_grounding_text(
                accumulated_text or "(no response)", meta
            )
            if sources_block:
                final_text = final_text.rstrip() + "\n\n" + sources_block

            queries: list[str] = []
            try:
                if meta is not None:
                    queries = list(getattr(meta, "web_search_queries", None) or [])
            except Exception:
                queries = []

            elapsed_ms = int((time.time() - start_ts) * 1000)
            meta_header = json.dumps(
                {"queries": queries, "duration_ms": elapsed_ms},
                ensure_ascii=False,
            )
            full_content = f"<!--meta:{meta_header}-->\n{final_text}"

            persist(full_content)

            yield sse(
                {
                    "type": "done",
                    "content": full_content,
                    "queries": queries,
                    "duration_ms": elapsed_ms,
                }
            )
        except GeneratorExit:
            # Client disconnected (abort). Save whatever we have so the user
            # doesn't lose a partial response on next chat load.
            if accumulated_text and not persisted:
                persist(
                    "<!--meta:" + json.dumps({"queries": [], "interrupted": True})
                    + "-->\n" + accumulated_text + "\n\n_(stopped)_"
                )
            raise
        except Exception as exc:
            yield sse(
                {"type": "error", "detail": f"{type(exc).__name__}: {exc}"}
            )

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # disable proxy buffering
        },
    )


# ---------------------------------------------------------------------------
# Agentic mode: the assistant can DRIVE the UI. Instead of (only) answering in
# text, the planner returns an ordered list of "steps" that the frontend plays
# out — moving an on-screen cursor, opening tabs, typing into the real forms.
# This is a fast, non-streaming structured call (response_schema forces shape);
# questions/analysis fall through to the normal streaming /chat endpoint.
# ---------------------------------------------------------------------------

_TAIPEI = timezone(timedelta(hours=8))


class AgentRequest(BaseModel):
    message: str = Field(..., min_length=1)
    view: str | None = None  # the tab the user is currently looking at


# One flat step object: every action's fields live here as optional keys so the
# schema stays a simple (Gemini-friendly) array of uniform objects.
_AGENT_STEP_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "action": {
            "type": "string",
            "enum": [
                "navigate", "open_stock", "close_modal", "add_trade",
                "add_dividend", "filter_trades", "highlight", "note",
            ],
        },
        "say": {"type": "string"},
        "view": {"type": "string", "enum": ["dashboard", "trades", "dividends"]},
        "ticker": {"type": "string"},
        "trade_type": {"type": "string", "enum": ["buy", "sell"]},
        "shares": {"type": "number"},
        "price": {"type": "number"},
        "amount": {"type": "number"},
        "date": {"type": "string"},
        "fee": {"type": "number"},
        "notes": {"type": "string"},
        "status": {"type": "string", "enum": ["all", "open", "closed"]},
        "target": {"type": "string"},
    },
    "required": ["action", "say"],
}

_AGENT_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "mode": {"type": "string", "enum": ["act", "chat"]},
        "reply": {"type": "string"},
        "steps": {"type": "array", "items": _AGENT_STEP_SCHEMA},
    },
    "required": ["mode", "reply", "steps"],
}


def _agent_context(db: Session) -> str:
    """Compact holdings list so the planner can resolve 'my biggest position',
    pick real tickers, and know what exists. Kept tiny (no fundamentals)."""
    try:
        holdings = portfolio.build_holdings(db)
    except Exception:
        holdings = []
    rows = [
        {
            "ticker": h.get("ticker"),
            "name": h.get("name"),
            "shares": h.get("shares"),
            "market_value": h.get("market_value"),
        }
        for h in holdings
        if h.get("ticker")
    ]
    return json.dumps(rows, default=str, ensure_ascii=False)


def _agent_prompt(context_json: str, view: str | None, today: str) -> str:
    return (
        "You are the UI-automation planner for \"AI Stock Studio\", a Taiwan\n"
        "stock-portfolio web app. The user types a request; you output a JSON\n"
        "plan that the app PLAYS OUT by physically moving an on-screen cursor,\n"
        "switching tabs, and typing into real forms while the user watches.\n"
        "\n"
        "Choose one mode:\n"
        "- \"act\": the user wants to DO something in the app — navigate, open a\n"
        "  stock, add a trade/dividend, filter, or be shown where something is.\n"
        "  Return an ordered `steps` array.\n"
        "- \"chat\": the user is asking a QUESTION or wants analysis, news, or an\n"
        "  explanation (e.g. \"how is 2330 doing?\", \"what's my best position?\").\n"
        "  Return mode \"chat\" with an EMPTY steps array — a separate analysis\n"
        "  assistant answers those. When torn between explaining and acting,\n"
        "  prefer \"chat\".\n"
        "\n"
        "Each step has an `action` and a short `say`: a 2–5 word present-tense\n"
        "caption shown while it runs (e.g. \"Opening Trades\", \"Typing 2330\",\n"
        "\"Submitting the trade\").\n"
        "\n"
        "Actions and their fields:\n"
        "- navigate {view: dashboard|trades|dividends} — switch the top tab.\n"
        "- open_stock {ticker} — open the detail modal for a position. Precede\n"
        "  it with a navigate to \"dashboard\".\n"
        "- close_modal — close the open stock modal.\n"
        "- add_trade {trade_type: buy|sell, ticker, shares, price, date, fee?,\n"
        "  notes?} — fills + submits the Record Trade form (auto-opens Trades).\n"
        "- add_dividend {ticker, amount, date, notes?} — fills + submits the\n"
        "  Record Dividend form (auto-opens Dividends).\n"
        "- filter_trades {ticker?, trade_type?, status?} — set the Trades filters.\n"
        "- highlight {target} — glow + point at a region so the user sees it.\n"
        "  Valid targets: today, total-earned, total-return, market-value,\n"
        "  unrealized, realized, dividends (dashboard summary cards), or\n"
        "  \"holding-<TICKER>\" for a position row (e.g. holding-2330).\n"
        "- note — narration only, no action. Use sparingly.\n"
        "\n"
        "Rules:\n"
        "- ticker is the bare TW code: \"2330\", \"00919\" (no .TW, no name).\n"
        "- Put the stock code in the `ticker` field for add_trade, add_dividend,\n"
        "  open_stock and filter_trades. The `target` field is ONLY for highlight\n"
        "  — never put a ticker in `target` for the other actions.\n"
        "- shares is a SHARE count (1 lot/張 = 1000 shares); price is per-share NT$.\n"
        f"- date is ISO YYYY-MM-DD; default to TODAY ({today}) if unspecified.\n"
        "- add_trade REQUIRES trade_type, ticker, shares, price. If the request\n"
        "  is missing a required value, do NOT act — return mode \"chat\" with a\n"
        "  `reply` that asks for the missing detail.\n"
        "- Only use tickers/targets that make sense. open_stock and\n"
        "  holding-<TICKER> highlights should reference a held position from the\n"
        "  HOLDINGS list below (or one the user explicitly named).\n"
        "- Keep plans minimal and ordered so they're easy to follow.\n"
        "- `reply` is ONE plain sentence (no markdown): for \"act\", what you're\n"
        "  about to do; for \"chat\", your question or a brief hand-off.\n"
        "\n"
        f"CURRENT_VIEW: {view or 'dashboard'}\n"
        f"HOLDINGS (ticker, name, shares, market_value):\n{context_json}"
    )


@router.post("/agent")
def agent_plan(req: AgentRequest):
    """Plan a UI-driving action sequence for the agentic assistant.

    Returns ``{mode, reply, steps}``. ``mode == "chat"`` (with empty steps)
    means "this is a question, not an action" — the frontend then calls the
    normal streaming ``/chat`` endpoint. ``mode == "act"`` ships an ordered
    list of steps the frontend plays out over the live UI.
    """
    api_key = os.environ.get("GOOGLE_AI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail=(
                "GOOGLE_AI_API_KEY environment variable is not set. "
                "Get a free key at https://aistudio.google.com/apikey "
                "and start the backend with the variable set."
            ),
        )

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        raise HTTPException(
            status_code=503,
            detail="google-genai not installed. Run `pip install -r requirements.txt`.",
        )

    user_text = req.message.strip()
    if not user_text:
        raise HTTPException(status_code=400, detail="Message cannot be empty")

    with SessionLocal() as db:
        context_json = _agent_context(db)

    today = datetime.now(_TAIPEI).date().isoformat()
    system_prompt = _agent_prompt(context_json, req.view, today)

    try:
        client = genai.Client(api_key=api_key)
        response = client.models.generate_content(
            model=DEFAULT_MODEL,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=0.1,
                response_mime_type="application/json",
                response_schema=_AGENT_SCHEMA,
            ),
            contents=[
                types.Content(role="user", parts=[types.Part(text=user_text)]),
            ],
        )
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Gemini call failed: {type(exc).__name__}: {exc}",
        )

    text = (getattr(response, "text", None) or "").strip()
    if not text:
        # Treat a blank plan as "just chat" rather than erroring the user out.
        return {"mode": "chat", "reply": "", "steps": []}

    try:
        plan = json.loads(text)
    except json.JSONDecodeError:
        return {"mode": "chat", "reply": "", "steps": []}

    mode = plan.get("mode") if plan.get("mode") in ("act", "chat") else "chat"
    steps = plan.get("steps") or []
    if mode != "act" or not isinstance(steps, list) or not steps:
        # No real actions → let the streaming chat assistant handle it.
        return {"mode": "chat", "reply": plan.get("reply") or "", "steps": []}

    return {
        "mode": "act",
        "reply": plan.get("reply") or "",
        "steps": steps,
    }


PARSE_MAX_BYTES = 8 * 1024 * 1024  # 8 MB cap on uploads to keep latency sane
PARSE_ALLOWED_MIMES = {
    "image/png",
    "image/jpeg",
    "image/jpg",
    "image/webp",
    "image/heic",
    "image/heif",
    "application/pdf",
}

# JSON schema Gemini is forced to return. Keeping it strict here means the
# frontend never has to defend against shape drift.
_PARSE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "trades": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "type": {"type": "string", "enum": ["buy", "sell"]},
                    "ticker": {"type": "string"},
                    "shares": {"type": "number"},
                    "price": {"type": "number"},
                    "date": {"type": "string"},
                    "fee": {"type": "number"},
                    "notes": {"type": "string"},
                },
                "required": ["type", "ticker", "shares", "price", "date"],
            },
        },
        "dividends": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "ticker": {"type": "string"},
                    "amount": {"type": "number"},
                    "date": {"type": "string"},
                    "notes": {"type": "string"},
                },
                "required": ["ticker", "amount", "date"],
            },
        },
        "notes": {"type": "string"},
    },
    "required": ["trades", "dividends"],
}

_PARSE_PROMPT = (
    "You are extracting structured data from a Taiwan brokerage record "
    "(image or PDF) for a personal stock investor. Pull every trade "
    "(買進/賣出) and every cash dividend (現金股利/股息) you can see, and "
    "return JSON matching the schema.\n\n"
    "Field rules:\n"
    "- ticker: the bare 4–6 digit Taiwan code, e.g. \"2330\", \"00919\". "
    "  Strip any \".TW\" suffix and any company name prefix.\n"
    "- type: \"buy\" for 買進/Buy, \"sell\" for 賣出/Sell.\n"
    "- shares: number of SHARES. If the document shows 張 (lots), multiply "
    "  by 1000 — 1 張 = 1000 shares.\n"
    "- price: per-share price in NT$.\n"
    "- date: ISO YYYY-MM-DD. If the document uses ROC (民國) years like "
    "  113/01/15, convert to Gregorian by adding 1911 → 2024-01-15.\n"
    "- fee (trades): handling fee + transaction tax in NT$ if visible, "
    "  otherwise omit.\n"
    "- amount (dividends): cash dividend in NT$. If the figure shown is "
    "  per-share, leave it as-is and add a note. If it's the total amount "
    "  received, that's also fine — note which.\n"
    "- notes: short context for anything unusual, including which interpretation "
    "  you used for ambiguous fields.\n\n"
    "If a row is unreadable or you're not confident, OMIT it rather than guess. "
    "If the document doesn't appear to contain any trades or dividends, return "
    "empty arrays and explain in the top-level `notes`."
)


async def run_parse_pipeline(file: UploadFile) -> dict:
    """Validate the upload, call Gemini, return the parsed dict.

    Raises HTTPException on any failure — caller can choose to bubble it
    (interactive request) or capture it for a session store (background
    request from the mobile QR upload page)."""
    api_key = os.environ.get("GOOGLE_AI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail=(
                "GOOGLE_AI_API_KEY environment variable is not set. "
                "Get a free key at https://aistudio.google.com/apikey "
                "and start the backend with the variable set."
            ),
        )

    mime = (file.content_type or "").lower().strip()
    if mime not in PARSE_ALLOWED_MIMES:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Unsupported file type: {mime or 'unknown'}. "
                "Allowed: PNG, JPG, WEBP, HEIC, or PDF."
            ),
        )

    raw = await file.read()
    if len(raw) == 0:
        raise HTTPException(status_code=400, detail="Empty file")
    if len(raw) > PARSE_MAX_BYTES:
        raise HTTPException(
            status_code=413,
            detail=(
                f"File too large ({len(raw) / 1e6:.1f} MB). "
                f"Max {PARSE_MAX_BYTES // (1024 * 1024)} MB."
            ),
        )

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        raise HTTPException(
            status_code=503,
            detail="google-genai not installed. Run `pip install -r requirements.txt`.",
        )

    try:
        client = genai.Client(api_key=api_key)
        response = client.models.generate_content(
            model=DEFAULT_MODEL,
            config=types.GenerateContentConfig(
                temperature=0.1,
                response_mime_type="application/json",
                response_schema=_PARSE_SCHEMA,
            ),
            contents=[
                types.Content(
                    role="user",
                    parts=[
                        types.Part(text=_PARSE_PROMPT),
                        types.Part.from_bytes(data=raw, mime_type=mime),
                    ],
                ),
            ],
        )
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Gemini call failed: {type(exc).__name__}: {exc}",
        )

    text = (getattr(response, "text", None) or "").strip()
    if not text:
        raise HTTPException(status_code=422, detail="Model returned no content")

    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=422,
            detail=f"Could not parse model JSON: {exc}",
        )

    return {
        "trades": parsed.get("trades") or [],
        "dividends": parsed.get("dividends") or [],
        "notes": parsed.get("notes") or "",
    }


@router.post("/parse-records")
async def parse_records(file: UploadFile = File(...)):
    """Parse a brokerage screenshot/PDF into structured trade + dividend rows.

    The frontend renders the result in a preview card so the user can review
    and edit before committing. Nothing is written to the DB here — this
    endpoint is read-only on the server side; the frontend calls the existing
    POST /api/trades and POST /api/dividends to persist the confirmed rows.
    """
    return await run_parse_pipeline(file)


# (cross-device QR upload lives in routers/mobile.py; it imports
# `run_parse_pipeline` from this module to share the validation +
# Gemini call.)


def _derive_title(first_user_msg: str) -> str:
    """Derive a chat title from the first user message. Trim, collapse
    whitespace, cap to MAX_TITLE_LEN with an ellipsis."""
    cleaned = " ".join(first_user_msg.split())
    if len(cleaned) <= MAX_TITLE_LEN:
        return cleaned or "New chat"
    return cleaned[: MAX_TITLE_LEN - 1].rstrip() + "…"


def _system_prompt(context_json: str) -> str:
    return (
        "You are a portfolio analysis assistant for a Taiwan stock tracker.\n"
        "Your primary source is the JSON in the CONTEXT block (the user's local\n"
        "portfolio data). You ALSO have a Google Search tool available — use it\n"
        "when the user asks about recent news, filings, macro events, analyst\n"
        "commentary, or anything time-sensitive that the CONTEXT can't answer.\n"
        "\n"
        "Hard rules:\n"
        "- DO NOT give investment advice, buy/sell recommendations, or predictions.\n"
        "  Even when reporting analyst opinions found via search, frame them as\n"
        "  observations of what others said, never as your own recommendation.\n"
        "- For numeric facts about the user's holdings (shares, cost, P/L), trust\n"
        "  the CONTEXT — never overwrite it with search results.\n"
        "- Use search for: recent news, earnings announcements, dividend\n"
        "  announcements, regulatory filings, sector trends, analyst price\n"
        "  targets, and to fill gaps the CONTEXT doesn't cover.\n"
        "- When you use search, briefly note what you found and that it came\n"
        "  from the web (e.g. 'According to Reuters…'). Citation links are\n"
        "  appended automatically — don't fabricate URLs.\n"
        "- If neither CONTEXT nor search yields a confident answer, say so plainly.\n"
        "- All amounts are TWD (NT$). When mentioning a ticker, include its Chinese\n"
        "  name in parentheses if available, e.g. `2330 (台積電)`.\n"
        "- Be concise and factual. Use bullet points or short tables for multi-row\n"
        "  answers. Round NT$ amounts to whole dollars unless precision matters.\n"
        "- `unrealized_pl` and `total_value` are gross (price × shares − cost),\n"
        "  matching what TW broker apps display under 總現值 / 損益試算.\n"
        "- `realized_pl` is from closed trades; `dividends` is cash payouts received.\n"
        "  `total_earned = realized + dividends` (the cash you've actually pocketed).\n"
        "\n"
        "What the CONTEXT contains:\n"
        "- `summary`: per-currency portfolio totals.\n"
        "- `holdings`: every open position with shares, avg cost, current price,\n"
        "  unrealized P/L, plus `fundamentals` (sector, industry, P/E, EPS,\n"
        "  market cap, 52-week range, dividend yield, beta, 1y analyst target,\n"
        "  next earnings/ex-div dates).\n"
        "- `trades`: every buy/sell row.\n"
        "- `dividends`: every payout received.\n"
        "- `focus`: deeper data for tickers the user is asking about. Each entry\n"
        "  has `monthly_revenue` (last 24 months in NT$ with YoY%) and\n"
        "  `quarterly_financials` (last 8 quarters with revenue, EPS, gross /\n"
        "  operating / net margin). Use this to answer trend / growth questions.\n"
        "\n"
        "Analytical questions you should be ready for:\n"
        "- 'How is 2330's revenue trend?' → cite recent monthly_revenue with YoY%.\n"
        "- 'Is 台積電's margin improving?' → compare quarterly_financials margins.\n"
        "- 'How does 2330's P/E compare to its 1y target?' → contrast price vs\n"
        "  fundamentals.target_mean_price; treat the upside as observation only,\n"
        "  not a recommendation.\n"
        "- 'Best month for revenue this year?' → scan the focus monthly_revenue.\n"
        "- 'Which holding has the strongest YoY revenue growth?' → if focus has\n"
        "  multiple tickers, compare them; otherwise say which data is missing.\n"
        "\n"
        f"CONTEXT (read-only data, current as of this request):\n{context_json}"
    )


def _apply_grounding(response) -> tuple[str, str]:
    """Convenience wrapper around :func:`_apply_grounding_text` for the
    non-streaming response object."""
    base_text = response.text or "(no response)"
    candidates = getattr(response, "candidates", None) or []
    meta = getattr(candidates[0], "grounding_metadata", None) if candidates else None
    return _apply_grounding_text(base_text, meta)


def _apply_grounding_text(base_text: str, meta) -> tuple[str, str]:
    """Inline-cite a Gemini response using grounding metadata.

    Returns (text, sources_block):
    - text: the model's reply with `[N]` markers inserted at the end of each
      grounded segment (byte-indexed via ``grounding_supports``). The frontend
      replaces those markers with citation chips.
    - sources_block: a markdown ``**Sources:**`` list mapping N → URL. Kept as
      a fallback for plain-markdown clients and as the data the frontend parses
      to look up chip metadata.
    Empty strings when search wasn't used or metadata is missing.
    """
    try:
        if meta is None:
            return base_text, ""

        chunks = list(getattr(meta, "grounding_chunks", None) or [])
        supports = list(getattr(meta, "grounding_supports", None) or [])

        # Build deduplicated source list and a chunk-index → source-N map.
        sources: list[tuple[str, str]] = []
        uri_to_n: dict[str, int] = {}
        chunk_to_n: dict[int, int] = {}
        for ci, ch in enumerate(chunks):
            web = getattr(ch, "web", None)
            if web is None:
                continue
            uri = getattr(web, "uri", None)
            title = getattr(web, "title", None) or uri or "source"
            if not uri:
                continue
            n = uri_to_n.get(uri)
            if n is None:
                sources.append((title, uri))
                n = len(sources)
                uri_to_n[uri] = n
            chunk_to_n[ci] = n

        if not sources:
            return base_text, ""

        # Gemini's segment.end_index is a BYTE offset into response.text.
        text_bytes = base_text.encode("utf-8")
        inserts: list[tuple[int, str]] = []
        for sup in supports:
            seg = getattr(sup, "segment", None)
            if seg is None:
                continue
            end_idx = getattr(seg, "end_index", None)
            if end_idx is None:
                continue
            indices = getattr(sup, "grounding_chunk_indices", None) or []
            ns: list[int] = []
            seen_n: set[int] = set()
            for ci in indices:
                n = chunk_to_n.get(ci)
                if n is None or n in seen_n:
                    continue
                seen_n.add(n)
                ns.append(n)
            if ns:
                inserts.append((end_idx, "".join(f"[{n}]" for n in ns)))

        # Insert in reverse byte order so each insertion preserves earlier
        # offsets. Stable secondary sort keeps marker order deterministic when
        # two supports share an end index.
        inserts.sort(key=lambda p: p[0], reverse=True)
        for pos, marker in inserts:
            pos = max(0, min(pos, len(text_bytes)))
            text_bytes = text_bytes[:pos] + marker.encode("utf-8") + text_bytes[pos:]
        new_text = text_bytes.decode("utf-8", errors="replace")

        lines = ["**Sources:**"]
        for i, (title, uri) in enumerate(sources, 1):
            lines.append(f"{i}. [{title}]({uri})")
        return new_text, "\n".join(lines)
    except Exception:
        return base_text, ""


def _detect_tickers(texts: list[str]) -> list[str]:
    """Pull TW-style ticker codes (4-6 digits, optional letter suffix) out
    of recent user/assistant turns. Returns most-recently-mentioned first,
    deduped. Years like '2024'/'2025' are filtered out so they don't get
    misread as tickers."""
    seen: list[str] = []
    year_like = re.compile(r"^(19|20)\d{2}$")
    for text in reversed(texts):
        for m in _TICKER_PATTERN.finditer(text):
            t = m.group(1).upper()
            if year_like.match(t):
                continue
            if t not in seen:
                seen.append(t)
    return seen


def _build_context(db: Session, focus_tickers: list[str] | None = None) -> str:
    """Compact portfolio snapshot for the LLM. Includes summary, holdings
    (with light fundamentals attached), trades and dividends. For any
    ``focus_tickers`` (typically the ticker the user is asking about),
    also includes monthly revenue and quarterly financials so the model
    can answer trend / growth questions without hallucinating."""
    holdings = portfolio.build_holdings(db)
    summary = portfolio.summarize(holdings, db)

    # Light fundamentals on every holding — small enough to send always.
    light_keys = (
        "sector", "industry", "pe", "eps", "market_cap", "dividend_rate",
        "dividend_yield", "fifty_two_week_high", "fifty_two_week_low",
        "beta", "target_mean_price", "earnings_date", "ex_dividend_date",
    )
    enriched_holdings: list[dict] = []
    for h in holdings:
        try:
            f = stock_info.get_fundamentals(h["ticker"])
            h_out = dict(h)
            h_out["fundamentals"] = {k: f.get(k) for k in light_keys if f.get(k) is not None}
            enriched_holdings.append(h_out)
        except Exception:
            enriched_holdings.append(h)

    # Deep data for any tickers the user is currently focused on.
    focus_payload: list[dict] = []
    held_tickers = {h["ticker"].upper() for h in holdings}
    for tkr in (focus_tickers or []):
        # Skip non-TW gibberish; quotes.resolve_symbol still works for
        # numeric codes even if not currently held.
        sym = quotes.resolve_symbol(tkr)
        try:
            quote = quotes.get_quote(tkr)
            f = stock_info.get_fundamentals(tkr)
            mr = stock_info.get_monthly_revenue(tkr, months=24)
            qf = stock_info.get_quarterly_financials(tkr, quarters=8)
        except Exception:
            quote = None
            f = {}
            mr = []
            qf = []
        focus_payload.append({
            "ticker": tkr,
            "symbol": sym,
            "name": (quote.name if quote else None) or f.get("short_name") or f.get("long_name"),
            "is_held": tkr.upper() in held_tickers,
            "current_price": quote.price if quote else None,
            "fundamentals": {k: v for k, v in f.items() if v is not None},
            "monthly_revenue": mr,
            "quarterly_financials": qf,
        })

    trades = (
        db.query(Trade)
        .order_by(Trade.trade_date.desc(), Trade.id.desc())
        .all()
    )
    dividends = (
        db.query(Dividend)
        .order_by(Dividend.pay_date.desc(), Dividend.id.desc())
        .all()
    )

    payload = {
        "summary": summary,
        "holdings": enriched_holdings,
        "focus": focus_payload,
        "trades": [
            {
                "date": t.trade_date.isoformat(),
                "type": t.type,
                "ticker": t.ticker,
                "shares": t.shares,
                "price": t.price,
                "fee": t.fee,
                "notes": t.notes,
            }
            for t in trades
        ],
        "dividends": [
            {
                "date": d.pay_date.isoformat(),
                "ticker": d.ticker,
                "amount": d.amount,
                "notes": d.notes,
            }
            for d in dividends
        ],
    }
    return json.dumps(payload, default=str, ensure_ascii=False, indent=2)
