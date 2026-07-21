import os
from datetime import datetime, date
from sqlalchemy import create_engine, inspect, text, String, Float, Date, DateTime, Integer, Text, ForeignKey, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker, Session, relationship
from pathlib import Path

# Load backend/.env here too (not just in main.py) so DATABASE_URL is picked up
# even when the app is imported from a script rather than started via uvicorn.
try:
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parent.parent / ".env")
except ImportError:
    pass


def _make_engine():
    """Use the cloud DATABASE_URL when set; otherwise the local SQLite file.

    Set DATABASE_URL in backend/.env to point at Neon (or any Postgres). Leaving
    it unset keeps the original on-disk SQLite behaviour, so local dev is
    unchanged and you can switch back any time.
    """
    url = os.environ.get("DATABASE_URL", "").strip()
    if url:
        # Neon hands out bare 'postgresql://' (or legacy 'postgres://') URLs;
        # route them through the psycopg 3 driver SQLAlchemy expects.
        if url.startswith("postgres://"):
            url = "postgresql+psycopg://" + url[len("postgres://"):]
        elif url.startswith("postgresql://"):
            url = "postgresql+psycopg://" + url[len("postgresql://"):]
        # pool_pre_ping revives connections Neon drops when it scales to zero.
        return create_engine(url, pool_pre_ping=True)

    db_path = Path(__file__).resolve().parent.parent / "data" / "trades.db"
    db_path.parent.mkdir(parents=True, exist_ok=True)
    return create_engine(
        f"sqlite:///{db_path}",
        connect_args={"check_same_thread": False},
    )


engine = _make_engine()
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


class Trade(Base):
    __tablename__ = "trades"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    type: Mapped[str] = mapped_column(String(4), nullable=False)
    ticker: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    shares: Mapped[float] = mapped_column(Float, nullable=False)
    price: Mapped[float] = mapped_column(Float, nullable=False)
    trade_date: Mapped[date] = mapped_column(Date, nullable=False)
    fee: Mapped[float] = mapped_column(Float, default=0.0)
    notes: Mapped[str | None] = mapped_column(String(500), nullable=True)
    # Which portfolio this belongs to: "TW" (TWD) or "US" (USD). server_default
    # is what backfills existing rows when the column is added by the migration.
    market: Mapped[str] = mapped_column(String(2), nullable=False, server_default="TW")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    # Owner. "legacy" for rows created before auth existed / by the un-authenticated
    # web app; "google:<sub>" once a signed-in user owns them. See app/auth.py.
    user_id: Mapped[str] = mapped_column(
        String(255), nullable=False, server_default="legacy", index=True
    )


class Dividend(Base):
    __tablename__ = "dividends"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    ticker: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    amount: Mapped[float] = mapped_column(Float, nullable=False)
    pay_date: Mapped[date] = mapped_column(Date, nullable=False)
    notes: Mapped[str | None] = mapped_column(String(500), nullable=True)
    market: Mapped[str] = mapped_column(String(2), nullable=False, server_default="TW")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    user_id: Mapped[str] = mapped_column(
        String(255), nullable=False, server_default="legacy", index=True
    )


class Metadata(Base):
    __tablename__ = "metadata"

    key: Mapped[str] = mapped_column(String(50), primary_key=True)
    value: Mapped[str] = mapped_column(String(500))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=datetime.utcnow, onupdate=datetime.utcnow
    )


class Chat(Base):
    __tablename__ = "chats"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    title: Mapped[str] = mapped_column(String(200), nullable=False, default="New chat")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False
    )
    user_id: Mapped[str] = mapped_column(
        String(255), nullable=False, server_default="legacy", index=True
    )

    messages: Mapped[list["ChatMessage"]] = relationship(
        back_populates="chat",
        cascade="all, delete-orphan",
        order_by="ChatMessage.id",
    )


