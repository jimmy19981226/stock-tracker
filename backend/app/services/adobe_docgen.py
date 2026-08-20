"""Adobe Document Generation — template + JSON → PDF.

Used only when ``ADOBE_CLIENT_ID`` / ``ADOBE_CLIENT_SECRET`` are set in the
server environment *and* the template `.docx` is present. Credentials live on
the server and nowhere else: the app talks to our backend, never to Adobe.

The flow Adobe's REST API asks for is four calls — get a token, ask for an
upload URI, PUT the template there, then submit the job and poll it. Kept
dependency-free (``urllib``) so the backend gains nothing to deploy for a code
path most installs will never take.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

_TOKEN_URL = "https://pdf-services.adobe.io/token"
_ASSETS_URL = "https://pdf-services.adobe.io/assets"
_DOCGEN_URL = "https://pdf-services.adobe.io/operation/documentgeneration"

_DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

# A Document Generation job is seconds, not minutes. Past this the caller falls
# back to the local renderer rather than leaving a report pending forever.
_POLL_TIMEOUT = 60.0
_POLL_INTERVAL = 1.0

_token_cache: tuple[float, str] | None = None


def _post(url: str, *, data: bytes | None, headers: dict) -> tuple[int, bytes, dict]:
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.read(), dict(response.headers)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Adobe {url} -> {exc.code}: {exc.read()[:300]!r}") from exc


def _access_token() -> str:
    """Cached until shortly before expiry — a token is good for ~24 h and every
    report would otherwise start by buying a new one."""
    global _token_cache
    now = time.time()
    if _token_cache and _token_cache[0] > now:
        return _token_cache[1]

    body = urllib.parse.urlencode({
        "client_id": os.environ["ADOBE_CLIENT_ID"],
        "client_secret": os.environ["ADOBE_CLIENT_SECRET"],
    }).encode()
    _status, payload, _headers = _post(
        _TOKEN_URL, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    parsed = json.loads(payload)
    token = parsed["access_token"]
    _token_cache = (now + int(parsed.get("expires_in", 3600)) - 300, token)
    return token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}",
            "x-api-key": os.environ["ADOBE_CLIENT_ID"]}


def _upload_template(token: str, template: Path) -> str:
    _status, payload, _ = _post(
        _ASSETS_URL,
        data=json.dumps({"mediaType": _DOCX_MIME}).encode(),
        headers={**_auth(token), "Content-Type": "application/json"})
    parsed = json.loads(payload)
    put = urllib.request.Request(parsed["uploadUri"], data=template.read_bytes(),
                                 headers={"Content-Type": _DOCX_MIME}, method="PUT")
    with urllib.request.urlopen(put, timeout=120):
        pass
    return parsed["assetID"]


def render(template: Path, payload: dict) -> bytes:
    """Render ``template`` against ``payload`` and return the PDF bytes."""
    token = _access_token()
    asset_id = _upload_template(token, template)

    _status, _body, headers = _post(
        _DOCGEN_URL,
        data=json.dumps({
            "assetID": asset_id,
            "outputFormat": "pdf",
            "jsonDataForMerge": payload,
        }).encode(),
        headers={**_auth(token), "Content-Type": "application/json"})

    location = headers.get("location") or headers.get("Location")
    if not location:
        raise RuntimeError("Adobe accepted the job but returned no polling location")

    deadline = time.time() + _POLL_TIMEOUT
    while time.time() < deadline:
        poll = urllib.request.Request(location, headers=_auth(token))
        with urllib.request.urlopen(poll, timeout=30) as response:
            state = json.loads(response.read())
        status = state.get("status")
        if status == "done":
            download = state.get("asset", {}).get("downloadUri")
            if not download:
                raise RuntimeError("Adobe reported done with no downloadUri")
            with urllib.request.urlopen(download, timeout=120) as response:
                return response.read()
        if status == "failed":
            raise RuntimeError(f"Adobe job failed: {state.get('error')}")
        time.sleep(_POLL_INTERVAL)

    raise RuntimeError("Adobe job did not finish within 60 s")
