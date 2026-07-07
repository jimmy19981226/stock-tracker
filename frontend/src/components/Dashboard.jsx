import React, { useEffect, useMemo, useRef, useState } from "react";
import { api } from "../api.js";
import { money, signedMoney, pct, shares, plClass, prettyDate } from "../format.js";
import Sparkline from "./Sparkline.jsx";

export default function Dashboard({ onSignOut }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState(null);

  const inFlight = useRef(false);

  // Price-driven numbers (quotes, values, P/L). Polled every 5s — the backend
  // quote cache has a matching 5s TTL, so each poll sees fresh prices.
  async function loadQuotes() {
    if (inFlight.current) return; // don't stack requests on a slow backend
    inFlight.current = true;
    try {
      const [overview, holdings] = await Promise.all([api.overview(), api.holdings()]);
      setData((prev) => ({ ...prev, overview, holdings }));
      setUpdatedAt(new Date());
      setError(null);
    } catch (err) {
      if (err.status === 401) return onSignOut();
      setError(err.message || "Couldn’t load the portfolio.");
    } finally {
      inFlight.current = false;
      setLoading(false);
    }
  }

  // Earnings history only moves on dividends/sells — a slow cadence is plenty.
  async function loadEarnings() {
    try {
      const earnings = await api.earnings(365);
      setData((prev) => ({ ...prev, earnings }));
    } catch (err) {
      if (err.status === 401) return onSignOut();
      /* transient — keep showing the last good series */
    }
  }

  useEffect(() => {
    loadQuotes();
    loadEarnings();
    // Fast poll for live prices; pause while the tab is hidden so a
    // backgrounded dashboard doesn't hammer the backend.
    const quotesId = setInterval(() => {
      if (document.visibilityState === "visible") loadQuotes();
    }, 5000);
    const earningsId = setInterval(() => {
      if (document.visibilityState === "visible") loadEarnings();
    }, 60000);
    return () => {
      clearInterval(quotesId);
      clearInterval(earningsId);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const overview = data?.overview;
  const combinedTwd = overview?.combined?.twd;
  const combinedUsd = overview?.combined?.usd;
  const fx = overview?.fx?.usd_twd;

  // Combined Total Return = unrealized + realized + dividends, across both
  // markets, expressed in TWD (US leg converted at the current FX rate).
  const twTR = marketTotalReturn(overview?.tw);
  const usTR = marketTotalReturn(overview?.us);
  const combinedTR =
    twTR == null && usTR == null
      ? null
      : (twTR ?? 0) + (fx != null ? (usTR ?? 0) * fx : 0);
  const combinedTRUsd = combinedTR != null && fx ? combinedTR / fx : null;
  const fxAsof = overview?.fx?.asof
    ? new Date(overview.fx.asof).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" })
    : null;

  // Build the combined "total earned" series across both markets in TWD.
  // (Hook must run unconditionally — keep it above any early return.)
  const earnedSeries = useMemo(() => buildEarnedSeries(data?.earnings, fx), [data?.earnings, fx]);

  if (loading && !data) {
    return (
      <div className="centered">
        <div className="spinner" aria-label="Loading" />
        <div className="loading-note">Loading portfolio… the server may take a moment to wake up.</div>
      </div>
    );
  }

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">✦ AI Stock Studio</div>
        <button className="ghost" onClick={onSignOut}>
          Sign out
        </button>
      </header>

      <main className="container">
        {error && <div className="error banner">{error}</div>}

        <section className="hero">
          <div className="hero-label">Investing net worth</div>
          <div className="hero-value">{money(combinedTwd, "TWD")}</div>
          <div className="hero-sub">
            ≈ {money(combinedUsd, "USD")}
            {fx != null && <span className="fx">USD/TWD {fx.toFixed(2)}</span>}
          </div>
          {combinedTR != null && (
            <div className="total-return-badge">
              <span className="tr-label">Total return</span>
              <span className={`tr-value ${plClass(combinedTR)}`}>{signedMoney(combinedTR, "TWD")}</span>
              {combinedTRUsd != null && (
                <span className="tr-usd">≈ {signedMoney(combinedTRUsd, "USD")}</span>
              )}
              <span className="tr-note">
                unrealized + realized + dividends{fxAsof ? ` · FX rate ${fxAsof}` : ""}
              </span>
            </div>
          )}
        </section>

        <NetWorthChart fx={fx} liveTotal={combinedTwd} />

        {earnedSeries.length >= 2 && (
          <section className="card">
            <div className="card-head">
              <h2>Total earned</h2>
              <span className={`pl ${plClass(earnedSeries[earnedSeries.length - 1].value)}`}>
                {signedMoney(earnedSeries[earnedSeries.length - 1].value, "TWD")}
              </span>
            </div>
            <Sparkline
              data={earnedSeries}
              formatValue={(v) => signedMoney(v, "TWD")}
              formatDate={(d) =>
                d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })
              }
            />
          </section>
        )}

        <section className="market-cards">
          <MarketCard title="Taiwan" currency="TWD" summary={overview?.tw} />
          <MarketCard title="US" currency="USD" summary={overview?.us} />
        </section>

        <Holdings holdings={data?.holdings || []} />

        <footer className="updated">
          {updatedAt && `Updated ${updatedAt.toLocaleTimeString()}`} · auto-refreshes every 5s · read-only
        </footer>
      </main>
    </div>
  );
}

