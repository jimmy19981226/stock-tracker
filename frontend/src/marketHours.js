// Is a market currently in session? Mirrors ios/StockTracker/Util/MarketHours.swift
// — weekday + open/close minutes evaluated in the market's OWN timezone, minus
// holidays. Both read the same /api/markets rows, so they can't drift.

const WEEKDAY_INDEX = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

// Intl gives us the wall clock in an arbitrary timezone without pulling in a
// date library. hourCycle "h23" keeps midnight at 0 rather than 24.
function localParts(timeZone, now) {
  const parts = {};
  for (const p of new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now)) {
    parts[p.type] = p.value;
  }
  return {
    weekday: WEEKDAY_INDEX[parts.weekday] ?? 0,
    date: `${parts.year}-${parts.month}-${parts.day}`,
    minutes: Number(parts.hour) * 60 + Number(parts.minute),
  };
}

export function isMarketOpen(market, now = new Date()) {
  if (!market || !market.timezone) return false;
  let p;
  try {
    p = localParts(market.timezone, now);
  } catch {
    return false; // unknown IANA zone — treat as closed rather than throwing
  }
  if (p.weekday === 0 || p.weekday === 6) return false;
  if ((market.holidays || []).includes(p.date)) return false;
  return p.minutes >= market.open_minute && p.minutes < market.close_minute;
}

// True while ANY market is trading — the dashboard shows both at once, so a
// single open market is reason enough to keep polling fast.
export function anyMarketOpen(markets, now = new Date()) {
  return (markets || []).some((m) => isMarketOpen(m, now));
}
