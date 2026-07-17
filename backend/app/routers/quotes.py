"""Quote-source status + live-price streaming API.

GET /api/quotes/sources live-probes each TW quote source so the app can show
which ones are usable from this deployment and let the user pick one. The
pick itself travels back per request as the ``X-Quote-Source`` header
("auto" | "mis" | "yahoo"), applied by middleware in main.py.

GET /api/quotes/stream is an SSE feed of real-time US price ticks (fan-out of
the Yahoo WebSocket, see services/live_quotes.py). Clients get a snapshot of
the current live table on connect, then one event per tick.
"""
import asyncio
import json
from concurrent.futures import ThreadPoolExecutor

from fastapi import APIRouter, Depends
from fastapi.responses import StreamingResponse

from ..auth import get_current_user
from ..services import live_quotes, quote_relay_client, quotes, tw_quotes, yahoo_quotes

router = APIRouter(prefix="/api/quotes", tags=["quotes"])

_PROBE_TICKER = "2330"  # liquid TWSE ticker every source can serve


def _probe_relay() -> bool:
    if not quote_relay_client.configured():
        return False
    return bool(quote_relay_client.get_quotes([_PROBE_TICKER]))


def _probe_yahoo() -> bool:
    return bool(yahoo_quotes.get_quotes([_PROBE_TICKER]))


@router.get("/sources")
def quote_sources():
    """Availability of each quote source, probed live (a few seconds)."""
    with ThreadPoolExecutor(max_workers=3) as pool:
        relay = pool.submit(_probe_relay)
        direct = pool.submit(tw_quotes.probe)
        yahoo = pool.submit(_probe_yahoo)
        relay_ok, direct_ok, yahoo_ok = relay.result(), direct.result(), yahoo.result()

    return {
        "preference": quotes.source_preference.get(),
        "mis": {
            "available": relay_ok or direct_ok,
            "via": "relay" if relay_ok else ("direct" if direct_ok else None),
            "realtime": True,
        },
        "yahoo": {
            "available": yahoo_ok,
            "via": None,
            "realtime": False,
        },
    }


@router.get("/stream")
async def quote_stream(user: str = Depends(get_current_user)):
    """SSE stream of real-time US price ticks.

    Emits a ``snapshot`` event on connect (the current live table), then a
    ``tick`` event per trade print. A comment line goes out every 15s so
    proxies don't reap idle connections while the US market is closed.
    Prices are public data — auth only gates access, no per-user filtering.
    """
    q = live_quotes.register()

    async def gen():
        try:
            yield f"data: {json.dumps({'type': 'snapshot', 'ticks': live_quotes.snapshot()})}\n\n"
            while True:
                try:
                    payload = await asyncio.wait_for(q.get(), timeout=15.0)
                    yield f"data: {json.dumps(payload)}\n\n"
                except asyncio.TimeoutError:
                    yield ": keep-alive\n\n"
        finally:
            live_quotes.unregister(q)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