class ChatMessage(Base):
    __tablename__ = "chat_messages"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    chat_id: Mapped[int] = mapped_column(
        ForeignKey("chats.id", ondelete="CASCADE"), nullable=False, index=True
    )
    role: Mapped[str] = mapped_column(String(20), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, nullable=False)
    # An image the user attached to this turn (base64-encoded), so reopening a
    # past chat still shows it. NULL for every message without one.
    image_mime: Mapped[str | None] = mapped_column(String(40), nullable=True)
    image_data: Mapped[str | None] = mapped_column(Text, nullable=True)

    chat: Mapped["Chat"] = relationship(back_populates="messages")


class Market(Base):
    """A tradeable market (TW, US, …) — its currency, timezone and session
    hours. The single source of truth for what used to be hardcoded in
    quotes.currency_of and the *MarketOpen helpers."""
    __tablename__ = "markets"

    code: Mapped[str] = mapped_column(String(2), primary_key=True)  # "TW","US"
    name: Mapped[str] = mapped_column(String(40), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), nullable=False)
    timezone: Mapped[str] = mapped_column(String(40), nullable=False)  # IANA tz
    open_minute: Mapped[int] = mapped_column(Integer, nullable=False)   # from local midnight
    close_minute: Mapped[int] = mapped_column(Integer, nullable=False)
    sort_order: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class MarketHoliday(Base):
    """A full-day market closure. Replaces the hardcoded holiday lists; add a
    row to close a market on a date, no code change needed."""
    __tablename__ = "market_holidays"
    __table_args__ = (UniqueConstraint("market_code", "holiday_date", name="uq_market_holiday"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    market_code: Mapped[str] = mapped_column(String(2), nullable=False, index=True)
    holiday_date: Mapped[date] = mapped_column(Date, nullable=False)
    name: Mapped[str | None] = mapped_column(String(80), nullable=True)


# One-time bootstrap data (used only when the markets table is empty). After
# seeding, the DB is authoritative — edit rows / use the API to change these.
_SEED_MARKETS = [
    # code, name, currency, timezone, open_minute, close_minute, sort_order
    ("TW", "Taiwan", "TWD", "Asia/Taipei", 9 * 60, 13 * 60 + 30, 0),
    ("US", "United States", "USD", "America/New_York", 9 * 60 + 30, 16 * 60, 1),
]
_SEED_HOLIDAYS = {
    "TW": [
        ("2026-01-01", "New Year / ROC Founding Day"),
        ("2026-02-16", "Lunar New Year (eve)"),
        ("2026-02-17", "Lunar New Year"),
        ("2026-02-18", "Lunar New Year"),
        ("2026-02-19", "Lunar New Year"),
        ("2026-02-20", "Lunar New Year"),
        ("2026-02-27", "Peace Memorial Day (observed)"),
        ("2026-04-03", "Children's Day (observed)"),
        ("2026-04-06", "Tomb-Sweeping Day (observed)"),
        ("2026-05-01", "Labor Day"),
        ("2026-06-19", "Dragon Boat Festival"),
        ("2026-09-25", "Mid-Autumn Festival"),
        ("2026-09-28", "Teachers' Day"),
        ("2026-10-09", "National Day (observed)"),
        ("2026-10-26", "Taiwan Restoration Day (observed)"),
        ("2026-12-25", "Constitution Day"),
    ],
    "US": [
        ("2026-01-01", "New Year's Day"),
        ("2026-01-19", "Martin Luther King Jr. Day"),
        ("2026-02-16", "Presidents' Day"),
        ("2026-04-03", "Good Friday"),
        ("2026-05-25", "Memorial Day"),
        ("2026-06-19", "Juneteenth"),
        ("2026-07-03", "Independence Day (observed)"),
        ("2026-09-07", "Labor Day"),
        ("2026-11-26", "Thanksgiving"),
        ("2026-12-25", "Christmas"),
    ],
}


def seed_markets() -> None:
    """Bootstrap the markets + holidays tables from ``_SEED_*`` if (and only if)
    no markets exist yet. Idempotent: a no-op once the DB is populated, so it
    seeds a fresh local DB and the existing prod DB alike without clobbering
    edits."""
    from datetime import date as _date

    with SessionLocal() as db:
        if db.query(Market).first() is not None:
            return
        for code, name, currency, tz, op, cl, order in _SEED_MARKETS:
            db.add(Market(
                code=code, name=name, currency=currency, timezone=tz,
                open_minute=op, close_minute=cl, sort_order=order,
            ))
        for code, days in _SEED_HOLIDAYS.items():
            for iso, hname in days:
                db.add(MarketHoliday(
                    market_code=code,
                    holiday_date=_date.fromisoformat(iso),
                    name=hname,
                ))
        db.commit()


def _ensure_market_column() -> None:
    """Add the ``market`` column to existing trades/dividends tables.

    ``create_all`` only CREATEs new tables — it never ALTERs an existing one,
    so a database created before this column existed (e.g. the prod Neon DB)
    needs an explicit migration. The DDL below is valid on both SQLite and
    Postgres, and the column-presence guard makes it a no-op on reruns. The
    ``DEFAULT 'TW'`` backfills every existing row in one statement, so prior
    trades/dividends become part of the TW portfolio.
    """
    insp = inspect(engine)
    existing_tables = set(insp.get_table_names())
    for table in ("trades", "dividends"):
        if table not in existing_tables:
            continue  # fresh DB — create_all already added the column
        cols = {c["name"] for c in insp.get_columns(table)}
        if "market" not in cols:
            with engine.begin() as conn:
                conn.execute(
                    text(
                        f"ALTER TABLE {table} "
                        "ADD COLUMN market VARCHAR(2) NOT NULL DEFAULT 'TW'"
                    )
                )


def _ensure_user_id_columns() -> None:
    """Add the ``user_id`` column to existing trades/dividends/chats tables.

    Like ``_ensure_market_column``, ``create_all`` won't ALTER an existing table,
    so a DB created before per-user scoping (the prod Neon DB) needs this. The
    ``DEFAULT 'legacy'`` backfills every existing row to the legacy bucket, which
    the un-authenticated web app keeps reading; a signed-in user's first request
    then adopts those rows (see app/auth.py). Idempotent on reruns. DDL is valid
    on both SQLite and Postgres.
    """
    insp = inspect(engine)
    existing_tables = set(insp.get_table_names())
    for table in ("trades", "dividends", "chats"):
        if table not in existing_tables:
            continue  # fresh DB — create_all already added the column
        cols = {c["name"] for c in insp.get_columns(table)}
        if "user_id" not in cols:
            with engine.begin() as conn:
                conn.execute(
                    text(
                        f"ALTER TABLE {table} "
                        "ADD COLUMN user_id VARCHAR(255) NOT NULL DEFAULT 'legacy'"
                    )
                )
                conn.execute(
                    text(f"CREATE INDEX IF NOT EXISTS ix_{table}_user_id "
                         f"ON {table} (user_id)")
                )


def _ensure_chat_image_columns() -> None:
    """Add the ``image_mime``/``image_data`` columns to an existing
    chat_messages table (see ``_ensure_market_column`` for why this is
    needed alongside ``create_all``). Idempotent; valid on SQLite and
    Postgres."""
    insp = inspect(engine)
    if "chat_messages" not in set(insp.get_table_names()):
        return  # fresh DB — create_all already added the columns
    cols = {c["name"] for c in insp.get_columns("chat_messages")}
    with engine.begin() as conn:
        if "image_mime" not in cols:
            conn.execute(text("ALTER TABLE chat_messages ADD COLUMN image_mime VARCHAR(40)"))
        if "image_data" not in cols:
            conn.execute(text("ALTER TABLE chat_messages ADD COLUMN image_data TEXT"))


def init_db() -> None:
    Base.metadata.create_all(bind=engine)
    _ensure_market_column()
    _ensure_user_id_columns()
    _ensure_chat_image_columns()
    seed_markets()


def get_db():
    db: Session = SessionLocal()
    try:
        yield db
    finally:
        db.close()
