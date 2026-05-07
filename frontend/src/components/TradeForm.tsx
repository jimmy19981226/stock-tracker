import { useState } from "react";
import { api, type TradeCreate } from "../api";

interface Props {
  onCreated: () => void;
}

const today = () => new Date().toISOString().slice(0, 10);

export function TradeForm({ onCreated }: Props) {
  const [type, setType] = useState<"buy" | "sell">("buy");
  const [ticker, setTicker] = useState("");
  const [shares, setShares] = useState("");
  const [price, setPrice] = useState("");
  const [tradeDate, setTradeDate] = useState(today());
  const [fee, setFee] = useState("0");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const payload: TradeCreate = {
      type,
      ticker: ticker.trim().toUpperCase(),
      shares: Number(shares),
      price: Number(price),
      trade_date: tradeDate,
      fee: Number(fee || "0"),
      notes: notes.trim() || null,
    };
    if (!payload.ticker) return setError("Ticker is required.");
    if (!(payload.shares > 0)) return setError("Shares must be greater than 0.");
    if (!(payload.price > 0)) return setError("Price must be greater than 0.");

    setSubmitting(true);
    try {
      await api.createTrade(payload);
      setTicker("");
      setShares("");
      setPrice("");
      setFee("0");
      setNotes("");
      onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to save trade");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form className="panel" onSubmit={submit}>
      <h2>Record Trade</h2>
      <div className="form-grid">
        <label>
          Type
          <select value={type} onChange={(e) => setType(e.target.value as "buy" | "sell")}>
            <option value="buy">Buy</option>
            <option value="sell">Sell</option>
          </select>
        </label>
        <label>
          Ticker
          <input
            value={ticker}
            onChange={(e) => setTicker(e.target.value)}
            placeholder="2330 / AAPL"
            autoCapitalize="characters"
          />
        </label>
        <label>
          Shares
          <input
            type="number"
            step="any"
            min="0"
            value={shares}
            onChange={(e) => setShares(e.target.value)}
            placeholder="100"
          />
        </label>
        <label>
          Price
          <input
            type="number"
            step="any"
            min="0"
            value={price}
            onChange={(e) => setPrice(e.target.value)}
            placeholder="0.00"
          />
        </label>
        <label>
          Date
          <input
            type="text"
            placeholder="YYYY-MM-DD"
            pattern="\d{4}-\d{2}-\d{2}"
            maxLength={10}
            value={tradeDate}
            onChange={(e) => setTradeDate(e.target.value)}
          />
        </label>
        <label>
          Fee
          <input
            type="number"
            step="any"
            min="0"
            value={fee}
            onChange={(e) => setFee(e.target.value)}
          />
        </label>
        <label style={{ gridColumn: "1 / -1" }}>
          Notes (optional)
          <input
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Anything you want to remember about this trade"
          />
        </label>
      </div>
      <div className="row-actions">
        <button type="submit" disabled={submitting}>
          {submitting ? "Saving…" : "Add Trade"}
        </button>
        <span className="muted" style={{ fontSize: 12 }}>
          Tip: use 4-digit tickers (e.g. 2330) for Taiwan, symbols (e.g. AAPL) for US.
        </span>
      </div>
      {error && <div className="error">{error}</div>}
    </form>
  );
}
