import { useEffect, useState } from "react";
import { api } from "../api";

/** Resolve a ticker to its short name (e.g. "2330" → "台積電").
 * Checks the prefetched names map first (instant for tickers already in
 * the portfolio); falls back to a debounced /quote lookup for new ones.
 */
export function useTickerName(
  ticker: string,
  names: Record<string, string>,
): string {
  const cleaned = ticker.trim().toUpperCase();
  const fromMap = cleaned ? names[cleaned] : "";
  const [lookup, setLookup] = useState("");

  useEffect(() => {
    if (!cleaned || fromMap) {
      setLookup("");
      return;
    }
    let cancelled = false;
    const t = window.setTimeout(async () => {
      try {
        const q = await api.lookupQuote(cleaned);
        if (!cancelled && q.found && q.name) setLookup(q.name);
        else if (!cancelled) setLookup("");
      } catch {
        if (!cancelled) setLookup("");
      }
    }, 500);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [cleaned, fromMap]);

  return fromMap || lookup;
}
