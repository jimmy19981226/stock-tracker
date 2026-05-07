import { useState } from "react";
import { api, type DividendCreate } from "../api";
import { useTickerName } from "../hooks/useTickerName";

interface Props {
  names: Record<string, string>;
  onCreated: () => void;
}

const today = () => new Date().toISOString().slice(0, 10);

export function DividendForm({ names, onCreated }: Props) {
  const [ticker, setTicker] = useState("");
  const resolvedName = useTickerName(ticker, names);
  const [amount, setAmount] = useState("");
  const [payDate, setPayDate] = useState(today());
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const payload: DividendCreate = {
      ticker: ticker.trim().toUpperCase(),
      amount: Number(amount),
      pay_date: payDate,
      notes: notes.trim() || null,
    };
    if (!payload.ticker) return setError("Ticker is required.");
    if (!(payload.amount > 0))
      return setError("Amount must be greater than 0.");

    setSubmitting(true);
    try {
      await api.createDividend(payload);
      setTicker("");
      setAmount("");
      setNotes("");
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to save dividend");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form className="panel" onSubmit={submit}>
      <h2>Record Dividend</h2>
      <div className="form-grid">
        <label>
          Ticker
          <input
            value={ticker}
            onChange={(e) => setTicker(e.target.value)}
            placeholder="2330 / 00919"
            autoCapitalize="characters"
          />
          <span
            className="muted"
            style={{
              fontSize: 11,
              fontWeight: 500,
              marginTop: 2,
              minHeight: 14,
              textTransform: "none",
              letterSpacing: "normal",
            }}
          >
            {resolvedName || (ticker ? "…" : " ")}
          </span>
        </label>
        <label>
          Amount Received
          <input
            type="number"
            step="any"
            min="0"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="Total cash received"
          />
        </label>
        <label>
          Pay Date
          <input
            type="text"
            placeholder="YYYY-MM-DD"
            pattern="\d{4}-\d{2}-\d{2}"
            maxLength={10}
            value={payDate}
            onChange={(e) => setPayDate(e.target.value)}
          />
        </label>
        <label style={{ gridColumn: "1 / -1" }}>
          Notes (optional)
          <input
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="e.g. 2024 Q3 cash dividend"
          />
        </label>
      </div>
      <div className="row-actions">
        <button type="submit" disabled={submitting}>
          {submitting ? "Saving…" : "Add Dividend"}
        </button>
        <span className="muted" style={{ fontSize: 12 }}>
          Amounts are recorded in TWD.
        </span>
      </div>
      {error && <div className="error">{error}</div>}
    </form>
  );
}
