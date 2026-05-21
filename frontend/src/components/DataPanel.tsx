import { useEffect, useRef, useState } from "react";
import { api, type Dividend, type Trade } from "../api";
import { fmtRelativeTime } from "../format";
import { ConfirmModal } from "./ConfirmModal";

interface Props {
  trades: Trade[];
  dividends: Dividend[];
  onImported: () => void;
}

type Status =
  | { kind: "idle" }
  | { kind: "uploading"; mode: "append" | "replace" }
  | {
      kind: "success";
      mode: "append" | "replace";
      trades: number;
      dividends: number;
      deletedTrades: number;
      deletedDividends: number;
    }
  | { kind: "error"; message: string };

export function DataPanel({ trades, dividends, onImported }: Props) {
  const appendRef = useRef<HTMLInputElement>(null);
  const replaceRef = useRef<HTMLInputElement>(null);
  const [status, setStatus] = useState<Status>({ kind: "idle" });
  const [lastExport, setLastExport] = useState<string | null>(null);
  const [pendingReplace, setPendingReplace] = useState<File | null>(null);

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
    setTimeout(refreshLastExport, 800);
  }

  async function runImport(file: File, mode: "append" | "replace") {
    setStatus({ kind: "uploading", mode });
    try {
      const r = await api.importPortfolioXlsx(file, mode);
      setStatus({
        kind: "success",
        mode,
        trades: r.trades,
        dividends: r.dividends,
        deletedTrades: r.deleted_trades,
        deletedDividends: r.deleted_dividends,
      });
      onImported();
    } catch (err) {
      setStatus({
        kind: "error",
        message: err instanceof Error ? err.message : "Import failed",
      });
    } finally {
      if (appendRef.current) appendRef.current.value = "";
      if (replaceRef.current) replaceRef.current.value = "";
    }
  }

  async function handleAppend(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    await runImport(file, "append");
  }

  function handleReplace(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setPendingReplace(file);
  }

  async function confirmReplace() {
    const file = pendingReplace;
    setPendingReplace(null);
    if (!file) return;
    await runImport(file, "replace");
  }

  function cancelReplace() {
    setPendingReplace(null);
    if (replaceRef.current) replaceRef.current.value = "";
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
          download="portfolio.xlsx"
          onClick={onExportClicked}
        >
          <button type="button">⤓ Export portfolio.xlsx</button>
        </a>
        <button
          className="secondary"
          type="button"
          onClick={() => appendRef.current?.click()}
          disabled={status.kind === "uploading"}
          title="Append rows from an Excel workbook to existing data"
        >
          {status.kind === "uploading" && status.mode === "append"
            ? "Uploading…"
            : "⤒ Import (append)"}
        </button>
        <button
          className="secondary"
          type="button"
          onClick={() => replaceRef.current?.click()}
          disabled={status.kind === "uploading"}
          title="Wipe existing data and replace with the Excel workbook — destructive"
          style={{
            color: "var(--red)",
            boxShadow:
              "0 1px 0 rgba(255,255,255,0.04) inset, 0 0 0 1px rgba(248,113,113,0.3)",
          }}
        >
          {status.kind === "uploading" && status.mode === "replace"
            ? "Replacing…"
            : "↻ Import (replace all)"}
        </button>
        <input
          ref={appendRef}
          type="file"
          accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          style={{ display: "none" }}
          onChange={handleAppend}
        />
        <input
          ref={replaceRef}
          type="file"
          accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          style={{ display: "none" }}
          onChange={handleReplace}
        />
        {status.kind === "success" && status.mode === "append" && (
          <span className="pos">
            ✓ Appended {status.trades} trades + {status.dividends} dividends
          </span>
        )}
        {status.kind === "success" && status.mode === "replace" && (
          <span className="pos">
            ✓ Replaced — wiped {status.deletedTrades} trades +{" "}
            {status.deletedDividends} dividends, imported {status.trades} +{" "}
            {status.dividends}
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

      <h2 style={{ marginTop: 18 }}>Excel format</h2>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.7 }}>
        The workbook has two sheets — everything the app displays (P/L,
        holdings, charts) is recomputed from these on import:
      </div>
      <ul className="muted" style={{ fontSize: 12, lineHeight: 1.7, paddingLeft: 18 }}>
        <li>
          <strong>Trades</strong> sheet — columns <code>type</code>,{" "}
          <code>ticker</code>, <code>shares</code>, <code>price</code>,{" "}
          <code>date</code>, <code>fee</code>, <code>notes</code>.{" "}
          <code>type</code> is <code>buy</code> or <code>sell</code>.
        </li>
        <li>
          <strong>Dividends</strong> sheet — columns <code>ticker</code>,{" "}
          <code>amount</code>, <code>date</code>, <code>notes</code>.
        </li>
        <li>
          Dates accept a real Excel date cell, or text{" "}
          <code>YYYY-MM-DD</code>, <code>YYYY/MM/DD</code>, or{" "}
          <code>MM/DD/YYYY</code>.
        </li>
        <li>
          Export once to get a correctly-shaped workbook, then edit it in
          Excel and re-import.
        </li>
      </ul>

      <h2 style={{ marginTop: 18 }}>Auto-load on first boot</h2>
      <div className="muted" style={{ fontSize: 13, lineHeight: 1.6 }}>
        Drop your workbook at{" "}
        <code>backend/data/seed/portfolio.xlsx</code> — the backend imports it
        on startup, but only when both tables are empty. Once you have any
        data, the seed file is ignored so nothing entered through the UI ever
        gets overwritten.
      </div>

      <ConfirmModal
        open={pendingReplace !== null}
        title="Replace all data?"
        message={
          <>
            This will <strong>delete</strong> your{" "}
            <strong>{trades.length} trades</strong> and{" "}
            <strong>{dividends.length} dividends</strong>, then import{" "}
            <code>{pendingReplace?.name}</code> in their place. This can't be
            undone — make sure the workbook is what you want.
          </>
        }
        confirmLabel="Replace all"
        cancelLabel="Cancel"
        danger
        onConfirm={confirmReplace}
        onCancel={cancelReplace}
      />
    </div>
  );
}
