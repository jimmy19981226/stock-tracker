"""Quote relay — run this on a machine with a Taiwan internet connection.

TWSE MIS only answers requests coming from Taiwan, so a cloud-hosted backend
(Render/Fly/etc.) can't fetch live prices itself. Run this small relay on your
Taiwan PC, expose it (e.g. with a free Cloudflare Tunnel), and point the cloud
backend at it via QUOTE_RELAY_URL — the cloud then borrows this machine's TW
connection just for the live-quote hop. Everything else stays on the cloud.

Run it (PowerShell, from the backend/ folder):

    $env:QUOTE_RELAY_SECRET = "<a long random string>"
    python -m uvicorn quote_relay:app --port 8500

Then expose it in another terminal:

    cloudflared tunnel --url http://localhost:8500

and set QUOTE_RELAY_URL (the https://<name>.trycloudflare.com URL) and the
same QUOTE_RELAY_SECRET on the Render backend.

This relay is read-only (live quotes only) and never touches your database.
"""
from __future__ import annotations

import hmac
import os
import sys
from dataclasses import asdict
from pathlib import Path

# Make the app package importable when run directly from backend/.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fastapi import FastAPI, Header, HTTPException, Query  # noqa: E402

from app.services import tw_quotes  # noqa: E402

app = FastAPI(title="Stock Tracker quote relay")


def _check_secret(provided: str | None) -> None:
    expected = os.environ.get("QUOTE_RELAY_SECRET")
    if not expected:
        # No secret set → open relay. Fine for a quick local test, but set one
        # before exposing it publicly so randoms can't use your connection.
        return
    if not provided or not hmac.compare_digest(provided, expected):
        raise HTTPException(status_code=401, detail="bad or missing relay secret")


@app.get("/health")
def health():
    return {"status": "ok", "secret_required": bool(os.environ.get("QUOTE_RELAY_SECRET"))}


@app.get("/quotes")
def quotes(
    codes: str = Query(..., description="comma-separated tickers, e.g. 2330,2454"),
    x_relay_secret: str | None = Header(default=None),
):
    _check_secret(x_relay_secret)
    tickers = [c.strip() for c in codes.split(",") if c.strip()]
    data = tw_quotes.get_quotes(tickers)  # live TWSE MIS (works from a TW IP)
    return {"quotes": {t: asdict(q) for t, q in data.items()}}
