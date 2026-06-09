"""Authentication: identify the request's user from a Google ID token.

Google is used for **login only**. The iOS app obtains a Google ID token and
sends it as ``Authorization: Bearer <token>``; we verify it and use the stable
``sub`` claim (prefixed ``google:``) as the per-user data scope.

Backward-compatible by design: a request with **no** token resolves to the
``"legacy"`` bucket, so the existing un-authenticated web frontend keeps working
on the pre-auth data. The first time a real Google user is seen, all ``legacy``
rows are adopted into their account (one-time), handing the existing portfolio to
its owner.
"""
from __future__ import annotations

import os

from fastapi import Header, HTTPException

from .database import Chat, Dividend, Metadata, SessionLocal, Trade

LEGACY_USER = "legacy"
_CLAIM_FLAG = "legacy_claimed_by"


def get_current_user(authorization: str | None = Header(default=None)) -> str:
    """FastAPI dependency → the request's user_id.

    No/blank token → ``"legacy"``. A valid Google token → ``"google:<sub>"``.
    An invalid/expired token → 401.
    """
    if not authorization:
        return LEGACY_USER
    parts = authorization.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].strip():
        return LEGACY_USER

    user_id = _verify_google_token(parts[1].strip())
    _maybe_adopt_legacy(user_id)
    return user_id


def _verify_google_token(token: str) -> str:
    try:
        from google.auth.transport import requests as google_requests
        from google.oauth2 import id_token
    except ImportError as exc:  # pragma: no cover
        raise HTTPException(
            status_code=503,
            detail="google-auth not installed on the server.",
        ) from exc

    # Audience check is enforced only when GOOGLE_CLIENT_ID is configured; until
    # then we still verify the signature, issuer and expiry.
    client_id = os.environ.get("GOOGLE_CLIENT_ID") or None
    try:
        info = id_token.verify_oauth2_token(token, google_requests.Request(), client_id)
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Invalid Google credential") from exc

    sub = info.get("sub")
    if not sub:
        raise HTTPException(status_code=401, detail="Google token missing subject")
    return f"google:{sub}"


def _maybe_adopt_legacy(user_id: str) -> None:
    """One-time: hand the pre-auth ``legacy`` data to the first real user."""
    with SessionLocal() as db:
        if db.get(Metadata, _CLAIM_FLAG) is not None:
            return
        for model in (Trade, Dividend, Chat):
            db.query(model).filter(model.user_id == LEGACY_USER).update(
                {model.user_id: user_id}, synchronize_session=False
            )
        db.add(Metadata(key=_CLAIM_FLAG, value=user_id))
        db.commit()
