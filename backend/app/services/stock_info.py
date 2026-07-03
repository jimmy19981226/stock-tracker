"""Per-stock fundamentals + historical prices via yfinance.

yfinance is used only for slow-moving data — fundamentals (P/E, market
cap, sector, etc.) and daily price history. Live intraday quotes still
go through TWSE MIS in ``tw_quotes.py``; yfinance prices for TW are
delayed and unsuitable for the dashboard.

All calls cache per-process so the per-stock detail page can be opened
many times without hammering yfinance. Fundamentals cache 1 hour;
history caches 30 minutes (so today's bar updates a few times during
the session); the latest day's bar is always extended on demand from
MIS so it reflects intraday movement, not yesterday's close.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone
from threading import Lock
from typing import Any

from .quotes import resolve_symbol


_FUNDAMENTALS_TTL = 3600.0    # 1 hour
_HISTORY_TTL = 1800.0          # 30 minutes
_FINANCIALS_TTL = 6 * 3600.0   # 6 hours — month/quarter data updates rarely

_fundamentals_cache: dict[str, tuple[float, dict]] = {}
_history_cache: dict[tuple[str, str], tuple[float, list[dict]]] = {}
_monthly_revenue_cache: dict[str, tuple[float, list[dict]]] = {}
_quarterly_financials_cache: dict[str, tuple[float, list[dict]]] = {}
_lock = Lock()


def _bare_tw(ticker: str) -> str:
    """Strip .TW/.TWO suffix to get the numeric code FinMind expects."""
    t = ticker.strip().upper()
    return t.split(".", 1)[0] if "." in t else t


def _yticker(ticker: str):
    """Lazy-import yfinance so the module loads even if yfinance is missing."""
    import yfinance as yf

    return yf.Ticker(resolve_symbol(ticker))


def _normalize_date(value: Any) -> str | None:
    """yfinance returns calendar dates as Unix-epoch ints, datetime/date
    objects, or already-formatted strings (and sometimes lists for ranged
    earnings estimates). Always return a single ISO date string or None."""
    if value is None:
        return None
    if isinstance(value, (list, tuple)) and value:
        # Earnings estimates often come as [start, end]; show the earliest.
        value = value[0]
    if isinstance(value, (datetime, date)):
        return (value.date() if isinstance(value, datetime) else value).isoformat()
    if isinstance(value, (int, float)):
        # Unix epoch seconds (sometimes ms — rough sanity threshold).
        try:
            secs = float(value)
            if secs > 1e12:  # likely ms
                secs /= 1000
            return datetime.fromtimestamp(secs, tz=timezone.utc).date().isoformat()
        except (OverflowError, OSError, ValueError):
            return None
    if isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        # Already an ISO date or datetime string?
        try:
            return datetime.fromisoformat(s.replace("Z", "+00:00")).date().isoformat()
        except ValueError:
            return s  # unrecognized but non-empty — pass through
    return None


def get_fundamentals(ticker: str) -> dict[str, Any]:
    """Return a small subset of yfinance ``info`` keys: market cap, P/E, EPS,
    dividend yield, 52-week range, sector, industry, name. Missing fields
    come back as ``None`` rather than absent."""
    now = time.time()
    sym = resolve_symbol(ticker)
    with _lock:
        cached = _fundamentals_cache.get(sym)
        if cached and now - cached[0] < _FUNDAMENTALS_TTL:
            return cached[1]

    info: dict = {}
    calendar: dict | None = None
    try:
        yt = _yticker(ticker)
        info = yt.info or {}
        # ticker.calendar holds the next earnings date (a dict with
        # "Earnings Date": [d1, d2]) when yfinance can find it. info's
        # "earningsDate" is unreliable — often missing for non-US tickers.
        try:
            cal = yt.calendar
            if isinstance(cal, dict):
                calendar = cal
        except Exception:
            calendar = None
    except Exception:
        info = {}

    # yfinance is inconsistent across versions about whether dividendYield
    # is returned as a decimal (0.01 = 1%) or a percentage (1.0 = 1%). Some
    # tickers also return 0 instead of None when there's no dividend.
    # Normalize: anything > 1 is treated as a percentage and divided by 100,
    # so callers can always do `value * 100` for display.
    raw_yield = info.get("dividendYield")
    if raw_yield is not None and raw_yield > 1:
        raw_yield = raw_yield / 100

    out = {
        "symbol": sym,
        "long_name": info.get("longName"),
        "short_name": info.get("shortName"),
        "sector": info.get("sector"),
        "industry": info.get("industry"),
        "market_cap": info.get("marketCap"),
        "currency": info.get("currency"),
        "pe": info.get("trailingPE") or info.get("forwardPE"),
        "forward_pe": info.get("forwardPE"),
        "eps": info.get("trailingEps"),
        "dividend_yield": raw_yield,
        "dividend_rate": info.get("dividendRate"),
        "payout_ratio": info.get("payoutRatio"),
        "fifty_two_week_high": info.get("fiftyTwoWeekHigh"),
        "fifty_two_week_low": info.get("fiftyTwoWeekLow"),
        "fifty_day_avg": info.get("fiftyDayAverage"),
        "two_hundred_day_avg": info.get("twoHundredDayAverage"),
        "beta": info.get("beta"),
        "book_value": info.get("bookValue"),
        "price_to_book": info.get("priceToBook"),
        "shares_outstanding": info.get("sharesOutstanding"),
        # Volume averages — Yahoo's "Avg. Volume" is the 3-month avg
        # (info["averageVolume"]); the 10-day version is also useful
        # for short-term context.
        "average_volume": info.get("averageVolume"),
        "average_volume_10d": info.get("averageVolume10days") or info.get("averageDailyVolume10Day"),
        # Calendar dates — yfinance returns these as ISO strings, ints
        # (Unix epoch in seconds), or datetime/date objects depending
        # on the ticker and version. Normalize all to ISO date strings.
        # Prefer ticker.calendar for earnings date (info field is often
        # missing on non-US tickers).
        "earnings_date": _normalize_date(
            (calendar or {}).get("Earnings Date")
            or info.get("earningsDate")
        ),
        "ex_dividend_date": _normalize_date(info.get("exDividendDate")),
        "last_dividend_date": _normalize_date(info.get("lastDividendDate")),
        # Analyst price targets
        "target_mean_price": info.get("targetMeanPrice"),
        "target_median_price": info.get("targetMedianPrice"),
        "target_high_price": info.get("targetHighPrice"),
        "target_low_price": info.get("targetLowPrice"),
        "analyst_count": info.get("numberOfAnalystOpinions"),
        "recommendation_mean": info.get("recommendationMean"),
        "recommendation_key": info.get("recommendationKey"),
    }

    with _lock:
        _fundamentals_cache[sym] = (now, out)
    return out


def _history_symbol_candidates(sym: str) -> list[str]:
    """Yahoo symbol variants to try in order. TPEx (OTC) tickers need ``.TWO``
    instead of ``.TW``; US share classes are dashed on Yahoo (``BRK-B``, not
    the ``BRK.B`` brokers print)."""
    out = [sym]
    if sym.endswith(".TW"):
        out.append(sym[:-3] + ".TWO")
    elif "." in sym and not sym.startswith("^") and not sym.endswith(".TWO"):
        out.append(sym.replace(".", "-"))
    return out


def get_history(ticker: str, period: str = "1y") -> list[dict]:
    """Daily OHLCV bars for the requested period.

    period: yfinance shorthand — ``1mo``, ``3mo``, ``6mo``, ``1y``, ``2y``,
    ``5y``, ``max``. Returned as a list of
    ``{date, open, high, low, close, volume}`` dicts, oldest first.
    """
    import yfinance as yf

    now = time.time()
    sym = resolve_symbol(ticker)
    key = (sym, period)
    with _lock:
        cached = _history_cache.get(key)
        if cached and now - cached[0] < _HISTORY_TTL:
            return cached[1]

    df = None
    for candidate in _history_symbol_candidates(sym):
        try:
            df = yf.Ticker(candidate).history(period=period, auto_adjust=False)
        except Exception:
            df = None
        if df is not None and not df.empty:
            break

    if df is None or df.empty:
        # Negative-cache misses too: portfolio value-history sweeps every
        # ticker ever traded, and re-hitting Yahoo for known-dead symbols on
        # every request is what made it crawl. Retried after the normal TTL.
        with _lock:
            _history_cache[key] = (now, [])
        return []

    bars: list[dict] = []
    for idx, row in df.iterrows():
        try:
            bars.append({
                "date": idx.date().isoformat() if hasattr(idx, "date") else str(idx)[:10],
                "open": float(row.get("Open")) if row.get("Open") == row.get("Open") else None,
                "high": float(row.get("High")) if row.get("High") == row.get("High") else None,
                "low": float(row.get("Low")) if row.get("Low") == row.get("Low") else None,
                "close": float(row.get("Close")) if row.get("Close") == row.get("Close") else None,
                "volume": int(row.get("Volume")) if row.get("Volume") == row.get("Volume") else None,
            })
        except Exception:
            continue

    with _lock:
        _history_cache[key] = (now, bars)
    return bars


def get_taiex_history(period: str = "1y") -> list[dict]:
    """TAIEX (台股加權) daily history for benchmark comparison."""
    return get_history("^TWII", period)


# ---------------------------------------------------------------------
# Taiwan-specific financials — monthly revenue + quarterly EPS
# ---------------------------------------------------------------------

_FINMIND_URL = "https://api.finmindtrade.com/api/v4/data"


def get_monthly_revenue(ticker: str, months: int = 24) -> list[dict]:
    """Last `months` months of revenue from FinMind (free tier, no key
    needed for this dataset). Each row: {month, revenue, yoy_pct}.

    The `month` field is the actual reporting month (e.g. "2026-04" =
    April 2026 revenue), not FinMind's internal `date` (which is the
    filing date). yoy_pct compares to the same month a year prior.
    """
    bare = _bare_tw(ticker)
    if not bare.isdigit() and not (bare[:-1].isdigit() and bare[-1].isalpha()):
        return []

    now = time.time()
    with _lock:
        cached = _monthly_revenue_cache.get(bare)
        if cached and now - cached[0] < _FINANCIALS_TTL:
            return cached[1][-months:]

    # Pull a wide window so YoY pairs always have prior-year data.
    start = (datetime.now(timezone.utc).date().replace(day=1)).replace(
        year=datetime.now(timezone.utc).year - 3
    ).isoformat()
    url = f"{_FINMIND_URL}?" + urllib.parse.urlencode({
        "dataset": "TaiwanStockMonthRevenue",
        "data_id": bare,
        "start_date": start,
    })
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            payload = json.loads(resp.read())
    except Exception:
        return []

    raw = payload.get("data") or []
    # Build a {YYYY-MM: revenue} lookup keyed by the actual reporting month.
    by_month: dict[str, int] = {}
    for r in raw:
        try:
            y = int(r["revenue_year"])
            m = int(r["revenue_month"])
            v = int(r["revenue"])
        except (KeyError, ValueError, TypeError):
            continue
        by_month[f"{y:04d}-{m:02d}"] = v

    if not by_month:
        return []

    rows: list[dict] = []
    for key in sorted(by_month):
        rev = by_month[key]
        # YoY: compare to the same month in the prior year.
        y = int(key[:4]) - 1
        m = key[5:]
        prev = by_month.get(f"{y}-{m}")
        yoy_pct = ((rev - prev) / prev * 100) if prev else None
        rows.append({"month": key, "revenue": rev, "yoy_pct": yoy_pct})

    with _lock:
        _monthly_revenue_cache[bare] = (now, rows)
    return rows[-months:]


def get_quarterly_financials(ticker: str, quarters: int = 8) -> list[dict]:
    """Last `quarters` quarters from yfinance's quarterly_income_stmt.

    Each row: {quarter, revenue, net_income, gross_profit, operating_income,
    eps_diluted, gross_margin, operating_margin, net_margin}.
    Margins computed locally as percentages.
    """
    sym = resolve_symbol(ticker)
    now = time.time()
    with _lock:
        cached = _quarterly_financials_cache.get(sym)
        if cached and now - cached[0] < _FINANCIALS_TTL:
            return cached[1][-quarters:]

    try:
        df = _yticker(ticker).quarterly_income_stmt
    except Exception:
        return []

    if df is None or df.empty:
        return []

    def _row(label: str, col) -> float | None:
        if label not in df.index:
            return None
        v = df.loc[label, col]
        try:
            v = float(v)
        except (TypeError, ValueError):
            return None
        # NaN check
        return v if v == v else None

    out: list[dict] = []
    # Columns are Timestamps, newest first; iterate so output is oldest-first.
    for col in reversed(list(df.columns)):
        revenue = _row("Total Revenue", col)
        net_income = _row("Net Income", col)
        gross_profit = _row("Gross Profit", col)
        operating_income = _row("Operating Income", col)
        eps_diluted = _row("Diluted EPS", col)
        eps = eps_diluted if eps_diluted is not None else _row("Basic EPS", col)

        # `revenue` kept truthy (non-zero) to avoid div-by-zero; numerators
        # checked with `is not None` so a legitimate 0 / loss isn't dropped.
        gross_margin = (gross_profit / revenue * 100) if revenue and gross_profit is not None else None
        operating_margin = (operating_income / revenue * 100) if revenue and operating_income is not None else None
        net_margin = (net_income / revenue * 100) if revenue and net_income is not None else None

        try:
            qkey = col.date().isoformat() if hasattr(col, "date") else str(col)[:10]
        except Exception:
            qkey = str(col)[:10]

        out.append({
            "quarter": qkey,
            "revenue": int(revenue) if revenue is not None else None,
            "net_income": int(net_income) if net_income is not None else None,
            "gross_profit": int(gross_profit) if gross_profit is not None else None,
            "operating_income": int(operating_income) if operating_income is not None else None,
            "eps_diluted": eps,
            "gross_margin": gross_margin,
            "operating_margin": operating_margin,
            "net_margin": net_margin,
        })

    with _lock:
        _quarterly_financials_cache[sym] = (now, out)
    return out[-quarters:]
