import { useEffect, useState } from "react";
import { isTwMarketOpen, nextTwMarketTransition } from "../format";

export function MarketStatus() {
  const [now, setNow] = useState(new Date());

  // Tick once a minute so the badge flips at 09:00 / 13:30 automatically.
  useEffect(() => {
    const t = window.setInterval(() => setNow(new Date()), 60_000);
    return () => clearInterval(t);
  }, []);

  const open = isTwMarketOpen(now);
  const { inMinutes } = nextTwMarketTransition(now);

  const title = open
    ? `TW market open. Closes in ${formatGap(inMinutes)}.`
    : `TW market closed. Opens in ${formatGap(inMinutes)}.`;

  return (
    <span className={`market-pill ${open ? "open" : "closed"}`} title={title}>
      <span className="market-dot" />
      TW {open ? "OPEN" : "CLOSED"}
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
