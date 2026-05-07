import { useEffect, useRef, useState } from "react";
import { api, type Dividend, type Trade } from "../api";
import { fmtRelativeTime } from "../format";

interface Props {
  trades: Trade[];
  dividends: Dividend[];
  onImported: () => void;
}

type Status =
  | { kind: "idle" }
  | { kind: "uploading" }
  | { kind: "success"; trades: number; dividends: number }
  | { kind: "error"; message: string };

export function DataPanel({ trades, dividends, onImported }: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const [lastExport, setLastExport] = useState<string | null>(null);

  async function refreshLastExport() {
    try {
      const r = await api.getLastExport();
      setLastExport(r.last_export);
    } catch {
      /* ignore */
    }
  }

  useEffect(() => {
    refreshLastExport();
  }, []);

  function onExportClicked() {
    // The export endpoint records the timestamp server-side; refresh it
    // shortly after the download fires.
    setTimeout(refreshLastExport, 800);
  }

  async function handleFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setStatus({ kind: "uploading" });
    try {
      const { trades, dividends } = await api.importPortfolioCsv(file);
      setStatus({ kind: "success", trades, dividends });
      onImported();
    } catch (err) {
      setStatus({
        kind: "error",
        message: err instanceof Error ? err.message : "Import failed",
      });
    } finally {
      if (fileRef.current) fileRef.current.value = "";
    }
  }

  const latestTrade = trades[0];
  const latestDividend = dividends[0];

  return (
    <div className="panel">
      <h2>Import / Export</h2>
      <div
        style={{
          display: "flex",
          gap: 10,
          alignItems: "center",
          marginBottom: 16,
          flexWrap: "wrap",
        }}
      >
        <a
          href={api.exportPortfolioUrl}
          download="portfolio.csv"
          onClick={onExportClicked}
        >
          <button type="button">⤓ Export portfolio.csv</button>
        </a>
        <button
          className="secondary"
          type="button"
          onClick={() => fileRef.current?.click()}
          disabled={status.kind === "uploading"}
        >
          {status.kind === "uploading" ? "Uploading…" : "⤒ Import portfolio.csv"}
        </button>
        <input
          ref={fileRef}
          type="file"
          accept=".csv,text/csv"
          style={{ display: "none" }}
          onChange={handleFile}
        />
        {status.kind === "success" && (
          <span className="pos">
            ✓ Imported {status.trades} trades + {status.dividends} dividends
          </span>
        )}
        {status.kind === "error" && (
          <span className="neg">✗ {status.message}</span>
        )}
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))",
          gap: 12,
          marginBottom: 16,
        }}
      >
        <div className="summary-card">
          <div className="label">Trades on file</div>
          <div className="value">{trades.length}</div>
          <div className="sub muted">
            {latestTrade
              ? `Latest: ${latestTrade.trade_date} · ${latestTrade.type.toUpperCase()} ${latestTrade.ticker}`
              : "None yet"}
          </div>
        </div>
        <div className="summary-card">
          <div className="label">Dividends on file</div>
          <div className="value">{dividends.length}</div>
          <div className="sub muted">
            {latestDividend
              ? `Latest: ${latestDividend.pay_date} · ${latestDividend.ticker}`
              : "None yet"}
          </div>
        </div>
        <div className="summary-card">
          <div className="label">Last export</div>
          <div className="value" style={{ fontSize: 18 }}>
            {fmtRelativeTime(lastExport)}
          </div>
          <div className="sub muted">
            {lastExport
              ? new Date(
                  lastExport + (lastExport.endsWith("Z") ? "" : "Z"),
                ).toLocaleString()
              : "Click Export to create a backup"}
          </div>
        </div>
      </div>

      <h2 style={{ marginTop: 18 }}>CSV format</h2>
      <pre
        style={{
          background: "var(--panel-2)",
          padding: 12,
          borderRadius: 6,
          fontSize: 12,
          overflowX: "auto",
          margin: "8px 0",
        }}
      >{`kind,type,ticker,shares,price,date,fee,amount,notes
trade,buy,2330,100,950,2024-01-15,28,,initial buy
trade,sell,2330,100,1100,2024-06-01,30,,closed
dividend,,2330,,,2024-08-15,,500,Q2 cash dividend`}</pre>
      <ul className="muted" style={{ fontSize: 12, lineHeight: 1.7, paddingLeft: 18 }}>
        <li>
          <strong>kind=trade</strong>: fill <code>type</code>, <code>shares</code>,
          <code> price</code>, <code>date</code>, <code>fee</code>. Leave <code>amount</code> blank.
        </li>
        <li>
          <strong>kind=dividend</strong>: fill <code>amount</code>, <code>date</code>.
          Leave the trade-only columns blank.
        </li>
        <li>
          Dates accept <code>YYYY-MM-DD</code>, <code>YYYY/MM/DD</code>, or
          <code> MM/DD/YYYY</code>.
        </li>
        <li>
          Import always <strong>appends</strong> — to wipe data, delete from the
          Trades / Dividends tabs first.
        </li>
      </ul>

      <h2 style={{ marginTop: 18 }}>Auto-load on first boot</h2>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.6 }}>
        Drop your CSV at{" "}
        <code>backend/data/seed/portfolio.csv</code> — the backend imports it on
        startup, but only when both tables are empty. Once you have any data,
        the seed file is ignored so nothing entered through the UI ever gets
        overwritten.
      </div>
    </div>
  );
}
