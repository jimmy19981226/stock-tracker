"""Read-only web dashboard: a simple password gate + scoped data endpoints.

The web app (deployed separately, e.g. on Vercel) is reachable on the public
internet, so it must not expose portfolio data to anyone with the URL. This
router gates it behind a single shared password (``WEB_DASHBOARD_PASSWORD``):

  1. ``POST /api/web/login`` with ``{"password": ...}`` → a short-lived signed
     token if the password matches.
  2. The dashboard sends that token as ``Authorization: Bearer <token>`` on the
     read-only ``/api/web/*`` data endpoints below.

The token is **stateless** (HMAC over its own expiry, keyed by the password) so
it survives process restarts and needs no server-side session store. Changing
``WEB_DASHBOARD_PASSWORD`` instantly invalidates every previously issued token.

All data is read from a single configurable scope, ``WEB_DASHBOARD_USER_ID``
(default ``"legacy"``) — point it at whichever bucket holds the portfolio you
want the dashboard to show. Everything here is strictly read-only; the web app
cannot mutate any data.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import time

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from ..database import Dividend, Trade, get_db
from ..services import portfolio

router = APIRouter(prefix="/api/web", tags=["web-dashboard"])

TOKEN_TTL_SECONDS = 12 * 60 * 60  # 12h; the dashboard re-logs in after that


def _password() -> str | None:
    pw = os.environ.get("WEB_DASHBOARD_PASSWORD", "")
    return pw or None


def _scope_user() -> str:
    return os.environ.get("WEB_DASHBOARD_USER_ID", "").strip() or "legacy"


def _signing_key() -> bytes:
    # Derive the HMAC key from the password so rotating the password revokes all
    # outstanding tokens. A fixed app-specific salt keeps the key from being the
    # bare password bytes.
    pw = _password() or ""
    return hashlib.sha256(b"web-dashboard\x00" + pw.encode("utf-8")).digest()


def _mint_token() -> tuple[str, int]:
    expiry = int(time.time()) + TOKEN_TTL_SECONDS
    payload = str(expiry).encode("ascii")
    sig = hmac.new(_signing_key(), payload, hashlib.sha256).hexdigest()
    return f"{expiry}.{sig}", TOKEN_TTL_SECONDS


def _token_valid(token: str) -> bool:
    try:
        expiry_str, sig = token.split(".", 1)
        expiry = int(expiry_str)
    except (ValueError, AttributeError):
        return False
    expected = hmac.new(_signing_key(), expiry_str.encode("ascii"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return False
    return expiry > int(time.time())


def require_web_auth(authorization: str | None = Header(default=None)) -> str:
    """Dependency for the read-only data endpoints → the scope user_id."""
    if _password() is None:
        raise HTTPException(
            status_code=503,
            detail="Web dashboard is not enabled (WEB_DASHBOARD_PASSWORD unset).",
        )
    parts = (authorization or "").split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not _token_valid(parts[1].strip()):
        raise HTTPException(status_code=401, detail="Sign in to view the dashboard.")
    return _scope_user()


class LoginBody(BaseModel):
    password: str


@router.get("/config")
def web_config():
    """Tells the frontend whether the gate is enabled, without leaking anything."""
    return {"enabled": _password() is not None}


@router.post("/login")
def web_login(body: LoginBody):
    expected = _password()
    if expected is None:
        raise HTTPException(
            status_code=503,
            detail="Web dashboard is not enabled (WEB_DASHBOARD_PASSWORD unset).",
        )
    # Constant-time compare so a wrong password can't be timed character by char.
    if not hmac.compare_digest(body.password or "", expected):
        raise HTTPException(status_code=401, detail="Incorrect password.")
    token, ttl = _mint_token()
    return {"token": token, "expires_in": ttl}


@router.get("/overview")
def web_overview(db: Session = Depends(get_db), user: str = Depends(require_web_auth)):
    return portfolio.build_overview(db, user)


@router.get("/holdings")
def web_holdings(db: Session = Depends(get_db), user: str = Depends(require_web_auth)):
    return portfolio.build_holdings(db, user)


@router.get("/summary")
def web_summary(db: Session = Depends(get_db), user: str = Depends(require_web_auth)):
    holdings = portfolio.build_holdings(db, user)
    return portfolio.summarize(holdings, db, user)


@router.get("/earnings-history")
def web_earnings_history(
    days: int = Query(180, ge=7, le=1825),
    db: Session = Depends(get_db),
    user: str = Depends(require_web_auth),
):
    return portfolio.build_earnings_history(db, user, days=days)


# Period tabs the net-worth chart offers (mirrors /api/portfolio/value-history).
_VALUE_PERIODS = {"5d", "1mo", "3mo", "6mo", "ytd", "1y", "2y", "5y", "max"}


@router.get("/value-history")
def web_value_history(
    market: str = Query("TW", pattern="^(TW|US)$"),
    period: str = Query("1y"),
    db: Session = Depends(get_db),
    user: str = Depends(require_web_auth),
):
    """Daily total market value of one market's holdings — the same series the
    iOS app charts, served read-only for the web dashboard's net-worth chart."""
    if period not in _VALUE_PERIODS:
        period = "1y"
    return portfolio.build_value_history(db, user, market=market, period=period)


@router.get("/trades")
def web_trades(db: Session = Depends(get_db), user: str = Depends(require_web_auth)):
    rows = (
        db.query(Trade)
        .filter(Trade.user_id == user)
        .order_by(Trade.trade_date.desc(), Trade.id.desc())
        .all()
    )
    return [
        {
            "id": t.id,
            "type": t.type,
            "ticker": t.ticker,
            "shares": t.shares,
            "price": t.price,
            "fee": t.fee,
            "trade_date": t.trade_date.isoformat() if t.trade_date else None,
            "market": t.market,
        }
        for t in rows
    ]


@router.get("/dividends")
def web_dividends(db: Session = Depends(get_db), user: str = Depends(require_web_auth)):
    rows = (
        db.query(Dividend)
        .filter(Dividend.user_id == user)
        .order_by(Dividend.pay_date.desc(), Dividend.id.desc())
        .all()
    )
    return [
        {
            "id": d.id,
            "ticker": d.ticker,
            "amount": d.amount,
            "pay_date": d.pay_date.isoformat() if d.pay_date else None,
            "market": d.market,
        }
        for d in rows
    ]
