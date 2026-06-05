import { lazy, Suspense, useCallback, useEffect, useState } from "react";
import {
  api,
  type CurrencySummary,
  type Dividend,
  type EarningsByCurrency,
  type Holding,
  type MarketCode,
  type MarketConfig,
  type Trade,
} from "./api";
import { AllocationChart } from "./components/AllocationChart";
import { DividendForm } from "./components/DividendForm";
import { DividendList } from "./components/DividendList";
import { HoldingsTable } from "./components/HoldingsTable";
import { MarketStatus } from "./components/MarketStatus";
import { Overview } from "./components/Overview";
import { PerformanceChart } from "./components/PerformanceChart";
import { PortfolioSummary } from "./components/PortfolioSummary";
import { TradeForm } from "./components/TradeForm";
import { TradeList } from "./components/TradeList";
import { UnrealizedChart } from "./components/UnrealizedChart";
import { AgentProvider } from "./agent/AgentProvider";
import { isMarketOpen } from "./format";

const AssistantPanel = lazy(() =>
  import("./components/AssistantPanel").then((m) => ({ default: m.AssistantPanel })),
);
const StockDetail = lazy(() =>
  import("./components/StockDetail").then((m) => ({ default: m.StockDetail })),
);

type View = "dashboard" | "trades" | "dividends";

