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

// Compact form for chart scales: NT$8.1M, NT$505K. A chart's value gutter has
// to stay narrow or it crowds the plot on a phone — full-precision figures
// belong in the tooltip and the cards, not on an axis.
export function compactMoney(value, currency = "TWD") {
  if (value == null || Number.isNaN(value)) return "—";
  const sym = SYMBOL[currency] || "";
  const sign = value < 0 ? "−" : "";
  const n = Math.abs(value);
  const [div, suffix] =
    n >= 1e9 ? [1e9, "B"] : n >= 1e6 ? [1e6, "M"] : n >= 1e3 ? [1e3, "K"] : [1, ""];
  const scaled = n / div;
  return `${sign}${sym}${scaled.toFixed(suffix && scaled < 10 ? 1 : 0)}${suffix}`;
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