function MarketCard({ title, currency, summary }) {
  if (!summary) {
    return (
      <div className="card market empty">
        <div className="market-title">{title}</div>
        <div className="muted">No holdings</div>
      </div>
    );
  }
  const tr = marketTotalReturn(summary);
  const trPct =
    tr != null && summary.total_cost > 0 ? (tr / summary.total_cost) * 100 : null;
  return (
    <div className="card market">
      <div className="market-title">{title}</div>
      <div className="market-value">{money(summary.total_value, currency)}</div>
      <div className="market-rows">
        <Row label="Today" value={signedMoney(summary.today_pl, currency)} cls={plClass(summary.today_pl)} extra={summary.today_pl_pct != null ? pct(summary.today_pl_pct) : null} />
        <Row label="Unrealized" value={signedMoney(summary.total_pl, currency)} cls={plClass(summary.total_pl)} extra={summary.total_pl_pct != null ? pct(summary.total_pl_pct) : null} />
        <Row label="Realized" value={signedMoney(summary.realized_pl, currency)} cls={plClass(summary.realized_pl)} />
        <Row label="Dividends" value={money(summary.dividends, currency)} cls="muted" />
      </div>
      {tr != null && (
        <div className="market-total-return">
          <span className="mtr-label">Total return <span className="mtr-unit">{currency}</span></span>
          <span className={`mtr-value ${plClass(tr)}`}>
            {signedMoney(tr, currency)}
            {trPct != null && <span className="mtr-pct">{pct(trPct)}</span>}
          </span>
        </div>
      )}
    </div>
  );
}

// Total Return for one market = unrealized (total_pl) + realized + dividends.
// The backend already sums realized + dividends into total_earned.
function marketTotalReturn(summary) {
  if (!summary) return null;
  return (summary.total_pl ?? 0) + (summary.total_earned ?? 0);
}

function Row({ label, value, cls, extra }) {
  return (
    <div className="kv">
      <span className="k">{label}</span>
      <span className={`v ${cls || ""}`}>
        {value}
        {extra && <span className="v-extra">{extra}</span>}
      </span>
    </div>
  );
}

// Market display order + labels for grouping holdings.
const MARKET_GROUPS = [
  { code: "TW", label: "Taiwan", currency: "TWD" },
  { code: "US", label: "US", currency: "USD" },
];

function Holdings({ holdings }) {
  if (!holdings.length) {
    return (
      <section className="card">
        <div className="card-head"><h2>Holdings</h2></div>
        <div className="muted empty-row">No open positions.</div>
      </section>
    );
  }

  // One separate card per market (TW then US), each sorted by value desc.
  // Any market not in MARKET_GROUPS still gets its own card under its raw code.
  const knownCodes = MARKET_GROUPS.map((g) => g.code);
  const extraCodes = [...new Set(holdings.map((h) => h.market).filter((m) => !knownCodes.includes(m)))];
  const groups = [
    ...MARKET_GROUPS,
    ...extraCodes.map((code) => ({ code, label: code, currency: holdings.find((h) => h.market === code)?.currency || "" })),
  ]
    .map((g) => ({
      ...g,
      rows: holdings.filter((h) => h.market === g.code).sort((a, b) => (b.market_value || 0) - (a.market_value || 0)),
    }))
    .filter((g) => g.rows.length);

  return (
    <>
      {groups.map((g) => {
        const groupValue = g.rows.reduce((sum, h) => sum + (h.market_value || 0), 0);
        return (
          <section className="card" key={g.code}>
            <div className="card-head">
              <h2>{g.label} holdings</h2>
              <span className="muted">
                {g.rows.length} · {money(groupValue, g.currency)}
              </span>
            </div>
            <div className="holdings">
              <div className="hrow head">
                <span>Ticker</span>
                <span className="num">Price</span>
                <span className="num">Value</span>
                <span className="num">Unrealized</span>
              </div>
              {g.rows.map((h) => (
                <HoldingRow key={`${h.market}-${h.ticker}`} h={h} />
              ))}
            </div>
          </section>
        );
      })}
    </>
  );
}

function HoldingRow({ h }) {
  return (
    <div className="hrow">
      <span className="tk">
        <span className="tk-sym">{h.ticker}</span>
        {h.name && <span className="tk-name">{h.name}</span>}
        <span className="tk-sh">{shares(h.shares)} sh</span>
      </span>
      <span className="num">
        {money(h.current_price, h.currency, 2)}
        {h.today_change_pct != null && (
          <span className={`mini ${plClass(h.today_change_pct)}`}>{pct(h.today_change_pct)}</span>
        )}
      </span>
      <span className="num">{money(h.market_value, h.currency)}</span>
      <span className={`num ${plClass(h.unrealized_pl)}`}>
        {signedMoney(h.unrealized_pl, h.currency)}
        {h.unrealized_pl_pct != null && <span className="mini">{pct(h.unrealized_pl_pct)}</span>}
      </span>
    </div>
  );
}

