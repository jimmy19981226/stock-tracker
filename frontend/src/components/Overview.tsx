import { useEffect, useRef, useState } from "react";
import {
  api,
  type CurrencySummary,
  type MarketCode,
  type PortfolioOverview,
} from "../api";
import { fmtMoney, fmtPct, plClass } from "../format";
import { FlashValue } from "./FlashValue";

interface Props {
  onEnter: (market: MarketCode) => void;
}

const MARKETS: { code: MarketCode; label: string; flag: string; currency: string }[] = [
  { code: "TW", label: "Taiwan", flag: "🇹🇼", currency: "TWD" },
  { code: "US", label: "United States", flag: "🇺🇸", currency: "USD" },
];

/** Landing page: one card per market (TW / US) plus a combined net worth shown
 *  in both NT$ and US$. Clicking a card enters that portfolio. Self-refreshes
 *  so the figures stay live while it's on screen. */
export function Overview({ onEnter }: Props) {
  const [data, setData] = useState<PortfolioOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Direction-aware flash when the combined net worth ticks up/down.
  const [flash, setFlash] = useState<"up" | "down" | null>(null);
  const prevTwd = useRef<number | null>(null);
  const flashTimer = useRef<number | undefined>(undefined);

  useEffect(() => {
    let cancelled = false;
    const load = () =>
      api
        .getOverview()
        .then((d) => {
          if (cancelled) return;
          const cur = d.combined.twd;
          const prev = prevTwd.current;
          if (cur != null && prev != null && cur !== prev) {
            setFlash(cur > prev ? "up" : "down");
            window.clearTimeout(flashTimer.current);
            flashTimer.current = window.setTimeout(() => setFlash(null), 900);
          }
          if (cur != null) prevTwd.current = cur;
          setData(d);
          setError(null);
        })
        .catch((e) => {
          if (!cancelled) setError(e instanceof Error ? e.message : "Failed to load");
        });
    load();
    const id = window.setInterval(load, 15000);
    return () => {
      cancelled = true;
      clearInterval(id);
      window.clearTimeout(flashTimer.current);
    };
  }, []);

  const summaryFor = (code: MarketCode): CurrencySummary | null =>
    data ? (code === "TW" ? data.tw : data.us) : null;

  return (
    <div className="overview">
      <div className={`networth-hero panel${flash ? ` flash-${flash}` : ""}`}>
        <div className="networth-label">Combined net worth</div>
        <div className="networth-values">
          <div className="networth-amount">
            {data?.combined.twd != null ? fmtMoney(data.combined.twd, "TWD") : "—"}
          </div>
          <div className="networth-sep">·</div>
          <div className="networth-amount alt">
            {data?.combined.usd != null ? fmtMoney(data.combined.usd, "USD") : "—"}
          </div>
        </div>
        <div className="networth-sub muted">
          {data?.fx.usd_twd != null ? (
            <>
              TW + US combined · 1 USD = {data.fx.usd_twd.toFixed(3)} TWD
              {data.fx.asof ? ` · as of ${new Date(data.fx.asof).toLocaleDateString()}` : ""}
            </>
          ) : (
            "Combined total unavailable — exchange rate could not be fetched"
          )}
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="overview-grid">
        {MARKETS.map((m) => {
          const s = summaryFor(m.code);
          const hasPositions = !!s && s.holdings_count > 0;
          return (
            <button
              key={m.code}
              type="button"
              className="market-card"
              data-agent={`overview-${m.code.toLowerCase()}`}
              onClick={() => onEnter(m.code)}
            >
              <div className="market-card-head">
                <span className="market-flag" aria-hidden>
                  {m.flag}
                </span>
                <div className="market-card-titles">
                  <span className="market-card-title">{m.label}</span>
                  <span className="market-card-sub muted">
                    {hasPositions
                      ? `${s!.holdings_count} ${s!.holdings_count === 1 ? "holding" : "holdings"} · ${m.currency}`
                      : "No positions yet"}
                  </span>
                </div>
                <span className="market-card-chevron" aria-hidden>
                  ›
                </span>
              </div>

              {hasPositions ? (
                <>
                  <div className="market-card-value">
                    <FlashValue value={s!.total_value}>
                      {fmtMoney(s!.total_value, m.currency)}
                    </FlashValue>
                  </div>
                  <div className="market-card-stats">
                    <div className="mcs">
                      <span className="mcs-label muted">Total P/L</span>
                      <span className={`mcs-value ${plClass(s!.total_pl)}`}>
                        {fmtMoney(s!.total_pl, m.currency)} ({fmtPct(s!.total_pl_pct)})
                      </span>
                    </div>
                    <div className="mcs">
                      <span className="mcs-label muted">Today</span>
                      <span className={`mcs-value ${plClass(s!.today_pl)}`}>
                        {fmtMoney(s!.today_pl, m.currency)} ({fmtPct(s!.today_pl_pct)})
                      </span>
                    </div>
                    <div className="mcs">
                      <span className="mcs-label muted">Total earned</span>
                      <span className={`mcs-value ${plClass(s!.total_earned)}`}>
                        {fmtMoney(s!.total_earned, m.currency)}
                      </span>
                    </div>
                  </div>
                </>
              ) : (
                <div className="market-card-empty muted">
                  Click to open the {m.label} portfolio and add your first{" "}
                  {m.code === "US" ? "US" : "TW"} trade.
                </div>
              )}
            </button>
          );
        })}
      </div>
    </div>
  );
}
