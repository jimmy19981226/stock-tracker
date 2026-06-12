import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Load backend/.env (if present) before importing routers, since ai.py
# reads GOOGLE_AI_MODEL at module-load time.
try:
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass

from .database import Dividend, SessionLocal, Trade, init_db
from .routers import ai, data, dividends, markets, mobile, portfolio, quotes, stock, trades
from .services import quotes as quote_service
from .services import xlsx_io

SEED_FILE = (
    Path(__file__).resolve().parent.parent / "data" / "seed" / "portfolio.xlsx"
)

app = FastAPI(title="AI Stock Studio", version="0.1.0")

# Local dev origins plus any extra origins from FRONTEND_ORIGINS (comma-
# separated), e.g. the deployed frontend's URL: "https://stock-tracker.vercel.app".
_default_origins = ["http://localhost:5173", "http://127.0.0.1:5173"]
_extra_origins = [
    o.strip() for o in os.environ.get("FRONTEND_ORIGINS", "").split(",") if o.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_default_origins + _extra_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def _quote_source_pref(request, call_next):
    """Apply the caller's quote-source choice (X-Quote-Source header) to this
    request. Contextvars propagate into the threadpool running sync routes."""
    pref = (request.headers.get("x-quote-source") or "auto").lower()
    if pref not in ("auto", "mis", "yahoo"):
        pref = "auto"
    token = quote_service.source_preference.set(pref)
    try:
        return await call_next(request)
    finally:
        quote_service.source_preference.reset(token)


@app.on_event("startup")
def _startup() -> None:
    init_db()
    _seed_from_disk()


def _seed_from_disk() -> None:
    """Load the portfolio Excel workbook on startup if both tables are empty.

    Looks for ``backend/data/seed/portfolio.xlsx``. Skipped entirely once the
    user has any trades or dividends, so UI-entered data is never overwritten.
    """
    if not SEED_FILE.exists():
        return
    db = SessionLocal()
    try:
        if db.query(Trade).count() > 0 or db.query(Dividend).count() > 0:
            return
        try:
            data_bytes = SEED_FILE.read_bytes()
            trades, dividends = xlsx_io.parse_portfolio_xlsx(data_bytes)
            xlsx_io.insert_trades(db, trades)
            xlsx_io.insert_dividends(db, dividends)
            print(
                f"[seed] loaded {len(trades)} trades + "
                f"{len(dividends)} dividends from {SEED_FILE.name}"
            )
        except Exception as exc:
            print(f"[seed] failed to load {SEED_FILE.name}: {exc}")
    finally:
        db.close()


@app.get("/api/health")
def health():
    return {"status": "ok"}


app.include_router(trades.router)
app.include_router(dividends.router)
app.include_router(portfolio.router)
app.include_router(data.router)
app.include_router(ai.router)
app.include_router(stock.router)
app.include_router(markets.router)
app.include_router(quotes.router)
app.include_router(mobile.router)
app.include_router(mobile.page_router)
