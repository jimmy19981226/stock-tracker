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

// 2026 TWSE market-holiday closures (mirror of backend tw_calendar.py).
// Update yearly. Weekends are handled separately.
const TW_MARKET_HOLIDAYS = new Set<string>([
  "2026-01-01",
  "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20",
  "2026-02-27",
  "2026-04-03", "2026-04-06",
  "2026-05-01",
  "2026-06-19",
  "2026-09-25", "2026-09-28",
  "2026-10-09", "2026-10-26",
  "2026-12-25",
]);

/** ISO date string for a Date whose UTC fields hold Taipei wall-clock time. */
function twDateStr(tw: Date): string {
  const m = String(tw.getUTCMonth() + 1).padStart(2, "0");
  const d = String(tw.getUTCDate()).padStart(2, "0");
  return `${tw.getUTCFullYear()}-${m}-${d}`;
}

function isTwHoliday(tw: Date): boolean {
  return TW_MARKET_HOLIDAYS.has(twDateStr(tw));
}

/** Is the Taiwan stock market currently open? 09:00–13:30 Taipei time,
 *  Monday-Friday, excluding TW public holidays. */
export function isTwMarketOpen(now: Date = new Date()): boolean {
  // Taipei is UTC+8, no DST. Compute "wall clock" time in Taipei from UTC.
  const utcMs = now.getTime();
  const taipeiMs = utcMs + 8 * 60 * 60 * 1000;
  const tw = new Date(taipeiMs);
  const day = tw.getUTCDay(); // 0=Sun, 6=Sat
  if (day === 0 || day === 6) return false;
  if (isTwHoliday(tw)) return false;
  const minutes = tw.getUTCHours() * 60 + tw.getUTCMinutes();
  return minutes >= 9 * 60 && minutes < 13 * 60 + 30;
}

// 2026 US (NYSE/Nasdaq) full-day market-holiday closures. Update yearly.
// Half-days (e.g. the day after Thanksgiving) are treated as open — close
// enough for deciding the refresh cadence.
const US_MARKET_HOLIDAYS = new Set<string>([
  "2026-01-01", // New Year's Day
  "2026-01-19", // Martin Luther King Jr. Day
  "2026-02-16", // Presidents' Day
  "2026-04-03", // Good Friday
  "2026-05-25", // Memorial Day
  "2026-06-19", // Juneteenth
  "2026-07-03", // Independence Day (observed)
  "2026-09-07", // Labor Day
  "2026-11-26", // Thanksgiving
  "2026-12-25", // Christmas
]);

/** Is the US stock market currently open? 09:30–16:00 US Eastern, Monday-Friday,
 *  excluding US market holidays. Uses Intl with the America/New_York zone so
 *  EST/EDT (daylight saving) is handled automatically. */
export function isUsMarketOpen(now: Date = new Date()): boolean {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  const wd = get("weekday");
  if (wd === "Sat" || wd === "Sun") return false;
  const date = `${get("year")}-${get("month")}-${get("day")}`;
  if (US_MARKET_HOLIDAYS.has(date)) return false;
  let hour = parseInt(get("hour"), 10);
  if (hour === 24) hour = 0; // some engines render midnight as "24"
  const minutes = hour * 60 + parseInt(get("minute"), 10);
  return minutes >= 9 * 60 + 30 && minutes < 16 * 60;
}

/** Minutes until TW market open or close, whichever applies. */
export function nextTwMarketTransition(now: Date = new Date()): {
  open: boolean;
  inMinutes: number;
} {
  const open = isTwMarketOpen(now);
  const utcMs = now.getTime();
  const taipeiMs = utcMs + 8 * 60 * 60 * 1000;
  const tw = new Date(taipeiMs);
  const minsNow = tw.getUTCHours() * 60 + tw.getUTCMinutes();

  if (open) {
    return { open: true, inMinutes: 13 * 60 + 30 - minsNow };
  }
  // Currently closed — find the next day the market opens, skipping
  // weekends and TW public holidays.
  let daysAhead = minsNow < 9 * 60 ? 0 : 1;
  for (;;) {
    const cand = new Date(taipeiMs + daysAhead * 24 * 60 * 60 * 1000);
    const cd = cand.getUTCDay();
    if (cd !== 0 && cd !== 6 && !isTwHoliday(cand)) break;
    daysAhead += 1;
  }
  const minsToNextOpen = daysAhead * 24 * 60 + (9 * 60 - minsNow);
  return { open: false, inMinutes: minsToNextOpen };
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
