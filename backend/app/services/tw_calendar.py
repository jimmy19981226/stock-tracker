"""TWSE market-holiday helper.

The holiday data now lives in the ``market_holidays`` table (see
services/markets.py) — this thin shim is kept for backward compatibility with
any caller that still imports ``is_tw_market_holiday``.
"""
from __future__ import annotations

from datetime import date


def is_tw_market_holiday(d: date) -> bool:
    """True if the Taiwan market is closed for a holiday on date ``d``."""
    from . import markets
    return markets.is_holiday("TW", d)
