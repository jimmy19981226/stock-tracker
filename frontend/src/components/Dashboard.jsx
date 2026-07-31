import React, { useEffect, useMemo, useRef, useState } from "react";
import { api } from "../api.js";
import { money, signedMoney, compactMoney, pct, shares, plClass } from "../format.js";
import { anyMarketOpen, isMarketOpen } from "../marketHours.js";
import Sparkline from "./Sparkline.jsx";

// Poll cadence, matching PortfolioStore.startPolling on iOS: fast while a
// market is trading, slow when both are shut.
const TICK_MS = 5000;
const CLOSED_TICKS = 12; // → one refresh per 60s outside market hours

export default function Dashboard({ onSignOut }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState(null);
  const [marketsOpen, setMarketsOpen] = useState(true);
  const [sessions, setSessions] = useState([]); // [{code, label, open}]

  const inFlight = useRef(false);
  const markets = useRef([]);
  const tick = useRef(0);

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
    // Session hours drive the cadence below. Public endpoint, and holidays
    // change rarely, so one fetch per mount is enough.
    api
      .markets()
      .then((m) => {
        markets.current = m || [];
        setMarketsOpen(anyMarketOpen(markets.current));
        setSessions(readSessions(markets.current));
      })
      .catch(() => {
        /* unknown hours — the fallback below keeps the fast cadence */
      });

    // Daily USD/TWD rates, fetched once for the whole session. Every chart that
    // converts a historical US figure uses these; "max" covers every period tab
    // and forward-fills, so no tab needs its own request. An older backend
    // without the endpoint just falls back to today's rate.
    api
      .fxHistory("max")
      .then((rows) => setData((prev) => ({ ...prev, fxHistory: rows })))
      .catch(() => {});

    // Poll for live prices; pause while the tab is hidden so a backgrounded
    // dashboard doesn't hammer the backend. Prices only move while a market is
    // in session, so once both close we drop to one refresh a minute — an idle
    // dashboard left open overnight was previously enough on its own to keep
    // the free-tier backend awake and burning quote fetches.
    const quotesId = setInterval(() => {
      if (document.visibilityState !== "visible") return;
      tick.current += 1;
      // No markets loaded → assume open, so a failed /api/markets can never
      // silently stall the dashboard at a 60s refresh.
      const open = markets.current.length === 0 || anyMarketOpen(markets.current);
      setMarketsOpen(open);
      setSessions(readSessions(markets.current));
      if (open || tick.current % CLOSED_TICKS === 0) loadQuotes();
    }, TICK_MS);
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

  // Sum one field across both markets in TWD (US leg at the live rate). Null
  // when neither market reports it, so a stat shows "—" rather than a fake 0.
  const combine = (field) => {
    const t = overview?.tw?.[field];
    const u = overview?.us?.[field];
    if (t == null && u == null) return null;
    return (t ?? 0) + (fx != null ? (u ?? 0) * fx : 0);
  };
  const combinedToday = combine("today_pl");
  const combinedUnrealized = combine("total_pl");
  const combinedEarned = combine("total_earned");
  const fxAsof = overview?.fx?.asof
    ? new Date(overview.fx.asof).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" })
    : null;

  // Build the combined "total earned" series across both markets in TWD.
  // (Hook must run unconditionally — keep it above any early return.)
  const fxHistory = data?.fxHistory;
  const earnedSeries = useMemo(
    () => buildEarnedSeries(data?.earnings, fx, fxHistory),
    [data?.earnings, fx, fxHistory]
  );

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
        <div className="brand">
          <span className="brand-mark">✦</span> AI Stock Studio
        </div>
        <div className="topbar-spacer" />
        {/* Live session state — the same market hours that drive the poll
            cadence, so "why isn't this moving?" answers itself. */}
        <div className="session-pills">
          {sessions.map((s) => (
            <span key={s.code} className={`session-pill${s.open ? " open" : ""}`}>
              <span className="session-dot" />
              {s.label}
            </span>
          ))}
        </div>
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
            <span>≈ {money(combinedUsd, "USD")}</span>
            {fx != null && (
              <>
                <span className="dot-sep">·</span>
                <span className="fx">USD/TWD {fx.toFixed(2)}</span>
              </>
            )}
            {fxAsof && (
              <>
                <span className="dot-sep">·</span>
                <span className="fx">FX {fxAsof}</span>
              </>
            )}
          </div>

          {/* The four numbers that used to be crammed into a wrapping pill and
              repeated per market card, promoted to their own row. */}
          <div className="stat-strip">
            <Stat label="Today" value={combinedToday} currency="TWD" signed />
            <Stat label="Unrealized" value={combinedUnrealized} currency="TWD" signed />
            <Stat label="Realized + div" value={combinedEarned} currency="TWD" signed />
            <Stat
              label="Total return"
              value={combinedTR}
              currency="TWD"
              signed
              accent
              sub={combinedTRUsd != null ? `≈ ${signedMoney(combinedTRUsd, "USD")}` : null}
            />
          </div>
        </section>

        <NetWorthChart fx={fx} fxHistory={fxHistory} liveTotal={combinedTwd} />

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
              height={120}
              formatValue={(v) => signedMoney(v, "TWD")}
              formatScale={(v) => compactMoney(v, "TWD")}
              formatDate={(d) =>
                d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })
              }
            />
          </section>
        )}

        <section className="market-cards">
          <MarketCard title="Taiwan" currency="TWD" summary={overview?.tw}
                      share={marketShare(overview?.tw?.total_value, combinedTwd)} />
          <MarketCard title="US" currency="USD" summary={overview?.us}
                      share={marketShare(usValueInTwd(overview?.us, fx), combinedTwd)} />
        </section>

        <Holdings holdings={data?.holdings || []} />

        <footer className="updated">
          {updatedAt && `Updated ${updatedAt.toLocaleTimeString()}`} ·{" "}
          {marketsOpen ? "auto-refreshes every 5s" : "markets closed · refreshing every 60s"} · read-only
        </footer>
      </main>
    </div>
  );
}

