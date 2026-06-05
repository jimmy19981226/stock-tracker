export function fmtMoney(value: number | null | undefined, currency: string): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "—";
  const symbol = currency === "TWD" ? "NT$" : currency === "USD" ? "$" : "";
  const sign = value < 0 ? "-" : "";
  const abs = Math.abs(value);
  const fixed = abs.toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
  return `${sign}${symbol}${fixed}`;
}

export function fmtNumber(value: number | null | undefined, digits = 2): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "—";
  return value.toLocaleString(undefined, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
}

export function fmtPct(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "—";
  const sign = value > 0 ? "+" : "";
  return `${sign}${value.toFixed(2)}%`;
}

export function plClass(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "flat";
  if (value > 0) return "pos";
  if (value < 0) return "neg";
  return "flat";
}

export function isTwTicker(ticker: string): boolean {
  return /^\d{4,6}[A-Z]?(\.TW(O)?)?$/.test(ticker.trim().toUpperCase());
}

export type DatePreset =
  | "all"
  | "30d"
  | "90d"
  | "180d"
  | "365d"
  | "ytd"
  | "custom";

export function presetRange(preset: DatePreset): {
  from: string;
  to: string;
} {
  const today = new Date();
  // Build the date string from LOCAL components — toISOString() converts to
  // UTC first, which shifts the date by a day for users far from UTC.
  const localStr = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(
      d.getDate(),
    ).padStart(2, "0")}`;
  const toStr = localStr(today);
  const subtract = (days: number) => {
    const d = new Date(today);
    d.setDate(d.getDate() - days);
    return localStr(d);
  };
  switch (preset) {
    case "30d":
      return { from: subtract(30), to: toStr };
    case "90d":
      return { from: subtract(90), to: toStr };
    case "180d":
      return { from: subtract(180), to: toStr };
    case "365d":
      return { from: subtract(365), to: toStr };
    case "ytd":
      return { from: `${today.getFullYear()}-01-01`, to: toStr };
    default:
      return { from: "", to: "" };
  }
}

// --- Market sessions (config-driven; the data comes from /api/markets) ------
export interface MarketHours {
  timezone: string; // IANA, e.g. "Asia/Taipei", "America/New_York"
  open_minute: number; // minutes from local midnight (09:00 = 540)
  close_minute: number;
  holidays: string[]; // ISO dates (YYYY-MM-DD) the market is closed
}

/** Local weekday / date / minute-of-day for `now` in a given IANA timezone.
 *  Uses Intl so EST/EDT (DST) and any zone are handled without manual math. */
function localParts(timezone: string, now: Date): {
  weekday: string;
  date: string;
  minutes: number;
} {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  let hour = parseInt(get("hour"), 10);
  if (hour === 24) hour = 0; // some engines render midnight as "24"
  return {
    weekday: get("weekday"),
    date: `${get("year")}-${get("month")}-${get("day")}`,
    minutes: hour * 60 + parseInt(get("minute"), 10),
  };
}

function isTradingDay(m: MarketHours, weekday: string, date: string): boolean {
  return weekday !== "Sat" && weekday !== "Sun" && !m.holidays.includes(date);
}

/** Is `market` currently in session? Weekday + open/close minutes in the
 *  market's own timezone, minus its holiday closures. */
export function isMarketOpen(
  market: MarketHours | null | undefined,
  now: Date = new Date(),
): boolean {
  if (!market) return false;
  const p = localParts(market.timezone, now);
  if (!isTradingDay(market, p.weekday, p.date)) return false;
  return p.minutes >= market.open_minute && p.minutes < market.close_minute;
}

/** Minutes until the market opens or closes, whichever applies next. */
export function nextMarketTransition(
  market: MarketHours | null | undefined,
  now: Date = new Date(),
): { open: boolean; inMinutes: number } {
  if (!market) return { open: false, inMinutes: 0 };
  const p = localParts(market.timezone, now);
  if (isMarketOpen(market, now)) {
    return { open: true, inMinutes: market.close_minute - p.minutes };
  }
  // Closed — find the next trading day (today if still before the open).
  let daysAhead =
    isTradingDay(market, p.weekday, p.date) && p.minutes < market.open_minute ? 0 : 1;
  for (let i = 0; i < 14; i++) {
    const cand = new Date(now.getTime() + daysAhead * 86_400_000);
    const cp = localParts(market.timezone, cand);
    if (isTradingDay(market, cp.weekday, cp.date)) break;
    daysAhead += 1;
  }
  return {
    open: false,
    inMinutes: daysAhead * 24 * 60 + (market.open_minute - p.minutes),
  };
}

export function fmtRelativeTime(iso: string | null | undefined): string {
  if (!iso) return "never";
  const then = new Date(iso + (iso.endsWith("Z") ? "" : "Z"));
  const diffSec = (Date.now() - then.getTime()) / 1000;
  if (diffSec < 60) return "just now";
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)} minute${Math.floor(diffSec / 60) === 1 ? "" : "s"} ago`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)} hour${Math.floor(diffSec / 3600) === 1 ? "" : "s"} ago`;
  const days = Math.floor(diffSec / 86400);
  if (days < 30) return `${days} day${days === 1 ? "" : "s"} ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months} month${months === 1 ? "" : "s"} ago`;
  return `${Math.floor(days / 365)} year${Math.floor(days / 365) === 1 ? "" : "s"} ago`;
}
