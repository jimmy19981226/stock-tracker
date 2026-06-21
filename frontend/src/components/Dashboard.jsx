import React, { useEffect, useMemo, useState } from "react";
import { api } from "../api.js";
import { money, signedMoney, pct, shares, plClass, prettyDate } from "../format.js";
import Sparkline from "./Sparkline.jsx";

export default function Dashboard({ onSignOut }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState(null);

  async function load() {
    try {
      const [overview, holdings, summary, earnings] = await Promise.all([
        api.overview(),
        api.holdings(),
        api.summary(),
        api.earnings(365),
      ]);
      setData({ overview, holdings, summary, earnings });
      setUpdatedAt(new Date());
      setError(null);
    } catch (err) {
      if (err.status === 401) return onSignOut();
      setError(err.message || "Couldn’t load the portfolio.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
    // Light polling so the dashboard stays fresh on a desktop left open.
    const id = setInterval(load, 30000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const overview = data?.overview;
  const combinedTwd = overview?.combined?.twd;
  const combinedUsd = overview?.combined?.usd;
  const fx = overview?.fx?.usd_twd;

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
        </section>

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
          {updatedAt && `Updated ${updatedAt.toLocaleTimeString()}`} · auto-refreshes every 30s
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
    </div>
  );
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

function Holdings({ holdings }) {
  const sorted = [...holdings].sort((a, b) => (b.market_value || 0) - (a.market_value || 0));
  if (!sorted.length) {
    return (
      <section className="card">
        <div className="card-head"><h2>Holdings</h2></div>
        <div className="muted empty-row">No open positions.</div>
      </section>
    );
  }
  return (
    <section className="card">
      <div className="card-head"><h2>Holdings</h2><span className="muted">{sorted.length}</span></div>
      <div className="holdings">
        <div className="hrow head">
          <span>Ticker</span>
          <span className="num">Price</span>
          <span className="num">Value</span>
          <span className="num">Unrealized</span>
        </div>
        {sorted.map((h) => (
          <div className="hrow" key={`${h.market}-${h.ticker}`}>
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
        ))}
      </div>
    </section>
  );
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