// One figure in the hero's stat strip. Values are proportional (not tabular) —
// tabular digits make a standalone number look loose at this size.
function Stat({ label, value, currency, signed, accent, sub }) {
  const text = value == null ? "—" : signed ? signedMoney(value, currency) : money(value, currency);
  return (
    <div className={`stat${accent ? " accent" : ""}`}>
      <div className="stat-label">{label}</div>
      <div className={`stat-value ${accent ? "" : plClass(value)}`} title={text}>
        {value != null && signed && <Arrow value={value} />}
        {text}
      </div>
      {sub && <div className="stat-sub">{sub}</div>}
    </div>
  );
}

// Direction as a shape, not only as a hue — red/green alone fails for the ~8%
// of men with a colour-vision deficiency.
function Arrow({ value }) {
  if (value == null || value === 0) return null;
  return (
    <span className="arrow" aria-hidden="true">
      {value > 0 ? "▲" : "▼"}
    </span>
  );
}

// Per-market open/closed, derived from the same /api/markets rows that set the
// poll cadence.
function readSessions(markets) {
  return (markets || []).map((m) => ({
    code: m.code,
    label: m.code,
    open: isMarketOpen(m),
  }));
}

function MarketCard({ title, currency, summary, share }) {
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
      <div className="market-head">
        <span className="market-title">{title}</span>
        {/* This market's share of total net worth — the allocation split, for
            free, from numbers already on screen. */}
        {share != null && <span className="market-share">{share.toFixed(0)}% of total</span>}
      </div>
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

function usValueInTwd(summary, fx) {
  if (!summary || summary.total_value == null || fx == null) return null;
  return summary.total_value * fx;
}

function marketShare(valueTwd, combinedTwd) {
  if (valueTwd == null || !combinedTwd) return null;
  return (valueTwd / combinedTwd) * 100;
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
                <span className="num col-price">Price</span>
                <span className="num">Value</span>
                <span className="num">Unrealized</span>
              </div>
              {g.rows.map((h) => (
                <HoldingRow key={`${h.market}-${h.ticker}`} h={h} groupValue={groupValue} />
              ))}
            </div>
          </section>
        );
      })}
    </>
  );
}

