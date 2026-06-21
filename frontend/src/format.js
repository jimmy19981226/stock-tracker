// Money / number formatting shared across the dashboard.

const SYMBOL = { TWD: "NT$", USD: "US$" };

export function money(value, currency = "TWD", digits = 0) {
  if (value == null || Number.isNaN(value)) return "—";
  const sym = SYMBOL[currency] || "";
  const n = Number(value).toLocaleString("en-US", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
  return `${sym}${n}`;
}

export function signedMoney(value, currency = "TWD", digits = 0) {
  if (value == null || Number.isNaN(value)) return "—";
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}${money(Math.abs(value), currency, digits)}`;
}

export function pct(value, digits = 2) {
  if (value == null || Number.isNaN(value)) return "—";
  const sign = value > 0 ? "+" : value < 0 ? "−" : "";
  return `${sign}${Math.abs(value).toFixed(digits)}%`;
}

export function shares(value) {
  if (value == null) return "—";
  return Number(value).toLocaleString("en-US", { maximumFractionDigits: 4 });
}

// Color class for a P/L value (green up / red down / muted flat).
export function plClass(value) {
  if (value == null || value === 0) return "muted";
  return value > 0 ? "up" : "down";
}

export function prettyDate(iso) {
  if (!iso) return "—";
  const d = new Date(iso.slice(0, 10) + "T00:00:00Z");
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}
