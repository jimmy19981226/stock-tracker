import type { Holding } from "../api";
import { fmtMoney, fmtNumber, fmtPct, plClass } from "../format";

interface Props {
  holdings: Holding[];
}

export function HoldingsTable({ holdings }: Props) {
  if (holdings.length === 0) {
    return (
      <div className="panel">
        <h2>Holdings</h2>
        <div className="empty">No open positions.</div>
      </div>
    );
  }

  const byCurrency = holdings.reduce<Record<string, Holding[]>>((acc, h) => {
    (acc[h.currency] ||= []).push(h);
    return acc;
  }, {});

  return (
    <div className="panel">
      <h2>Holdings</h2>
      {Object.entries(byCurrency).map(([currency, items]) => (
        <div key={currency} style={{ marginBottom: 16 }}>
          <div
            className="muted"
            style={{ fontSize: 12, marginBottom: 6, fontWeight: 600 }}
          >
            {currency}
          </div>
          <table>
            <thead>
              <tr>
                <th>Ticker</th>
                <th>Shares</th>
                <th>Avg Cost</th>
                <th>Price</th>
                <th>Today</th>
                <th>Market Value</th>
                <th>Unrealized P/L</th>
                <th>Return</th>
              </tr>
            </thead>
            <tbody>
              {items.map((h) => (
                <tr key={h.ticker}>
                  <td>
                    <strong>{h.ticker}</strong>
                  </td>
                  <td>{fmtNumber(h.shares, 4)}</td>
                  <td>{fmtMoney(h.avg_cost, currency)}</td>
                  <td>{fmtMoney(h.current_price, currency)}</td>
                  <td className={plClass(h.today_change_pct)}>
                    {fmtPct(h.today_change_pct)}
                  </td>
                  <td>{fmtMoney(h.market_value, currency)}</td>
                  <td className={plClass(h.unrealized_pl)}>
                    {fmtMoney(h.unrealized_pl, currency)}
                  </td>
                  <td className={plClass(h.unrealized_pl_pct)}>
                    {fmtPct(h.unrealized_pl_pct)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </div>
  );
}
