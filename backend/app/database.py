import os
from datetime import datetime, date
from sqlalchemy import create_engine, inspect, text, String, Float, Date, DateTime, Integer, Text, ForeignKey
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


class Dividend(Base):
    __tablename__ = "dividends"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    ticker: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    amount: Mapped[float] = mapped_column(Float, nullable=False)
    pay_date: Mapped[date] = mapped_column(Date, nullable=False)
    notes: Mapped[str | None] = mapped_column(String(500), nullable=True)
    market: Mapped[str] = mapped_column(String(2), nullable=False, server_default="TW")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


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

    chat: Mapped["Chat"] = relationship(back_populates="messages")


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


def init_db() -> None:
    Base.metadata.create_all(bind=engine)
    _ensure_market_column()


def get_db():
    db: Session = SessionLocal()
    try:
        yield db
    finally:
        db.close()