function HoldingRow({ h, groupValue }) {
  // Share of this market's value. The bar turns "which positions dominate?"
  // into a glance without adding a column.
  const weight = groupValue > 0 && h.market_value != null ? (h.market_value / groupValue) * 100 : null;
  return (
    <div className="hrow">
      <span className="tk">
        <span className="tk-sym">{h.ticker}</span>
        {h.name && <span className="tk-name">{h.name}</span>}
        <span className="tk-sh">
          {shares(h.shares)} sh{weight != null && ` · ${weight.toFixed(1)}%`}
        </span>
        {weight != null && (
          <span className="weight" role="presentation">
            <span className="weight-fill" style={{ width: `${Math.min(100, weight)}%` }} />
          </span>
        )}
      </span>
      <span className="num col-price">
        {money(h.current_price, h.currency, 2)}
        {h.today_change_pct != null && (
          <span className={`mini ${plClass(h.today_change_pct)}`}>
            <Arrow value={h.today_change_pct} />
            {pct(h.today_change_pct)}
          </span>
        )}
      </span>
      <span className="num">{money(h.market_value, h.currency)}</span>
      <span className={`num ${plClass(h.unrealized_pl)}`}>
        <Arrow value={h.unrealized_pl} />
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
function NetWorthChart({ fx, fxHistory, liveTotal }) {
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
    const pts = combineValueSeries(raw.tw, raw.us, fx, fxHistory);
    // End the curve at the live combined total so chart and hero agree.
    if (pts.length && liveTotal != null) pts[pts.length - 1] = { ...pts[pts.length - 1], value: liveTotal };
    return pts;
  }, [seriesByPeriod, period, fx, fxHistory, liveTotal]);

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
        // While a new period loads, hold the current chart at reduced opacity
        // rather than swapping in a placeholder — no skeleton flash, no jump.
        <div className={loading ? "is-refreshing" : undefined}>
          <Sparkline
            data={series}
            formatValue={(v) => money(v, "TWD")}
            formatScale={(v) => compactMoney(v, "TWD")}
            formatDate={(d) =>
              d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" })
            }
          />
        </div>
      ) : (
        <div className="muted empty-row">
          {loading ? "Loading value history…" : "Not enough history for this period yet."}
        </div>
      )}
    </section>
  );
}

// Merge per-market daily value series into one TWD total across the union of
// dates, carrying each market's last value forward over gaps (different trading
// calendars). The US leg is converted at the rate that applied ON THAT DAY —
// using today's rate for the whole series restates years of history by whatever
// the currency has done since (a 5% FX move shifts every past point 5%).
// `fx` (today's live rate) is the fallback when no history is available.
function combineValueSeries(tw, us, fx, fxHistory) {
  const twByDate = new Map();
  const usByDate = new Map();
  for (const p of tw || []) twByDate.set(p.date.slice(0, 10), p.total);
  for (const p of us || []) usByDate.set(p.date.slice(0, 10), p.total);
  const rateAt = makeRateLookup(fxHistory, fx);
  const allDates = [...new Set([...twByDate.keys(), ...usByDate.keys()])].sort();
  let lastTw = 0;
  let lastUs = 0;
  return allDates.map((d) => {
    if (twByDate.has(d)) lastTw = twByDate.get(d);
    if (usByDate.has(d)) lastUs = usByDate.get(d);
    const rate = rateAt(d);
    return { date: new Date(d + "T00:00:00Z"), value: lastTw + (rate != null ? lastUs * rate : 0) };
  });
}

// Date → USD/TWD rate, forward-filled. FX has its own calendar (and its series
// can start a few days after the value series), so a date resolves to the most
// recent rate at or before it, then to the earliest known rate, then to today's.
function makeRateLookup(fxHistory, liveRate) {
  const rows = (fxHistory || [])
    .filter((r) => r && r.date && r.rate)
    .sort((a, b) => (a.date < b.date ? -1 : 1));
  if (!rows.length) return () => liveRate ?? null;
  let i = 0;
  let last = rows[0].rate;
  let prevDate = "";
  return (d) => {
    // Callers walk dates in ascending order, so the cursor only moves forward.
    // Rewind fully (cursor AND carried rate) if that assumption is ever broken.
    if (d < prevDate) {
      i = 0;
      last = rows[0].rate;
    }
    prevDate = d;
    while (i < rows.length && rows[i].date <= d) last = rows[i++].rate;
    return last;
  };
}

// Merge the per-currency earnings series into one TWD-denominated total series,
// carrying each currency's last value forward across the union of dates (mirrors
// the iOS TotalEarnedCard logic). Like the net-worth curve, each day's USD leg
// is converted at that day's rate rather than at today's.
function buildEarnedSeries(earnings, fx, fxHistory) {
  if (!earnings) return [];
  const tw = earnings.TWD || [];
  const us = earnings.USD || [];
  const twByDate = new Map();
  const usByDate = new Map();
  for (const p of tw) twByDate.set(p.date.slice(0, 10), p.total);
  for (const p of us) usByDate.set(p.date.slice(0, 10), p.total);
  const rateAt = makeRateLookup(fxHistory, fx);
  const allDates = [...new Set([...twByDate.keys(), ...usByDate.keys()])].sort();
  let lastTw = 0;
  let lastUs = 0;
  return allDates.map((d) => {
    if (twByDate.has(d)) lastTw = twByDate.get(d);
    if (usByDate.has(d)) lastUs = usByDate.get(d);
    const rate = rateAt(d);
    const total = lastTw + (rate != null ? lastUs * rate : 0);
    return { date: new Date(d + "T00:00:00Z"), value: total };
  });
}
