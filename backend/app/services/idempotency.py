"""In-memory replay cache for non-idempotent writes.

A client that retries a POST after a transport failure (dead keep-alive to an
idled backend, timeout mid-flight) can't know whether the original insert
landed. Clients send a per-attempt ``Idempotency-Key`` header; when a key is
seen again within the TTL, the stored response is returned instead of
inserting a duplicate row.

Process-local by design — this deployment is single-instance. The
check-then-store isn't atomic across the request's DB commit, so two truly
simultaneous requests with the same key could both insert; in practice the
client only retries after the first attempt already failed at the transport
layer, so the original has either finished or never arrived.
"""
from __future__ import annotations

import time
from threading import Lock

_TTL_SECONDS = 600.0
_store: dict[tuple[str, str], tuple[float, object]] = {}
_lock = Lock()


def replay(user_id: str, key: str | None) -> object | None:
    """The stored response for (user, key), or None if unseen/expired."""
    if not key:
        return None
    now = time.time()
    with _lock:
        _purge(now)
        hit = _store.get((user_id, key))
    return hit[1] if hit else None


def remember(user_id: str, key: str | None, response: object) -> None:
    if not key:
        return
    with _lock:
        _store[(user_id, key)] = (time.time(), response)


def _purge(now: float) -> None:
    for k in [k for k, (at, _) in _store.items() if now - at > _TTL_SECONDS]:
        _store.pop(k, None)
