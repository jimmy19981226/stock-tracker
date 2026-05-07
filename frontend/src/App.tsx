import { useCallback, useEffect, useState } from "react";
import {
  api,
  type CurrencySummary,
  type Dividend,
  type HistoryByCurrency,
  type Holding,
  type Trade,
} from "./api";
import { AllocationChart } from "./components/AllocationChart";
import { DataPanel } from "./components/DataPanel";
import { DividendForm } from "./components/DividendForm";
import { DividendList } from "./components/DividendList";
import { HoldingsTable } from "./components/HoldingsTable";
import { PerformanceChart } from "./components/PerformanceChart";
import { PortfolioSummary } from "./components/PortfolioSummary";
import { TradeForm } from "./components/TradeForm";
import { TradeList } from "./components/TradeList";

type View = "dashboard" | "trades" | "dividends" | "data";

export default function App() {
  const [view, setView] = useState<View>("dashboard");
  const [trades, setTrades] = useState<Trade[]>([]);
  const [dividends, setDividends] = useState<Dividend[]>([]);
  const [holdings, setHoldings] = useState<Holding[]>([]);
  const [summaries, setSummaries] = useState<CurrencySummary[]>([]);
  const [history, setHistory] = useState<HistoryByCurrency>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const [t, d, h, s, hist] = await Promise.all([
        api.listTrades(),
        api.listDividends(),
        api.getHoldings(),
        api.getSummary(),
        api.getRealizedHistory(1825),
      ]);
      setTrades(t);
      setDividends(d);
      setHoldings(h);
      setSummaries(s);
      setHistory(hist);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load data");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return (
    <div className="app">
      <header className="app-header">
        <h1>📈 Stock Tracker</h1>
        <nav>
          <button
            className={view === "dashboard" ? "active" : ""}
            onClick={() => setView("dashboard")}
          >
            Dashboard
          </button>
          <button
            className={view === "trades" ? "active" : ""}
            onClick={() => setView("trades")}
          >
            Trades
          </button>
          <button
            className={view === "dividends" ? "active" : ""}
            onClick={() => setView("dividends")}
          >
            Dividends
          </button>
          <button
            className={view === "data" ? "active" : ""}
            onClick={() => setView("data")}
          >
            Data
          </button>
          <button className="secondary" onClick={refresh} title="Refresh prices">
            ↻
          </button>
        </nav>
      </header>

      {error && <div className="error">{error}</div>}
      {loading && <div className="muted">Loading…</div>}

      {view === "dashboard" && !loading && (
        <>
          <PortfolioSummary summaries={summaries} />
          <PerformanceChart history={history} />
          <div className="dual-grid">
            <HoldingsTable holdings={holdings} />
            <AllocationChart holdings={holdings} />
          </div>
        </>
      )}

      {view === "trades" && !loading && (
        <>
          <TradeForm onCreated={refresh} />
          <TradeList trades={trades} onChanged={refresh} />
        </>
      )}

      {view === "dividends" && !loading && (
        <>
          <DividendForm onCreated={refresh} />
          <DividendList dividends={dividends} onChanged={refresh} />
        </>
      )}

      {view === "data" && !loading && (
        <DataPanel
          trades={trades}
          dividends={dividends}
          onImported={refresh}
        />
      )}
    </div>
  );
}
