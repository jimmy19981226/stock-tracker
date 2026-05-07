import { useCallback, useEffect, useState } from "react";
import {
  api,
  type CurrencySummary,
  type Dividend,
  type EarningsByCurrency,
  type Holding,
  type Trade,
} from "./api";
import { AllocationChart } from "./components/AllocationChart";
import { AssistantPanel } from "./components/AssistantPanel";
import { DataPanel } from "./components/DataPanel";
import { DividendForm } from "./components/DividendForm";
import { DividendList } from "./components/DividendList";
import { HoldingsTable } from "./components/HoldingsTable";
import { MarketStatus } from "./components/MarketStatus";
import { PerformanceChart } from "./components/PerformanceChart";
import { PortfolioSummary } from "./components/PortfolioSummary";
import { TradeForm } from "./components/TradeForm";
import { TradeList } from "./components/TradeList";
import { UnrealizedChart } from "./components/UnrealizedChart";

type View = "dashboard" | "trades" | "dividends" | "data";

export default function App() {
  const [view, setView] = useState<View>("dashboard");
  const [trades, setTrades] = useState<Trade[]>([]);
  const [dividends, setDividends] = useState<Dividend[]>([]);
  const [holdings, setHoldings] = useState<Holding[]>([]);
  const [summaries, setSummaries] = useState<CurrencySummary[]>([]);
  const [history, setHistory] = useState<EarningsByCurrency>({});
  const [names, setNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [assistantOpen, setAssistantOpen] = useState<boolean>(() => {
    try {
      return localStorage.getItem("assistant.open") === "true";
    } catch {
      return false;
    }
  });

  useEffect(() => {
    try {
      localStorage.setItem("assistant.open", String(assistantOpen));
    } catch {
      /* ignore */
    }
  }, [assistantOpen]);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const [t, d, h, s, hist, n] = await Promise.all([
        api.listTrades(),
        api.listDividends(),
        api.getHoldings(),
        api.getSummary(),
        api.getEarningsHistory(1825),
        api.getNames(),
      ]);
      setTrades(t);
      setDividends(d);
      setHoldings(h);
      setSummaries(s);
      setHistory(hist);
      setNames(n);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load data");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // Auto-refresh every 5s while the Dashboard is the active view AND the
  // browser tab is visible. Pauses on tab switch, minimize, or when
  // navigating to a different view; resumes with an immediate refresh.
  const [polling, setPolling] = useState(false);
  useEffect(() => {
    if (view !== "dashboard") {
      setPolling(false);
      return;
    }

    let interval: number | undefined;
    function start() {
      setPolling(true);
      refresh();
      interval = window.setInterval(refresh, 5000);
    }
    function stop() {
      setPolling(false);
      if (interval !== undefined) {
        clearInterval(interval);
        interval = undefined;
      }
    }

    function onVisibilityChange() {
      if (document.visibilityState === "visible") start();
      else stop();
    }

    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [view, refresh]);

  return (
    <div className="layout">
      <main className="app">
      <header className="app-header">
        <div className="brand-block">
          <h1>
            <span className="brand-mark" aria-hidden>
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
                <path
                  d="M3 18 L9 12 L13 16 L21 6"
                  stroke="white"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
                <circle cx="21" cy="6" r="1.6" fill="white" />
              </svg>
            </span>
            <span className="brand-text">Stock Tracker</span>
          </h1>
          <MarketStatus />
          {polling && (
            <span
              className="live-indicator"
              title="Auto-refreshing every 5 seconds"
            >
              Live
            </span>
          )}
        </div>
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
          <button
            className={assistantOpen ? "active assistant-toggle" : "assistant-toggle"}
            onClick={() => setAssistantOpen((o) => !o)}
            title="Toggle AI assistant sidebar"
          >
            ✦ Assistant
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
          <UnrealizedChart holdings={holdings} names={names} />
          <div className="dual-grid">
            <HoldingsTable holdings={holdings} />
            <AllocationChart holdings={holdings} names={names} />
          </div>
        </>
      )}

      {view === "trades" && !loading && (
        <>
          <TradeForm names={names} onCreated={refresh} />
          <TradeList trades={trades} names={names} onChanged={refresh} />
        </>
      )}

      {view === "dividends" && !loading && (
        <>
          <DividendForm names={names} onCreated={refresh} />
          <DividendList
            dividends={dividends}
            names={names}
            onChanged={refresh}
          />
        </>
      )}

      {view === "data" && !loading && (
        <DataPanel
          trades={trades}
          dividends={dividends}
          onImported={refresh}
        />
      )}

      </main>
      {assistantOpen && (
        <AssistantPanel onClose={() => setAssistantOpen(false)} />
      )}
    </div>
  );
}
