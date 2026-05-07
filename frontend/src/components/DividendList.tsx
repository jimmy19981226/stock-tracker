import { useEffect, useState } from "react";
import { api, type Dividend } from "../api";
import { type DatePreset, fmtMoney, presetRange } from "../format";
import { Pagination } from "./Pagination";

interface Props {
  dividends: Dividend[];
  names: Record<string, string>;
  onChanged: () => void;
}

export function DividendList({ dividends, names, onChanged }: Props) {
  const [tickerQuery, setTickerQuery] = useState("");
  const [preset, setPreset] = useState<DatePreset>("all");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [editingId, setEditingId] = useState<number | null>(null);
  const [draft, setDraft] = useState<Dividend | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(20);

  function applyPreset(p: DatePreset) {
    setPreset(p);
    if (p !== "custom") {
      const r = presetRange(p);
      setFrom(r.from);
      setTo(r.to);
    }
  }

  async function remove(id: number) {
    if (!confirm("Delete this dividend record?")) return;
    await api.deleteDividend(id);
    onChanged();
  }

  function startEdit(d: Dividend) {
    setEditingId(d.id);
    setDraft({ ...d });
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
      await api.updateDividend(draft.id, {
        ticker: draft.ticker,
        amount: Number(draft.amount),
        pay_date: draft.pay_date,
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

  const visible = dividends.filter((d) => {
    if (
      tickerQuery &&
      !d.ticker.toLowerCase().includes(tickerQuery.trim().toLowerCase())
    ) {
      return false;
    }
    if (from && d.pay_date < from) return false;
    if (to && d.pay_date > to) return false;
    return true;
  });

  const filtersActive =
    tickerQuery !== "" || from !== "" || to !== "";

  useEffect(() => {
    setPage(1);
  }, [tickerQuery, from, to]);

  const pageRows = visible.slice((page - 1) * pageSize, page * pageSize);

  function clearFilters() {
    setTickerQuery("");
    setPreset("all");
    setFrom("");
    setTo("");
  }

  const totals = dividends.reduce<Record<string, number>>((acc, d) => {
    acc[d.currency] = (acc[d.currency] || 0) + d.amount;
    return acc;
  }, {});

  const latest = dividends[0];

  return (
    <div className="panel">
      <h2>Dividend History ({dividends.length})</h2>
      <div className="muted" style={{ fontSize: 12, marginBottom: 4 }}>
        Most recent: <strong>{latest.pay_date}</strong> · {latest.ticker} ·
        continue from here next time.
      </div>
      <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>
        Total received:{" "}
        {Object.entries(totals)
          .map(([c, v]) => fmtMoney(v, c))
          .join("  ·  ")}
      </div>

      <div className="filter-bar">
        <input
          placeholder="Filter by ticker…"
          value={tickerQuery}
          onChange={(e) => setTickerQuery(e.target.value)}
          style={{ minWidth: 160 }}
        />
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
          Showing {visible.length} of {dividends.length}
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
          {pageRows.map((d) => {
            const isEditing = editingId === d.id;
            return (
              <tr key={d.id}>
                <td className={isEditing ? "editing" : ""}>
                  {isEditing && draft ? (
                    <input
                      type="text"
                      className="cell-input"
                      placeholder="YYYY-MM-DD"
                      pattern="\d{4}-\d{2}-\d{2}"
                      maxLength={10}
                      value={draft.pay_date}
                      onChange={(e) =>
                        setDraft({ ...draft, pay_date: e.target.value })
                      }
                    />
                  ) : (
                    d.pay_date
                  )}
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
                      <strong>{d.ticker}</strong>
                      {names[d.ticker] && (
                        <span
                          className="muted"
                          style={{ fontSize: 11, fontWeight: 500 }}
                        >
                          {names[d.ticker]}
                        </span>
                      )}
                    </div>
                  )}
                </td>
                <td className={isEditing ? "editing pos" : "pos"}>
                  {isEditing && draft ? (
                    <input
                      type="number"
                      step="any"
                      className="cell-input"
                      value={draft.amount}
                      onChange={(e) =>
                        setDraft({ ...draft, amount: Number(e.target.value) })
                      }
                    />
                  ) : (
                    fmtMoney(d.amount, d.currency)
                  )}
                </td>
                <td
                  style={{ textAlign: "left", maxWidth: 240 }}
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
                    d.notes || "—"
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
                        onClick={() => startEdit(d)}
                        style={{ padding: "4px 8px", fontSize: 12 }}
                      >
                        Edit
                      </button>{" "}
                      <button
                        className="danger"
                        onClick={() => remove(d.id)}
                      >
                        Delete
                      </button>
                    </>
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

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
    </div>
  );
}
