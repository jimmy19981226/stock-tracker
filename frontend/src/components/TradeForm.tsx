import { useState } from "react";
import { api, type MarketCode, type TradeCreate } from "../api";
import { useTickerName } from "../hooks/useTickerName";

interface Props {
  names: Record<string, string>;
  market: MarketCode;
  onCreated: () => void;
}

const today = () => new Date().toISOString().slice(0, 10);

// TW codes are numeric (optional trailing letter); US tickers start with a
// letter. Used to auto-pick the market as the user types a ticker.
const deriveMarket = (t: string, fallback: MarketCode): MarketCode => {
  const s = t.trim();
  if (!s) return fallback;
  return /^\d/.test(s) ? "TW" : "US";
};

export function TradeForm({ names, market: activeMarket, onCreated }: Props) {
  const [type, setType] = useState<"buy" | "sell">("buy");
  const [ticker, setTicker] = useState("");
  const resolvedName = useTickerName(ticker, names);
  const [market, setMarket] = useState<MarketCode>(activeMarket);
  const [marketTouched, setMarketTouched] = useState(false);
  const [shares, setShares] = useState("");
  const [price, setPrice] = useState("");
  const [tradeDate, setTradeDate] = useState(today());
  const [fee, setFee] = useState("0");
  const [notes, setNotes] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const onTickerChange = (v: string) => {
    setTicker(v);
    if (!marketTouched) setMarket(deriveMarket(v, activeMarket));
  };

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
      market,
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
      setMarket(activeMarket);
      setMarketTouched(false);
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
          Market
          <select
            data-agent="trade-market"
            value={market}
            onChange={(e) => {
              setMarket(e.target.value as MarketCode);
              setMarketTouched(true);
            }}
          >
            <option value="TW">🇹🇼 Taiwan (NT$)</option>
            <option value="US">🇺🇸 US ($)</option>
          </select>
        </label>
        <label>
          Type
          <select data-agent="trade-type" value={type} onChange={(e) => setType(e.target.value as "buy" | "sell")}>
            <option value="buy">Buy</option>
            <option value="sell">Sell</option>
          </select>
        </label>
        <label>
          Ticker
          <input
            data-agent="trade-ticker"
            value={ticker}
            onChange={(e) => onTickerChange(e.target.value)}
            placeholder={market === "US" ? "AAPL / MSFT" : "2330 / 00919"}
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
            {resolvedName || (ticker ? "…" : " ")}
          </span>
        </label>
        <label>
          Shares
          <input
            data-agent="trade-shares"
            type="number"
            step="any"
            min="0"
            value={shares}
            onChange={(e) => setShares(e.target.value)}
            placeholder="100"
          />
        </label>
        <label>
          Price ({market === "US" ? "$" : "NT$"})
          <input
            data-agent="trade-price"
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
            data-agent="trade-date"
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
            data-agent="trade-fee"
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
            data-agent="trade-notes"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            placeholder="Anything you want to remember about this trade"
          />
        </label>
      </div>
      <div className="row-actions">
        <button data-agent="trade-submit" type="submit" disabled={submitting}>
          {submitting ? "Saving…" : "Add Trade"}
        </button>
        <span className="muted" style={{ fontSize: 12 }}>
          {market === "US"
            ? "US tickers are letters (AAPL, MSFT). Price in US$."
            : "TW: 4-digit stocks (2330), 5-digit ETFs (00919), letter suffix for bond ETFs (00937B)."}
        </span>
      </div>
      {error && <div className="error">{error}</div>}
    </form>
  );
}
