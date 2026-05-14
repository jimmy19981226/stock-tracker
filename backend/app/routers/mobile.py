"""Mobile bridge: hand off image/PDF uploads from a phone to the desktop.

The desktop UI generates a short-lived upload token and renders it as a QR
code. The phone scans, opens the URL on this backend (so the phone must be
on the same LAN), uploads the file via a tiny mobile-friendly page, and
the desktop polls until the parse is ready — at which point the same
preview-and-confirm flow used by the desktop paperclip kicks in.

Only the upload bytes live in memory, keyed by token; nothing is persisted.
Sessions expire after :data:`SESSION_TTL_SECONDS` of inactivity.
"""
from __future__ import annotations

import json
import os
import secrets
import socket
import time
from dataclasses import dataclass, field
from threading import Lock
from typing import Literal

from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import HTMLResponse

# Reuse the parser we already wrote for the desktop paperclip so phone
# uploads go through the exact same Gemini pipeline + JSON schema.
from .ai import (
    PARSE_ALLOWED_MIMES,
    PARSE_MAX_BYTES,
    _PARSE_PROMPT,
    _PARSE_SCHEMA,
    DEFAULT_MODEL,
)


router = APIRouter(prefix="/api/mobile", tags=["mobile"])

SESSION_TTL_SECONDS = 5 * 60  # tokens self-expire 5 min after creation
PARSE_STATUS = Literal["pending", "received", "parsing", "ready", "error"]


@dataclass
class _Session:
    token: str
    created_at: float
    status: PARSE_STATUS = "pending"
    file_bytes: bytes | None = None
    file_mime: str | None = None
    file_name: str | None = None
    parsed: dict | None = None  # {"trades": [...], "dividends": [...], "notes": "..."}
    error: str | None = None
    # Lock so the desktop's poll and the phone's upload don't trip over each
    # other when we transition state.
    lock: Lock = field(default_factory=Lock)


_sessions: dict[str, _Session] = {}
_sessions_lock = Lock()


def _purge_expired(now: float | None = None) -> None:
    """Drop sessions older than the TTL. Cheap because there are at most
    a handful at a time per user."""
    now = now or time.time()
    with _sessions_lock:
        expired = [
            t for t, s in _sessions.items() if now - s.created_at > SESSION_TTL_SECONDS
        ]
        for t in expired:
            _sessions.pop(t, None)


def _detect_lan_ip() -> str:
    """Best-effort LAN IP for the QR URL. Opens a UDP socket to a public
    address (no packets sent, just sets up routing) and reads back the
    local end of the connection. Falls back to 127.0.0.1 — the phone
    won't be able to reach that, but at least the UI doesn't crash."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        try:
            s.close()
        except Exception:
            pass


def _backend_origin() -> str:
    """The base URL the phone should hit. Always points at the backend,
    never the dev server.

    Honours ``MOBILE_PUBLIC_HOST`` for users behind unusual networks
    (e.g. running behind a reverse proxy or on Tailscale); otherwise
    builds ``http://<LAN-IP>:<STOCK_TRACKER_PORT>``.

    We DO NOT trust ``request.url.port`` here. In dev the desktop hits
    this endpoint through Vite's ``/api`` proxy, which by default
    forwards the ``Host: 127.0.0.1:5173`` header — so trusting the
    request port would put the Vite dev port in the QR and the phone
    would land on a blank React shell that doesn't know /m/upload."""
    override = os.environ.get("MOBILE_PUBLIC_HOST", "").strip()
    if override:
        return override.rstrip("/")
    try:
        port = int(os.environ.get("STOCK_TRACKER_PORT", "8000"))
    except ValueError:
        port = 8000
    return f"http://{_detect_lan_ip()}:{port}"


@router.post("/sessions")
def create_session():
    """Mint a new upload session. Desktop UI renders the returned ``url``
    as a QR + plain-text fallback, then polls ``GET /api/mobile/sessions/{token}``."""
    api_key = os.environ.get("GOOGLE_AI_API_KEY")
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="GOOGLE_AI_API_KEY not set — phone import needs the AI assistant configured.",
        )

    _purge_expired()
    token = secrets.token_urlsafe(16)
    sess = _Session(token=token, created_at=time.time())
    with _sessions_lock:
        _sessions[token] = sess

    origin = _backend_origin()
    return {
        "token": token,
        "url": f"{origin}/m/upload/{token}",
        "expires_in": SESSION_TTL_SECONDS,
        "lan_ip": _detect_lan_ip(),
    }


