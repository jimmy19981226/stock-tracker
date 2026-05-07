import { api, type Dividend } from "../api";
import { fmtMoney, isTwTicker } from "../format";

interface Props {
  dividends: Dividend[];
  onDeleted: () => void;
}

export function DividendList({ dividends, onDeleted }: Props) {
  async function remove(id: number) {
    if (!confirm("Delete this dividend record?")) return;
    await api.deleteDividend(id);
    onDeleted();
  }

  if (dividends.length === 0) {
    return (
      <div className="panel">
        <h2>Dividend History</h2>
        <div className="empty">
          No dividends recorded yet — add your first payout above.
        </div>
      </div>
    );
  }

  const totals = dividends.reduce<Record<string, number>>((acc, d) => {
    acc[d.currency] = (acc[d.currency] || 0) + d.amount;
    return acc;
  }, {});

  return (
    <div className="panel">
      <h2>Dividend History ({dividends.length})</h2>
      <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>
        Total received:{" "}
        {Object.entries(totals)
          .map(([c, v]) => fmtMoney(v, c))
          .join("  ·  ")}
      </div>
      <table>
        <thead>
          <tr>
            <th>Pay Date</th>
            <th>Ticker</th>
            <th>Amount</th>
            <th>Notes</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {dividends.map((d) => (
            <tr key={d.id}>
              <td>{d.pay_date}</td>
              <td>
                {d.ticker}{" "}
                <span className={`tag ${isTwTicker(d.ticker) ? "tw" : "us"}`}>
                  {isTwTicker(d.ticker) ? "TW" : "US"}
                </span>
              </td>
              <td className="pos">{fmtMoney(d.amount, d.currency)}</td>
              <td style={{ textAlign: "left", maxWidth: 240 }} className="muted">
                {d.notes || "—"}
              </td>
              <td>
                <button className="danger" onClick={() => remove(d.id)}>
                  Delete
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