export default function App() {
  // null = the Overview landing page; "TW"/"US" = inside that portfolio.
  const [market, setMarket] = useState<MarketCode | null>(null);
  const [view, setView] = useState<View>("dashboard");
  const [trades, setTrades] = useState<Trade[]>([]);
  const [dividends, setDividends] = useState<Dividend[]>([]);
  const [holdings, setHoldings] = useState<Holding[]>([]);
  const [summaries, setSummaries] = useState<CurrencySummary[]>([]);
  const [history, setHistory] = useState<EarningsByCurrency>({});
  const [names, setNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedTicker, setSelectedTicker] = useState<string | null>(null);
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

  // Auto-refresh while the Dashboard is the active view AND the browser tab
  // is visible. Cadence: 5s during TW market hours, 60s outside (prices can't
  // change but trade/dividend edits from another tab still need to sync).
  // Pauses on tab switch, minimize, or view change; resumes with an immediate
  // refresh.
  const [polling, setPolling] = useState(false);
  // Market config (currency, session hours, holidays) comes from the DB via
  // /api/markets — nothing about trading calendars is hardcoded here.
  const [markets, setMarkets] = useState<MarketConfig[]>([]);
  useEffect(() => {
    api.getMarkets().then(setMarkets).catch(() => {
      /* offline — cadence safely defaults to the slow 60s path */
    });
  }, []);
  const activeMarketCfg = market ? markets.find((m) => m.code === market) ?? null : null;
  // Status pill on Overview defaults to TW; in a portfolio it tracks that market.
  const statusMarket = activeMarketCfg ?? markets.find((m) => m.code === "TW") ?? null;

  // "Is the market I'm currently viewing open?" — drives the fast (5s) vs slow
  // (60s) refresh cadence. Each market's hours/holidays/timezone come from its
  // config, so the cadence follows whichever portfolio is on screen.
  const [marketOpen, setMarketOpen] = useState(false);
  useEffect(() => {
    const check = () => setMarketOpen(isMarketOpen(activeMarketCfg));
    check();
    const tick = window.setInterval(check, 60_000);
    return () => clearInterval(tick);
  }, [activeMarketCfg]);

  useEffect(() => {
    if (market === null || view !== "dashboard") {
      setPolling(false);
      return;
    }

    const cadence = marketOpen ? 5000 : 60_000;
    let interval: number | undefined;
    function start() {
      setPolling(true);
      refresh();
      interval = window.setInterval(refresh, cadence);
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
  }, [market, view, refresh, marketOpen]);

  // Scope every view to the selected market. Holdings/summaries split by
  // currency (TWD↔TW, USD↔US); trades/dividends carry an explicit market.
  const cur = market === "US" ? "USD" : "TWD";
  const mHoldings = holdings.filter((h) => h.market === market);
  const mSummaries = summaries.filter((s) => s.currency === cur);
  const mTrades = trades.filter((t) => t.market === market);
  const mDividends = dividends.filter((d) => d.market === market);
  const mHistory: EarningsByCurrency = history[cur] ? { [cur]: history[cur] } : {};

  return (
    <AgentProvider>
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
            <span className="brand-text">AI Stock Studio</span>
          </h1>
          <MarketStatus market={statusMarket} />
          {polling && (
            <span
              className="live-indicator"
              title={
                marketOpen
                  ? "Auto-refreshing every 5 seconds"
                  : "Market closed — refreshing every 60 seconds"
              }
            >
              Live
            </span>
          )}
        </div>
        <div className="header-right">
          {market !== null && (
            <div className="portfolio-context">
              <button
                data-agent="nav-overview"
                className="nav-back"
                onClick={() => {
                  setMarket(null);
                  setView("dashboard");
                }}
                title="Back to all portfolios"
              >
                <span className="nav-back-chevron" aria-hidden>
                  ‹
                </span>
                <span className="nav-label">Portfolios</span>
              </button>
              <span
                className="market-chip"
                data-market={market}
                aria-label={`${market === "US" ? "United States" : "Taiwan"} portfolio`}
              >
                <span className="market-chip-dot" aria-hidden />
                {market}
              </span>
            </div>
          )}
          <nav>
            {market !== null && (
              <>
                <button
                  data-agent="nav-dashboard"
                  className={view === "dashboard" ? "active" : ""}
                  onClick={() => setView("dashboard")}
                >
                  Dashboard
                </button>
                <button
                  data-agent="nav-trades"
                  className={view === "trades" ? "active" : ""}
                  onClick={() => setView("trades")}
                >
                  Trades
                </button>
                <button
                  data-agent="nav-dividends"
                  className={view === "dividends" ? "active" : ""}
                  onClick={() => setView("dividends")}
                >
                  Dividends
                </button>
              </>
            )}
            <button
              className={assistantOpen ? "active assistant-toggle" : "assistant-toggle"}
              onClick={() => setAssistantOpen((o) => !o)}
              title="Toggle AI assistant sidebar"
            >
              ✦ <span className="nav-label">Assistant</span>
            </button>
          </nav>
        </div>
      </header>

      {error && <div className="error">{error}</div>}
      {loading && <div className="muted">Loading…</div>}

      {market === null && !loading && (
        <Overview
          onEnter={(m) => {
            setMarket(m);
            setView("dashboard");
          }}
        />
      )}

      {market !== null && view === "dashboard" && !loading && (
        <>
          <PortfolioSummary summaries={mSummaries} />
          <PerformanceChart history={mHistory} />
          <UnrealizedChart holdings={mHoldings} names={names} />
          <div className="dual-grid">
            <HoldingsTable holdings={mHoldings} onSelectTicker={setSelectedTicker} />
            <AllocationChart holdings={mHoldings} names={names} />
          </div>
        </>
      )}

      {market !== null && view === "trades" && !loading && (
        <>
          <TradeForm names={names} market={market} onCreated={refresh} />
          <TradeList trades={mTrades} names={names} onChanged={refresh} />
        </>
      )}

      {market !== null && view === "dividends" && !loading && (
        <>
          <DividendForm names={names} market={market} onCreated={refresh} />
          <DividendList
            dividends={mDividends}
            names={names}
            onChanged={refresh}
          />
        </>
      )}

      </main>
      <Suspense fallback={null}>
        {assistantOpen && (
          <AssistantPanel
            holdings={holdings}
            trades={trades}
            dividends={dividends}
            currentView={market === null ? "overview" : view}
            onClose={() => setAssistantOpen(false)}
            onPortfolioChanged={refresh}
          />
        )}
        {selectedTicker && (
          <StockDetail
            ticker={selectedTicker}
            onClose={() => setSelectedTicker(null)}
          />
        )}
      </Suspense>
    </div>
    </AgentProvider>
  );
}
