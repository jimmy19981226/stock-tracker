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
from .routers import ai, data, dividends, portfolio, trades
from .services import csv_io

SEED_FILE = (
    Path(__file__).resolve().parent.parent / "data" / "seed" / "portfolio.csv"
)

app = FastAPI(title="Stock Tracker", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def _startup() -> None:
    init_db()
    _seed_from_disk()


def _seed_from_disk() -> None:
    """Load the unified portfolio CSV on startup if both tables are empty.

    Looks for ``backend/data/seed/portfolio.csv``. Skipped entirely once the
    user has any trades or dividends, so UI-entered data is never overwritten.
    """
    if not SEED_FILE.exists():
        return
    db = SessionLocal()
    try:
        if db.query(Trade).count() > 0 or db.query(Dividend).count() > 0:
            return
        try:
            text = SEED_FILE.read_text(encoding="utf-8-sig")
            trades, dividends = csv_io.parse_portfolio_csv(text)
            csv_io.insert_trades(db, trades)
            csv_io.insert_dividends(db, dividends)
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
