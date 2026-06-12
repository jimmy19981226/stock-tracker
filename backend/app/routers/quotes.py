"""Quote-source status API.

GET /api/quotes/sources live-probes each TW quote source so the app can show
which ones are usable from this deployment and let the user pick one. The
pick itself travels back per request as the ``X-Quote-Source`` header
("auto" | "mis" | "yahoo"), applied by middleware in main.py.
"""
from concurrent.futures import ThreadPoolExecutor

from fastapi import APIRouter

from ..services import quote_relay_client, quotes, tw_quotes, yahoo_quotes

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
