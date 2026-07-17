"""Live US quote streaming via Yahoo's WebSocket.

Yahoo pushes a tick the moment a trade prints (the same feed finance.yahoo.com
uses), so US prices update in real time instead of on the 5s REST poll. One
background task holds a single upstream connection subscribed to every US
ticker currently held by any user; ticks land in an in-memory table that

  * fans out to SSE subscribers (GET /api/quotes/stream) so clients render
    price changes the moment they happen, and
  * overlays the REST quote path (yahoo_quotes.get_quotes), so polled
    holdings/summary responses also carry the freshest price.

TW stocks are not streamed here — TWSE has no free tick feed; they stay on
the 5s MIS path (see tw_quotes.py).

Only REGULAR_MARKET ticks are applied. Pre/post-market prices would disagree
with the REST path's regularMarketPrice and silently change what "today's
move" means, so outside regular hours the stream simply goes quiet and the
REST close price stays authoritative.
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time
from collections import defaultdict
from dataclasses import dataclass

from .quotes import market_of

logger = logging.getLogger("live_quotes")

# How often the held-ticker set is re-read from the DB. A ticker bought a
# minute ago reaches the stream within this window; REST covers it meanwhile.
_REFRESH_SECONDS = 60.0
# Yahoo streams at most this many symbols for us. Personal portfolios are far
# below this; the cap just bounds the subscription if the DB grows unexpectedly.
_MAX_SYMBOLS = 100


@dataclass
class LiveTick:
    ticker: str                  # ticker as stored in trades (dotted class shares)
    price: float
    prev_close: float | None    # derived: price - change
    change: float | None        # vs previous close, from the feed
    change_pct: float | None
    day_volume: int | None
    ts: float                    # epoch seconds of the tick

    def payload(self) -> dict:
        return {
            "type": "tick",
            "ticker": self.ticker,
            "price": self.price,
            "prev_close": self.prev_close,
            "change": self.change,
            "change_pct": self.change_pct,
            "day_volume": self.day_volume,
            "ts": self.ts,
        }


_table: dict[str, LiveTick] = {}          # bare upper ticker -> latest tick
_table_lock = threading.Lock()             # written on the loop, read from threadpool
_subscribers: set[asyncio.Queue] = set()   # SSE listener queues (event loop only)
_task: asyncio.Task | None = None


# --- Public read API (safe from any thread) --------------------------------

def get(ticker: str) -> LiveTick | None:
    with _table_lock:
        return _table.get(ticker.strip().upper())


def snapshot() -> list[dict]:
    with _table_lock:
        return [t.payload() for t in _table.values()]


# --- SSE subscriber registry (event loop only) ------------------------------

def register() -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=500)
    _subscribers.add(q)
    return q


def unregister(q: asyncio.Queue) -> None:
    _subscribers.discard(q)


# --- Symbol universe ---------------------------------------------------------

def _yahoo_symbol(ticker: str) -> str:
    """Stored ticker -> Yahoo streaming symbol (class shares are dashed)."""
    t = ticker.strip().upper()
    return t.replace(".", "-") if "." in t and not t.startswith("^") else t


def _held_us_tickers() -> set[str]:
    """US tickers held by any user, plus every configured index symbol.

    Index symbols (``^GSPC`` …) stream over the same connection so the index
    strip ticks live too. Yahoo simply never sends REGULAR_MARKET ticks for
    an index whose exchange is closed, so over-subscribing is harmless.
    """
    import json

    from ..database import Metadata, SessionLocal, Trade
    from ..routers.indices import DEFAULT_INDICES

    net: dict[tuple[str, str], float] = defaultdict(float)
    market: dict[str, str] = {}
    symbols: set[str] = {s.upper() for s in DEFAULT_INDICES}
    with SessionLocal() as db:
        for t in db.query(Trade).all():
            ticker = t.ticker.strip().upper()
            net[(t.user_id, ticker)] += t.shares if t.type == "buy" else -t.shares
            market[ticker] = t.market or market_of(ticker)
        for row in db.query(Metadata).filter(Metadata.key.like("indices:%")).all():
            try:
                symbols.update(str(s).upper() for s in json.loads(row.value))
            except ValueError:
                pass
    held = {tk for (_uid, tk), n in net.items() if n > 1e-9}
    symbols.update(tk for tk in held if market.get(tk) == "US")
    return {s for s in symbols if s}


# --- Upstream listener -------------------------------------------------------

def _on_message(msg: dict, sym_to_ticker: dict[str, str]) -> None:
    sym = msg.get("id")
    price = msg.get("price")
    if not sym or price is None:
        return
    # market_hours: 0=pre, 1=regular, 2=post, 3=extended, 4=overnight. The
    # proto decodes it as a bare int (older yfinance gave the enum name).
    hours = msg.get("market_hours", 1)
    if str(hours) not in ("1", "REGULAR_MARKET"):
        return
    try:
        price = float(price)
    except (TypeError, ValueError):
        return

    def _f(key: str) -> float | None:
        v = msg.get(key)
        try:
            return float(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    change = _f("change")
    # proto int64 fields arrive as strings from MessageToDict
    try:
        ts = float(msg["time"]) / 1000.0
    except (KeyError, TypeError, ValueError):
        ts = time.time()
    try:
        day_volume = int(msg["day_volume"])
    except (KeyError, TypeError, ValueError):
        day_volume = None

    tick = LiveTick(
        ticker=sym_to_ticker.get(sym, sym),
        price=price,
        prev_close=price - change if change is not None else None,
        change=change,
        change_pct=_f("change_percent"),
        day_volume=day_volume,
        ts=ts,
    )
    with _table_lock:
        _table[tick.ticker] = tick

    payload = tick.payload()
    for q in list(_subscribers):
        try:
            q.put_nowait(payload)
        except asyncio.QueueFull:
            pass  # slow consumer: drop this tick, it's superseded momentarily


async def _resubscribe_loop(ws, sym_to_ticker: dict[str, str]) -> None:
    """Keep the upstream subscription in sync with what users actually hold."""
    while True:
        await asyncio.sleep(_REFRESH_SECONDS)
        tickers = await asyncio.to_thread(_held_us_tickers)
        wanted = {_yahoo_symbol(t): t for t in sorted(tickers)[:_MAX_SYMBOLS]}
        added = set(wanted) - set(sym_to_ticker)
        removed = set(sym_to_ticker) - set(wanted)
        sym_to_ticker.clear()
        sym_to_ticker.update(wanted)
        if added:
            await ws.subscribe(sorted(added))
        if removed:
            await ws.unsubscribe(sorted(removed))


async def _run() -> None:
    from yfinance import AsyncWebSocket

    while True:
        ws = None
        resub: asyncio.Task | None = None
        try:
            tickers = await asyncio.to_thread(_held_us_tickers)
            if not tickers:
                await asyncio.sleep(_REFRESH_SECONDS)
                continue
            sym_to_ticker = {_yahoo_symbol(t): t for t in sorted(tickers)[:_MAX_SYMBOLS]}
            ws = AsyncWebSocket(verbose=False)
            await ws.subscribe(sorted(sym_to_ticker))
            logger.info("live quotes: streaming %d US symbols", len(sym_to_ticker))
            resub = asyncio.create_task(_resubscribe_loop(ws, sym_to_ticker))
            await ws.listen(lambda m: _on_message(m, sym_to_ticker))
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning("live quotes: stream dropped (%s); reconnecting in 15s", e)
            await asyncio.sleep(15)
        finally:
            if resub is not None:
                resub.cancel()
            if ws is not None:
                try:
                    await ws.close()
                except Exception:
                    pass


def start() -> None:
    """Launch the background streaming task. Call once from FastAPI startup."""
    global _task
    if _task is not None:
        return
    try:
        _task = asyncio.get_running_loop().create_task(_run())
    except Exception as e:  # yfinance too old / no loop — degrade to REST-only
        logger.warning("live quotes disabled: %s", e)
