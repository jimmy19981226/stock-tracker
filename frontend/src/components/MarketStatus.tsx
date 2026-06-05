import { useEffect, useState } from "react";
import type { MarketConfig } from "../api";
import { isMarketOpen, nextMarketTransition } from "../format";

/** Open/closed pill for a market, driven by its DB-sourced config (hours,
 *  timezone, holidays). Shows the active portfolio's market. */
export function MarketStatus({ market }: { market: MarketConfig | null }) {
  const [now, setNow] = useState(new Date());

  // Tick once a minute so the badge flips at the session open/close automatically.
  useEffect(() => {
    const t = window.setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(t);
  }, []);

  if (!market) return null;

  const open = isMarketOpen(market, now);
  const { inMinutes } = nextMarketTransition(market, now);

  const title = open
    ? `${market.name} market open. Closes in ${formatGap(inMinutes)}.`
    : `${market.name} market closed. Opens in ${formatGap(inMinutes)}.`;

  return (
    <span className={`market-pill ${open ? "open" : "closed"}`} title={title}>
      <span className="market-dot" />
      {market.code} {open ? "OPEN" : "CLOSED"}
    </span>
  );
}

function formatGap(mins: number): string {
  if (mins < 60) return `${Math.max(0, Math.floor(mins))}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h < 24) return m ? `${h}h ${m}m` : `${h}h`;
  const d = Math.floor(h / 24);
  return `${d}d ${h % 24}h`;
}