@router.get("/sessions/{token}")
def session_status(token: str):
    """Desktop polls this. When the phone has uploaded, the first poll
    after upload runs the Gemini parse and caches it; subsequent polls
    return the cached result."""
    _purge_expired()
    with _sessions_lock:
        sess = _sessions.get(token)
    if sess is None:
        raise HTTPException(status_code=404, detail="Session expired or unknown")

    # If the phone has uploaded but we haven't parsed yet, kick off the
    # parse on this poll. Only ONE poller should run Gemini, so we capture
    # the transition under the lock and key the parse off the captured
    # boolean — checking ``sess.status == "parsing"`` outside the lock would
    # let a second concurrent poll re-trigger the call.
    do_parse = False
    with sess.lock:
        if sess.status == "received":
            sess.status = "parsing"
            do_parse = True

    if do_parse:
        try:
            parsed = _run_parse(sess.file_bytes or b"", sess.file_mime or "")
            with sess.lock:
                sess.parsed = parsed
                sess.status = "ready"
        except HTTPException as exc:
            with sess.lock:
                sess.status = "error"
                sess.error = str(exc.detail)
        except Exception as exc:
            with sess.lock:
                sess.status = "error"
                sess.error = f"{type(exc).__name__}: {exc}"

    return {
        "status": sess.status,
        "file_name": sess.file_name,
        "parsed": sess.parsed,
        "error": sess.error,
    }


@router.delete("/sessions/{token}", status_code=204)
def delete_session(token: str):
    """Desktop calls this when the user closes the modal or the records
    have been imported, freeing the in-memory bytes."""
    with _sessions_lock:
        _sessions.pop(token, None)


@router.post("/sessions/{token}/file")
async def upload_file(token: str, file: UploadFile = File(...)):
    """Phone hits this from the mobile upload page."""
    _purge_expired()
    with _sessions_lock:
        sess = _sessions.get(token)
    if sess is None:
        raise HTTPException(status_code=404, detail="Session expired. Refresh the QR code.")

    mime = (file.content_type or "").lower().strip()
    if mime not in PARSE_ALLOWED_MIMES:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported file type: {mime or 'unknown'}.",
        )

    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty file.")
    if len(raw) > PARSE_MAX_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File too large ({len(raw) / 1e6:.1f} MB). Max {PARSE_MAX_BYTES // (1024 * 1024)} MB.",
        )

    with sess.lock:
        sess.file_bytes = raw
        sess.file_mime = mime
        sess.file_name = file.filename or "upload"
        sess.status = "received"

    return {"ok": True, "size": len(raw)}


def _run_parse(raw: bytes, mime: str) -> dict:
    """Gemini call — same schema/prompt as the desktop /api/ai/parse-records."""
    api_key = os.environ.get("GOOGLE_AI_API_KEY")
    if not api_key:
        raise HTTPException(status_code=503, detail="GOOGLE_AI_API_KEY not set")

    try:
        from google import genai
        from google.genai import types
    except ImportError:
        raise HTTPException(status_code=503, detail="google-genai not installed")

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
        raise HTTPException(status_code=422, detail=f"Bad JSON from model: {exc}")

    return {
        "trades": parsed.get("trades") or [],
        "dividends": parsed.get("dividends") or [],
        "notes": parsed.get("notes") or "",
    }


# ---- Mobile-facing HTML page (served at /m/upload/{token}) -----------------

page_router = APIRouter(tags=["mobile-page"])


@page_router.get("/m/upload/{token}", response_class=HTMLResponse)
def mobile_upload_page(token: str):
    """Tiny self-contained upload page the phone opens when scanning the QR.

    No JS framework, no external assets — this needs to load and work even
    on a flaky cellular connection. All styles inline."""
    _purge_expired()
    with _sessions_lock:
        exists = token in _sessions
    return HTMLResponse(_mobile_html(token, exists))


