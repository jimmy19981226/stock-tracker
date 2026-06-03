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

/** Is the Taiwan stock market currently open? 09:00–13:30 Taipei time,
 *  Monday-Friday. Doesn't account for public holidays — close enough
 *  for a visual indicator. */
export function isTwMarketOpen(now: Date = new Date()): boolean {
  // Taipei is UTC+8, no DST. Compute "wall clock" time in Taipei from UTC.
  const utcMs = now.getTime();
  const taipeiMs = utcMs + 8 * 60 * 60 * 1000;
  const tw = new Date(taipeiMs);
  const day = tw.getUTCDay(); // 0=Sun, 6=Sat
  if (day === 0 || day === 6) return false;
  const minutes = tw.getUTCHours() * 60 + tw.getUTCMinutes();
  return minutes >= 9 * 60 && minutes < 13 * 60 + 30;
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
  // Currently closed — find next opening.
  const day = tw.getUTCDay();
  let daysAhead = 0;
  // If before 09:00 today and today is a weekday, opens later today.
  if (day >= 1 && day <= 5 && minsNow < 9 * 60) {
    daysAhead = 0;
  } else {
    // After 13:30 weekday, or weekend — find next weekday.
    daysAhead = 1;
    while (((day + daysAhead) % 7) === 0 || ((day + daysAhead) % 7) === 6) {
      daysAhead += 1;
    }
  }
  const minsToNextOpen =
    daysAhead * 24 * 60 + (9 * 60 - minsNow);
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
