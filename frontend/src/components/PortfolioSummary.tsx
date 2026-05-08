import { useRef } from "react";
import type { CurrencySummary } from "../api";
import { fmtMoney, fmtPct, plClass } from "../format";

interface Props {
  summaries: CurrencySummary[];
}

const STICKY_FIELDS = [
  "total_value",
  "total_pl",
  "total_pl_pct",
  "today_pl",
  "today_pl_pct",
] as const;

type StickyField = (typeof STICKY_FIELDS)[number];

export function PortfolioSummary({ summaries }: Props) {
  // When a poll briefly returns null for live-data fields (transient MIS
  // quote failure), keep showing the previous known value instead of "—".
  // Each currency tracks its own last-known-good values.
  const lastGood = useRef<Record<string, Partial<Record<StickyField, number>>>>({});

  const merged = summaries.map((s) => {
    const prev = lastGood.current[s.currency] ?? {};
    const next: Partial<Record<StickyField, number>> = { ...prev };
    const out: CurrencySummary = { ...s };
    for (const f of STICKY_FIELDS) {
      if (s[f] !== null && s[f] !== undefined) {
        next[f] = s[f] as number;
      } else if (prev[f] !== undefined) {
        out[f] = prev[f]!;
      }
    }
    lastGood.current[s.currency] = next;
    return out;
  });

  if (merged.length === 0) {
    return (
      <div className="panel">
        <h2>Portfolio Summary</h2>
        <div className="empty">Add a trade to see your portfolio summary.</div>
      </div>
    );
  }

  return (
    <>
      {merged.map((s) => (
        <div className="panel" key={s.currency}>
          <h2>
            {s.currency} Portfolio · {s.holdings_count}{" "}
            {s.holdings_count === 1 ? "holding" : "holdings"}
          </h2>
          <div className="summary-grid">
            <div className="summary-card hero">
              <div className="label">Total Earned</div>
              <div className="value">
                {fmtMoney(s.total_earned, s.currency)}
              </div>
              <div className="sub muted">
                Realized {fmtMoney(s.realized_pl, s.currency)} ·
                Dividends {fmtMoney(s.dividends, s.currency)}
              </div>
            </div>
            <div className="summary-card">
              <div className="label">Market Value</div>
              <div className="value">{fmtMoney(s.total_value, s.currency)}</div>
              <div className="sub muted">
                Cost: {fmtMoney(s.total_cost, s.currency)}
              </div>
            </div>
            <div className="summary-card">
              <div className="label">Unrealized P/L</div>
              <div className={`value ${plClass(s.total_pl)}`}>
                {fmtMoney(s.total_pl, s.currency)}
              </div>
              <div className={`sub ${plClass(s.total_pl_pct)}`}>
                {fmtPct(s.total_pl_pct)}
              </div>
            </div>
            <div className="summary-card">
              <div className="label">Today</div>
              <div className={`value ${plClass(s.today_pl)}`}>
                {fmtMoney(s.today_pl, s.currency)}
              </div>
              <div className={`sub ${plClass(s.today_pl_pct)}`}>
                {fmtPct(s.today_pl_pct)}
              </div>
            </div>
            <div className="summary-card">
              <div className="label">Realized P/L</div>
              <div className={`value ${plClass(s.realized_pl)}`}>
                {fmtMoney(s.realized_pl, s.currency)}
              </div>
              <div className="sub muted">From closed positions</div>
            </div>
            <div className="summary-card">
              <div className="label">Dividends</div>
              <div className={`value ${plClass(s.dividends)}`}>
                {fmtMoney(s.dividends, s.currency)}
              </div>
              <div className="sub muted">Cash payouts received</div>
            </div>
          </div>
        </div>
      ))}
    </>
  );
}
