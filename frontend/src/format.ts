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
  const toStr = today.toISOString().slice(0, 10);
  const subtract = (days: number) => {
    const d = new Date(today);
    d.setDate(d.getDate() - days);
    return d.toISOString().slice(0, 10);
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