def _mobile_html(token: str, exists: bool) -> str:
    if not exists:
        return (
            "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>Upload expired</title>"
            "<style>body{font-family:system-ui;background:#0a0e16;color:#e8ecf2;padding:24px;text-align:center}"
            "h1{font-size:18px;margin:24px 0 8px}p{color:#9aa3b8;font-size:14px;line-height:1.5}</style></head>"
            "<body><h1>Upload link expired</h1>"
            "<p>Refresh the QR code on your computer and try again.</p></body></html>"
        )
    # The form posts to /api/mobile/sessions/{token}/file. We use plain HTML +
    # a sprinkle of inline JS so we can show progress and errors without a
    # full page reload (better UX on mobile data).
    return f"""<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<meta name="theme-color" content="#0a0e16">
<title>AI Stock Studio · Upload</title>
<style>
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; padding: 0; }}
  body {{
    font-family: -apple-system, system-ui, sans-serif;
    background: #0a0e16;
    color: #e8ecf2;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 24px 20px 40px;
  }}
  .mark {{ font-size: 28px; color: #6384ff; margin-bottom: 8px; }}
  h1 {{ font-size: 18px; margin: 0 0 4px; font-weight: 600; }}
  .sub {{ color: #9aa3b8; font-size: 13px; margin-bottom: 24px; text-align: center; line-height: 1.5; }}
  label.picker {{
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    width: 100%;
    max-width: 380px;
    padding: 32px 20px;
    border: 2px dashed rgba(99, 132, 255, 0.45);
    border-radius: 16px;
    background: rgba(99, 132, 255, 0.06);
    cursor: pointer;
    transition: background 140ms;
  }}
  label.picker:active {{ background: rgba(99, 132, 255, 0.14); }}
  .picker-icon {{ font-size: 36px; margin-bottom: 10px; }}
  .picker-title {{ font-weight: 600; font-size: 15px; margin-bottom: 4px; }}
  .picker-sub {{ color: #9aa3b8; font-size: 12px; text-align: center; }}
  input[type=file] {{ display: none; }}
  button.go {{
    margin-top: 18px;
    width: 100%;
    max-width: 380px;
    padding: 14px 16px;
    font-size: 15px;
    font-weight: 600;
    color: white;
    background: linear-gradient(135deg, #6384ff, #a78bfa);
    border: none;
    border-radius: 12px;
    cursor: pointer;
  }}
  button.go:disabled {{ opacity: 0.45; cursor: not-allowed; }}
  .file-name {{ margin-top: 12px; font-size: 13px; color: #9aa3b8; max-width: 380px; word-break: break-all; text-align: center; }}
  .status {{ margin-top: 18px; font-size: 13px; padding: 12px 16px; border-radius: 10px; max-width: 380px; width: 100%; text-align: center; }}
  .status.ok {{ background: rgba(52, 211, 153, 0.12); color: #34d399; border: 1px solid rgba(52, 211, 153, 0.4); }}
  .status.err {{ background: rgba(248, 113, 113, 0.12); color: #fca5a5; border: 1px solid rgba(248, 113, 113, 0.4); }}
  .footer {{ margin-top: auto; padding-top: 32px; color: #6b7589; font-size: 11px; text-align: center; }}
</style>
</head>
<body>
  <div class="mark">✦</div>
  <h1>Send to your portfolio</h1>
  <div class="sub">Upload a brokerage screenshot or PDF. The AI on your computer will extract trades and dividends — you'll review on the desktop before anything is saved.</div>

  <form id="form">
    <label class="picker" for="file">
      <div class="picker-icon">📷</div>
      <div class="picker-title">Choose photo or PDF</div>
      <div class="picker-sub">Tap to pick from camera or files</div>
      <input id="file" name="file" type="file" accept="image/*,application/pdf">
    </label>
    <div id="filename" class="file-name"></div>
    <button class="go" id="go" type="submit" disabled>Send to desktop</button>
    <div id="status" class="status" style="display:none"></div>
  </form>

  <div class="footer">AI Stock Studio · session expires in 5 min</div>

<script>
  const form = document.getElementById('form');
  const fileEl = document.getElementById('file');
  const goEl = document.getElementById('go');
  const nameEl = document.getElementById('filename');
  const statusEl = document.getElementById('status');

  fileEl.addEventListener('change', () => {{
    const f = fileEl.files && fileEl.files[0];
    nameEl.textContent = f ? f.name : '';
    goEl.disabled = !f;
  }});

  form.addEventListener('submit', async (e) => {{
    e.preventDefault();
    const f = fileEl.files && fileEl.files[0];
    if (!f) return;
    goEl.disabled = true;
    goEl.textContent = 'Sending…';
    statusEl.style.display = 'none';
    const data = new FormData();
    data.append('file', f);
    try {{
      const res = await fetch('/api/mobile/sessions/{token}/file', {{ method: 'POST', body: data }});
      if (!res.ok) {{
        let msg = res.status + ' ' + res.statusText;
        try {{ const j = await res.json(); if (j && j.detail) msg = j.detail; }} catch (_) {{}}
        throw new Error(msg);
      }}
      statusEl.className = 'status ok';
      statusEl.textContent = '✓ Sent! Switch to your desktop to review and confirm.';
      statusEl.style.display = 'block';
      goEl.textContent = 'Done';
    }} catch (err) {{
      statusEl.className = 'status err';
      statusEl.textContent = (err && err.message) ? err.message : 'Upload failed.';
      statusEl.style.display = 'block';
      goEl.disabled = false;
      goEl.textContent = 'Try again';
    }}
  }});
</script>
</body>
</html>"""
