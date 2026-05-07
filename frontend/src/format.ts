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
  return /^\d{4,6}(\.TW(O)?)?$/.test(ticker.trim().toUpperCase());
}
