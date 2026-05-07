import type { CurrencySummary } from "../api";
import { fmtMoney, fmtPct, plClass } from "../format";

interface Props {
  summaries: CurrencySummary[];
}

export function PortfolioSummary({ summaries }: Props) {
  if (summaries.length === 0) {
    return (
      <div className="panel">
        <h2>Portfolio Summary</h2>
        <div className="empty">Add a trade to see your portfolio summary.</div>
      </div>
    );
  }

  return (
    <>
      {summaries.map((s) => (
        <div className="panel" key={s.currency}>
          <h2>
            {s.currency} Portfolio · {s.holdings_count}{" "}
            {s.holdings_count === 1 ? "holding" : "holdings"}
          </h2>
          <div className="summary-grid">
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
            <div className="summary-card" style={{ outline: "1px solid var(--accent)" }}>
              <div className="label">Total Earned</div>
              <div className={`value ${plClass(s.total_earned)}`}>
                {fmtMoney(s.total_earned, s.currency)}
              </div>
              <div className="sub muted">Realized + dividends</div>
            </div>
          </div>
        </div>
      ))}
    </>
  );
}
