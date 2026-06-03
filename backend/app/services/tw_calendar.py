"""TWSE market calendar — public-holiday closures.

The Taiwan Stock Exchange is closed on weekends and on the public-holiday
dates below. Source: TWSE 2026 holiday schedule
(https://www.twse.com.tw/en/trading/holiday.html).

⚠️ Update this list once a year — it only covers 2026. Rare make-up trading
Saturdays (補行交易) around long holidays are not modeled.
"""
from __future__ import annotations

from datetime import date

# 2026 TWSE closed dates (national holidays + observed/bridged days).
TW_MARKET_HOLIDAYS: frozenset[str] = frozenset(
    {
        "2026-01-01",  # Founding Day of the ROC / New Year
        "2026-02-16",  # Lunar New Year (eve)
        "2026-02-17",  # Lunar New Year
        "2026-02-18",  # Lunar New Year
        "2026-02-19",  # Lunar New Year
        "2026-02-20",  # Lunar New Year
        "2026-02-27",  # Peace Memorial Day (228 observed)
        "2026-04-03",  # Children's Day (observed)
        "2026-04-06",  # Tomb-Sweeping Day / Qingming (observed)
        "2026-05-01",  # Labor Day
        "2026-06-19",  # Dragon Boat Festival
        "2026-09-25",  # Mid-Autumn Festival
        "2026-09-28",  # Teachers' Day
        "2026-10-09",  # National Day (Double Tenth, observed)
        "2026-10-26",  # Taiwan Restoration Day (observed)
        "2026-12-25",  # Constitution Day
    }
)


def is_tw_market_holiday(d: date) -> bool:
    """True if the Taiwan market is closed for a public holiday on date ``d``."""
    return d.isoformat() in TW_MARKET_HOLIDAYS
