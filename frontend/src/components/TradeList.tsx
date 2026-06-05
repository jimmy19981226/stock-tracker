import { useEffect, useState } from "react";
import { api, type Trade } from "../api";
import { type DatePreset, fmtNumber, presetRange } from "../format";
import { ConfirmModal } from "./ConfirmModal";
import { FillerRows } from "./PageFiller";
import { Pagination } from "./Pagination";

interface Props {
  trades: Trade[];
  names: Record<string, string>;
  onChanged: () => void;
}

type TypeFilter = "all" | "buy" | "sell";
type StatusFilter = "all" | "open" | "closed";

export function TradeList({ trades, names, onChanged }: Props) {
  const [tickerQuery, setTickerQuery] = useState("");
  const [typeFilter, setTypeFilter] = useState<TypeFilter>("all");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [preset, setPreset] = useState<DatePreset>("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [editingId, setEditingId] = useState<number | null>(null);
  const [draft, setDraft] = useState<Trade | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(20);
  const [pendingDelete, setPendingDelete] = useState<Trade | null>(null);

  function applyPreset(p: DatePreset) {
    setPreset(p);
    if (p !== "custom") {
      const r = presetRange(p);
      setFrom(r.from);
      setTo(r.to);
    }
  }

  function askRemove(t: Trade) {
    setPendingDelete(t);
  }

  async function confirmRemove() {
    if (!pendingDelete) return;
    const id = pendingDelete.id;
    setPendingDelete(null);
    await api.deleteTrade(id);
    onChanged();
  }

  function startEdit(t: Trade) {
    setEditingId(t.id);
    setDraft({ ...t });
    setError(null);
  }

  function cancelEdit() {
    setEditingId(null);
    setDraft(null);
    setError(null);
  }

  async function saveEdit() {
    if (!draft) return;
    setSaving(true);
    setError(null);
    try {
      await api.updateTrade(draft.id, {
        type: draft.type as "buy" | "sell",
        ticker: draft.ticker,
        shares: Number(draft.shares),
        price: Number(draft.price),
        trade_date: draft.trade_date,
        fee: Number(draft.fee),
        notes: draft.notes ?? null,
      });
      cancelEdit();
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  const visible = trades.filter((t) => {
    if (typeFilter !== "all" && t.type !== typeFilter) return false;
    if (statusFilter !== "all" && t.status !== statusFilter) return false;
    if (
      tickerQuery &&
      !t.ticker.toLowerCase().includes(tickerQuery.trim().toLowerCase())
    ) {
      return false;
    }
    if (from && t.trade_date < from) return false;
    if (to && t.trade_date > to) return false;
    return true;
  });

  const filtersActive =
    tickerQuery !== "" ||
    typeFilter !== "all" ||
    statusFilter !== "all" ||
    from !== "" ||
    to !== "";

  // Reset to first page whenever filters change the visible total.
  useEffect(() => {
    setPage(1);
  }, [tickerQuery, typeFilter, statusFilter, from, to]);

  const pageRows = visible.slice((page - 1) * pageSize, page * pageSize);

  function clearFilters() {
    setTickerQuery("");
    setTypeFilter("all");
    setStatusFilter("all");
    setPreset("all");
    setFrom("");
    setTo("");
  }

  const openCount = trades.filter((t) => t.status === "open").length;
  const closedCount = trades.length - openCount;

  if (trades.length === 0) {
    return (
      <div className="panel">
        <h2>Trade History</h2>
        <div className="empty">No trades yet — add your first trade above.</div>
      </div>
    );
  }

  const latest = trades[0];

  return (
    <div className="panel">
      <h2>Trade History ({trades.length})</h2>
      <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>
        Most recent: <strong>{latest.trade_date}</strong> ·{" "}
        {latest.type.toUpperCase()} {latest.ticker} · continue from here next
        time.
      </div>

      <div className="filter-bar">
        <input
          data-agent="trade-filter-ticker"
          placeholder="Filter by ticker…"
          value={tickerQuery}
          onChange={(e) => setTickerQuery(e.target.value)}
          style={{ minWidth: 160 }}
        />
        <select
          data-agent="trade-filter-type"
          value={typeFilter}
          onChange={(e) => setTypeFilter(e.target.value as TypeFilter)}
        >
          <option value="all">All types</option>
          <option value="buy">Buy only</option>
          <option value="sell">Sell only</option>
        </select>
        <select
          data-agent="trade-filter-status"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
        >
          <option value="all">All status</option>
          <option value="open">Open · unrealized ({openCount})</option>
          <option value="closed">Closed · realized ({closedCount})</option>
        </select>
        <select
          value={preset}
          onChange={(e) => applyPreset(e.target.value as DatePreset)}
        >
          <option value="all">All time</option>
          <option value="30d">Last 30 days</option>
          <option value="90d">Last 3 months</option>
          <option value="180d">Last 6 months</option>
          <option value="365d">Last 1 year</option>
          <option value="ytd">Year to date</option>
          <option value="custom">Custom range</option>
        </select>
        <label className="date-field">
          From
          <input
            type="text"
            placeholder="YYYY-MM-DD"
            pattern="\d{4}-\d{2}-\d{2}"
            maxLength={10}
            style={{ width: 120 }}
            value={from}
            onChange={(e) => {
              setFrom(e.target.value);
              setPreset("custom");
            }}
          />
        </label>
        <label className="date-field">
          To
          <input
            type="text"
            placeholder="YYYY-MM-DD"
            pattern="\d{4}-\d{2}-\d{2}"
            maxLength={10}
            style={{ width: 120 }}
            value={to}
            onChange={(e) => {
              setTo(e.target.value);
              setPreset("custom");
            }}
          />
        </label>
        <span className="muted" style={{ fontSize: 12 }}>
          Showing {visible.length} of {trades.length}
        </span>
        {filtersActive && (
          <button
            className="secondary"
            type="button"
            onClick={clearFilters}
            style={{ padding: "4px 10px", fontSize: 12 }}
          >
            Clear
          </button>
        )}
      </div>

      {error && <div className="error">{error}</div>}

      <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Date</th>
            <th>Type</th>
            <th>Status</th>
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
          {pageRows.map((t) => {
            const isEditing = editingId === t.id;
            const total = t.shares * t.price + (t.type === "buy" ? t.fee : -t.fee);
            return (
              <tr key={t.id}>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <input
                      type="text"
                      className="cell-input"
                      placeholder="YYYY-MM-DD"
                      pattern="\d{4}-\d{2}-\d{2}"
                      maxLength={10}
                      value={draft.trade_date}
                      onChange={(e) =>
                        setDraft({ ...draft, trade_date: e.target.value })
                      }
                    />
                  ) : (
                    t.trade_date
                  )}
                </td>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <select
                      className="cell-input"
                      value={draft.type}
                      onChange={(e) =>
                        setDraft({
                          ...draft,
                          type: e.target.value as "buy" | "sell",
                        })
                      }
                    >
                      <option value="buy">buy</option>
                      <option value="sell">sell</option>
                    </select>
                  ) : (
                    <span className={`tag ${t.type}`}>
                      {t.type.toUpperCase()}
                    </span>
                  )}
                </td>
                <td>
                  <span className={`tag status-${t.status}`}>
                    {t.status === "open" ? "OPEN" : "CLOSED"}
                  </span>
                </td>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <input
                      className="cell-input"
                      value={draft.ticker}
                      onChange={(e) =>
                        setDraft({
                          ...draft,
                          ticker: e.target.value.toUpperCase(),
                        })
                      }
                    />
                  ) : (
                    <div style={{ display: "flex", flexDirection: "column" }}>
                      <strong>{t.ticker}</strong>
                      {names[t.ticker] && (
                        <span
                          className="muted"
                          style={{ fontSize: 11, fontWeight: 500 }}
                        >
                          {names[t.ticker]}
                        </span>
                      )}
                    </div>
                  )}
                </td>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <input
                      type="number"
                      step="any"
                      className="cell-input"
                      value={draft.shares}
                      onChange={(e) =>
                        setDraft({ ...draft, shares: Number(e.target.value) })
                      }
                    />
                  ) : (
                    fmtNumber(t.shares, 4)
                  )}
                </td>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <input
                      type="number"
                      step="any"
                      className="cell-input"
                      value={draft.price}
                      onChange={(e) =>
                        setDraft({ ...draft, price: Number(e.target.value) })
                      }
                    />
                  ) : (
                    fmtNumber(t.price, 2)
                  )}
                </td>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <input
                      type="number"
                      step="any"
                      className="cell-input"
                      value={draft.fee}
                      onChange={(e) =>
                        setDraft({ ...draft, fee: Number(e.target.value) })
                      }
                    />
                  ) : (
                    fmtNumber(t.fee, 2)
                  )}
                </td>
                <td>{isEditing ? "—" : fmtNumber(total, 2)}</td>
                <td
                  style={{
                    textAlign: "left",
                    maxWidth: 200,
                    whiteSpace: isEditing ? "normal" : "nowrap",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                  }}
                  className={isEditing ? "editing muted" : "muted"}
                >
                  {isEditing && draft ? (
                    <input
                      className="cell-input"
                      value={draft.notes || ""}
                      onChange={(e) =>
                        setDraft({ ...draft, notes: e.target.value })
                      }
                    />
                  ) : (
                    t.notes || "—"
                  )}
                </td>
                <td style={{ whiteSpace: "nowrap" }}>
                  {isEditing ? (
                    <>
                      <button
                        type="button"
                        onClick={saveEdit}
                        disabled={saving}
                        style={{ padding: "4px 10px", fontSize: 12 }}
                      >
                        {saving ? "…" : "Save"}
                      </button>{" "}
                      <button
                        type="button"
                        className="secondary"
                        onClick={cancelEdit}
                        disabled={saving}
                        style={{ padding: "4px 10px", fontSize: 12 }}
                      >
                        Cancel
                      </button>
                    </>
                  ) : (
                    <>
                      <button
                        type="button"
                        className="secondary"
                        onClick={() => startEdit(t)}
                        style={{ padding: "4px 8px", fontSize: 12 }}
                      >
                        Edit
                      </button>{" "}
                      <button
                        className="danger"
                        onClick={() => askRemove(t)}
                      >
                        Delete
                      </button>
                    </>
                  )}
                </td>
              </tr>
            );
          })}
          <FillerRows
            count={visible.length > pageSize ? pageSize - pageRows.length : 0}
            cols={10}
          />
        </tbody>
      </table>
      </div>

      <Pagination
        page={page}
        pageSize={pageSize}
        total={visible.length}
        onPageChange={setPage}
        onPageSizeChange={(s) => {
          setPageSize(s);
          setPage(1);
        }}
      />

      <ConfirmModal
        open={pendingDelete !== null}
        title="Delete this trade?"
        message={
          pendingDelete && (
            <>
              <strong>
                {pendingDelete.type.toUpperCase()} {pendingDelete.shares} ×{" "}
                {pendingDelete.ticker} @ NT$
                {pendingDelete.price.toFixed(2)}
              </strong>
              {" — "}
              {pendingDelete.trade_date}. This can't be undone.
            </>
          )
        }
        confirmLabel="Delete"
        danger
        onConfirm={confirmRemove}
        onCancel={() => setPendingDelete(null)}
      />
    </div>
  );
}