// Period tabs for the net-worth chart (labels → backend period params).
const VALUE_PERIODS = [
  { label: "1M", period: "1mo" },
  { label: "3M", period: "3mo" },
  { label: "6M", period: "6mo" },
  { label: "YTD", period: "ytd" },
  { label: "1Y", period: "1y" },
  { label: "MAX", period: "max" },
];

// Combined (TW + US, in TWD) portfolio-value history with period tabs —
// the same net-worth curve the iOS app charts. Series are fetched once per
// period and cached; the last point is stitched to the live combined total
// so the curve always ends at the number in the hero.
function NetWorthChart({ fx, liveTotal }) {
  const [period, setPeriod] = useState("1y");
  const [seriesByPeriod, setSeriesByPeriod] = useState({}); // period -> [{date,total}] per market
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (seriesByPeriod[period]) return;
    let cancelled = false;
    setLoading(true);
    Promise.all([api.valueHistory("TW", period), api.valueHistory("US", period)])
      .then(([tw, us]) => {
        if (cancelled) return;
        setSeriesByPeriod((prev) => ({ ...prev, [period]: { tw, us } }));
      })
      .catch(() => {
        /* transient — the card just stays in its loading/empty state */
      })
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [period]);

  const series = useMemo(() => {
    const raw = seriesByPeriod[period];
    if (!raw) return [];
    const pts = combineValueSeries(raw.tw, raw.us, fx);
    // End the curve at the live combined total so chart and hero agree.
    if (pts.length && liveTotal != null) pts[pts.length - 1] = { ...pts[pts.length - 1], value: liveTotal };
    return pts;
  }, [seriesByPeriod, period, fx, liveTotal]);

  const change = series.length >= 2 ? series[series.length - 1].value - series[0].value : null;
  const changePct =
    change != null && series[0].value > 0 ? (change / series[0].value) * 100 : null;

  return (
    <section className="card">
      <div className="card-head">
        <h2>Net worth</h2>
        {change != null && (
          <span className={`pl ${plClass(change)}`}>
            {signedMoney(change, "TWD")}
            {changePct != null && <span className="v-extra">{pct(changePct)}</span>}
          </span>
        )}
      </div>
      <div className="period-tabs" role="tablist" aria-label="Chart period">
        {VALUE_PERIODS.map((p) => (
          <button
            key={p.period}
            role="tab"
            aria-selected={period === p.period}
            className={`period-tab${period === p.period ? " active" : ""}`}
            onClick={() => setPeriod(p.period)}
          >
            {p.label}
          </button>
        ))}
      </div>
      {series.length >= 2 ? (
        <Sparkline
          data={series}
          formatValue={(v) => money(v, "TWD")}
          formatDate={(d) =>
            d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })
          }
        />
      ) : (
        <div className="muted empty-row">
          {loading ? "Loading value history…" : "Not enough history for this period yet."}
        </div>
      )}
    </section>
  );
}

// Merge per-market daily value series into one TWD total across the union of
// dates, carrying each market's last value forward over gaps (different
// trading calendars), converting the US leg at the current FX rate.
function combineValueSeries(tw, us, fx) {
  const twByDate = new Map();
  const usByDate = new Map();
  for (const p of tw || []) twByDate.set(p.date.slice(0, 10), p.total);
  for (const p of us || []) usByDate.set(p.date.slice(0, 10), p.total);
  const allDates = [...new Set([...twByDate.keys(), ...usByDate.keys()])].sort();
  let lastTw = 0;
  let lastUs = 0;
  return allDates.map((d) => {
    if (twByDate.has(d)) lastTw = twByDate.get(d);
    if (usByDate.has(d)) lastUs = usByDate.get(d);
    return { date: new Date(d + "T00:00:00Z"), value: lastTw + (fx != null ? lastUs * fx : 0) };
  });
}

// Merge the per-currency earnings series into one TWD-denominated total series,
// carrying each currency's last value forward across the union of dates (mirrors
// the iOS TotalEarnedCard logic).
function buildEarnedSeries(earnings, fx) {
  if (!earnings) return [];
  const tw = earnings.TWD || [];
  const us = earnings.USD || [];
  const twByDate = new Map();
  const usByDate = new Map();
  for (const p of tw) twByDate.set(p.date.slice(0, 10), p.total);
  for (const p of us) usByDate.set(p.date.slice(0, 10), p.total);
  const allDates = [...new Set([...twByDate.keys(), ...usByDate.keys()])].sort();
  let lastTw = 0;
  let lastUs = 0;
  return allDates.map((d) => {
    if (twByDate.has(d)) lastTw = twByDate.get(d);
    if (usByDate.has(d)) lastUs = usByDate.get(d);
    const total = lastTw + (fx != null ? lastUs * fx : 0);
    return { date: new Date(d + "T00:00:00Z"), value: total };
  });
}
