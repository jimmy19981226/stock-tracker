import { api, type Trade } from "../api";
import { fmtNumber, isTwTicker } from "../format";

interface Props {
  trades: Trade[];
  onDeleted: () => void;
}

export function TradeList({ trades, onDeleted }: Props) {
  async function remove(id: number) {
    if (!confirm("Delete this trade?")) return;
    await api.deleteTrade(id);
    onDeleted();
  }

  if (trades.length === 0) {
    return (
      <div className="panel">
        <h2>Trade History</h2>
        <div className="empty">No trades yet — add your first trade above.</div>
      </div>
    );
  }

  return (
    <div className="panel">
      <h2>Trade History ({trades.length})</h2>
      <table>
        <thead>
          <tr>
            <th>Date</th>
            <th>Type</th>
            <th>Ticker</th>
            <th>Shares</th>
            <th>Price</th>
            <th>Fee</th>
            <th>Total</th>
            <th>Notes</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {trades.map((t) => {
            const total = t.shares * t.price + (t.type === "buy" ? t.fee : -t.fee);
            return (
              <tr key={t.id}>
                <td>{t.trade_date}</td>
                <td>
                  <span className={`tag ${t.type}`}>{t.type.toUpperCase()}</span>
                </td>
                <td>
                  {t.ticker}{" "}
                  <span className={`tag ${isTwTicker(t.ticker) ? "tw" : "us"}`}>
                    {isTwTicker(t.ticker) ? "TW" : "US"}
                  </span>
                </td>
                <td>{fmtNumber(t.shares, 4)}</td>
                <td>{fmtNumber(t.price, 2)}</td>
                <td>{fmtNumber(t.fee, 2)}</td>
                <td>{fmtNumber(total, 2)}</td>
                <td style={{ textAlign: "left", maxWidth: 200 }} className="muted">
                  {t.notes || "—"}
                </td>
                <td>
                  <button className="danger" onClick={() => remove(t.id)}>
                    Delete
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
