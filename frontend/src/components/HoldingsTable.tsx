import { useState } from "react";
import type { Holding } from "../api";
import { fmtMoney, fmtNumber, fmtPct, plClass } from "../format";
import { Pagination } from "./Pagination";

interface Props {
  holdings: Holding[];
}

export function HoldingsTable({ holdings }: Props) {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(10);

  // Drop anything without a real ticker so a transient render mid-poll
  // can't paint blank rows.
  const valid = holdings.filter((h): h is Holding => !!(h && h.ticker));

  if (valid.length === 0) {
    return (
      <div className="panel">
        <h2>Holdings</h2>
        <div className="empty">No open positions.</div>
      </div>
    );
  }

  const byCurrency = valid.reduce<Record<string, Holding[]>>((acc, h) => {
    (acc[h.currency] ||= []).push(h);
    return acc;
  }, {});

  return (
    <div className="panel">
      <h2>
        Open Positions{" "}
        <span
          className="tag status-open"
          style={{ marginLeft: 8, verticalAlign: "middle" }}
        >
          {holdings.length} OPEN
        </span>
      </h2>
      {Object.entries(byCurrency).map(([currency, rawItems]) => {
        const items = [...rawItems].sort((a, b) =>
          a.ticker.localeCompare(b.ticker, undefined, { numeric: true }),
        );
        const pageItems = items.slice((page - 1) * pageSize, page * pageSize);
        return (
        <div key={currency} style={{ marginBottom: 16 }}>
          <div
            className="muted"
            style={{
              fontSize: 11,
              marginBottom: 8,
              fontWeight: 700,
              textTransform: "uppercase",
              letterSpacing: "0.1em",
            }}
          >
            {currency} · {items.length}
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
              {pageItems.map((h) => (
                <tr key={h.ticker}>
                  <td>
                    <div style={{ display: "flex", flexDirection: "column" }}>
                      <strong>{h.ticker}</strong>
                      {h.name && (
                        <span
                          className="muted"
                          style={{ fontSize: 11, fontWeight: 500 }}
                        >
                          {h.name}
                        </span>
                      )}
                    </div>
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
          <Pagination
            page={page}
            pageSize={pageSize}
            total={items.length}
            onPageChange={setPage}
            onPageSizeChange={(s) => {
              setPageSize(s);
              setPage(1);
            }}
          />
        </div>
        );
      })}
    </div>
  );
}
