import { useEffect, useMemo, useState } from "react";
import {
  CartesianGrid,
  ComposedChart,
  Line,
  ReferenceDot,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { api, type HistoryPeriod, type StockDetail } from "../api";
import { fmtMoney, fmtNumber, fmtPct, plClass } from "../format";

interface Props {
  ticker: string;
  onClose: () => void;
}

const PERIODS: { label: string; value: HistoryPeriod }[] = [
  { label: "1M", value: "1mo" },
  { label: "3M", value: "3mo" },
  { label: "6M", value: "6mo" },
  { label: "1Y", value: "1y" },
  { label: "2Y", value: "2y" },
  { label: "5Y", value: "5y" },
  { label: "All", value: "max" },
];

export function StockDetail({ ticker, onClose }: Props) {
  const [period, setPeriod] = useState<HistoryPeriod>("1y");
  const [data, setData] = useState<StockDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showTaiex, setShowTaiex] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    api
      .getStockDetail(ticker, period)
      .then((d) => {
        if (!cancelled) {
          setData(d);
          setLoading(false);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : "Failed to load");
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [ticker, period]);

  // Close on Escape
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal stock-modal" onClick={(e) => e.stopPropagation()}>
        <header className="stock-modal-header">
          <div>
            <div style={{ display: "flex", alignItems: "baseline", gap: 12 }}>
              <h2 style={{ margin: 0 }}>{ticker}</h2>
              {data?.name && (
                <span className="muted" style={{ fontSize: 14 }}>
                  {data.name}
                </span>
              )}
              {data?.fundamentals?.sector && (
                <span className="tag" style={{ marginLeft: 4 }}>
                  {data.fundamentals.sector}
                </span>
              )}
            </div>
            {data?.fundamentals?.long_name && (
              <div className="muted" style={{ fontSize: 11, marginTop: 4 }}>
                {data.fundamentals.long_name}
              </div>
            )}
          </div>
          <button
            type="button"
            className="secondary assistant-close"
            onClick={onClose}
            aria-label="Close"
            title="Close (Esc)"
          >
            ✕
          </button>
        </header>

        {loading && <div className="empty" style={{ padding: 32 }}>Loading…</div>}
        {error && <div className="error">{error}</div>}

        {data && !loading && (
          <div className="stock-modal-body">
            <PriceRow detail={data} />
            {data.position && <PositionCard detail={data} />}
            <FundamentalsGrid detail={data} />

            <div className="stock-section">
              <div className="stock-section-header">
                <h3>Price history</h3>
                <div className="stock-period-tabs">
                  {PERIODS.map((p) => (
                    <button
                      key={p.value}
                      type="button"
                      className={`secondary ${period === p.value ? "active" : ""}`}
                      onClick={() => setPeriod(p.value)}
                    >
                      {p.label}
                    </button>
                  ))}
                  <label
                    className="muted"
                    style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 6,
                      fontSize: 11,
                      marginLeft: 12,
                    }}
                  >
                    <input
                      type="checkbox"
                      checked={showTaiex}
                      onChange={(e) => setShowTaiex(e.target.checked)}
                    />
                    vs TAIEX
                  </label>
                </div>
              </div>
              <PriceChart detail={data} showTaiex={showTaiex} />
            </div>

            {(data.trades.length > 0 || data.dividends.length > 0) && (
              <div className="stock-section">
                <h3>Activity</h3>
                <ActivityList detail={data} />
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function PriceRow({ detail }: { detail: StockDetail }) {
  const { live } = detail;
  const dayRange =
    live.day_low != null && live.day_high != null
      ? `${live.day_low.toFixed(2)} – ${live.day_high.toFixed(2)}`
      : "—";
  return (
    <div className="stock-price-row">
      <div>
        <div className="muted micro-label">Last price</div>
        <div className="stock-price">{fmtMoney(live.price, "TWD")}</div>
        <div className={`sub ${plClass(live.today_change)}`} style={{ fontSize: 13 }}>
          {live.today_change != null
            ? `${live.today_change > 0 ? "+" : ""}${live.today_change.toFixed(2)}`
            : "—"}{" "}
          ({fmtPct(live.today_change_pct)})
        </div>
      </div>
      <Stat label="Open" value={fmtMoney(live.day_open, "TWD")} />
      <Stat label="Day range" value={dayRange} />
      <Stat label="Bid / Ask" value={`${fmtMoney(live.bid, "TWD")} / ${fmtMoney(live.ask, "TWD")}`} />
      <Stat
        label="Volume"
        value={live.volume != null ? live.volume.toLocaleString() : "—"}
      />
    </div>
  );
}

function PositionCard({ detail }: { detail: StockDetail }) {
  const p = detail.position!;
  return (
    <div className="stock-section stock-position-card">
      <h3>Your position</h3>
      <div className="stock-stat-grid">
        <Stat label="Shares" value={fmtNumber(p.shares, 4)} />
        <Stat label="Avg cost" value={fmtMoney(p.avg_cost, "TWD")} />
        <Stat label="Cost basis" value={fmtMoney(p.cost_basis, "TWD")} />
        <Stat label="Market value" value={fmtMoney(p.market_value, "TWD")} />
        <Stat
          label="Unrealized P/L"
          value={fmtMoney(p.unrealized_pl, "TWD")}
          className={plClass(p.unrealized_pl)}
          sub={fmtPct(p.unrealized_pl_pct)}
        />
        <Stat
          label="Realized P/L"
          value={fmtMoney(p.realized_pl, "TWD")}
          className={plClass(p.realized_pl)}
        />
        <Stat label="Dividends received" value={fmtMoney(p.dividends_received, "TWD")} />
        <Stat
          label="Total return"
          value={fmtMoney(p.total_return, "TWD")}
          className={plClass(p.total_return)}
          sub={fmtPct(p.total_return_pct)}
        />
        <Stat
          label="Yield on cost (1y)"
          value={detail.yield_on_cost != null ? fmtPct(detail.yield_on_cost) : "—"}
        />
        <Stat
          label="Holding period"
          value={
            p.holding_days != null
              ? p.holding_days < 60
                ? `${p.holding_days}d`
                : p.holding_days < 730
                  ? `${Math.floor(p.holding_days / 30)}mo`
                  : `${(p.holding_days / 365).toFixed(1)}y`
              : "—"
          }
          sub={p.first_buy_date ?? undefined}
        />
        <Stat label="Trades" value={p.trade_count.toString()} />
        <Stat label="Fees paid" value={fmtMoney(p.fees_paid, "TWD")} />
      </div>
    </div>
  );
}

function FundamentalsGrid({ detail }: { detail: StockDetail }) {
  const f = detail.fundamentals;
  if (!f || Object.values(f).every((v) => v == null)) {
    return null;
  }
  const fmtMcap = (v: number | null | undefined) => {
    if (v == null) return "—";
    if (v >= 1e12) return `NT$${(v / 1e12).toFixed(2)} T`;
    if (v >= 1e9) return `NT$${(v / 1e9).toFixed(2)} B`;
    if (v >= 1e6) return `NT$${(v / 1e6).toFixed(2)} M`;
    return fmtMoney(v, "TWD");
  };
  return (
    <div className="stock-section">
      <h3>Market data</h3>
      <div className="stock-stat-grid">
        <Stat label="Market cap" value={fmtMcap(f.market_cap)} />
        <Stat
          label="P/E (TTM)"
          value={f.pe != null ? f.pe.toFixed(2) : "—"}
        />
        <Stat
          label="EPS (TTM)"
          value={f.eps != null ? `NT$${f.eps.toFixed(2)}` : "—"}
        />
        <Stat
          label="Dividend yield"
          value={
            f.dividend_yield != null
              ? `${(f.dividend_yield * 100).toFixed(2)}%`
              : "—"
          }
        />
        <Stat
          label="52-week high"
          value={fmtMoney(f.fifty_two_week_high ?? null, "TWD")}
        />
        <Stat
          label="52-week low"
          value={fmtMoney(f.fifty_two_week_low ?? null, "TWD")}
        />
        <Stat
          label="50-day avg"
          value={fmtMoney(f.fifty_day_avg ?? null, "TWD")}
        />
        <Stat
          label="200-day avg"
          value={fmtMoney(f.two_hundred_day_avg ?? null, "TWD")}
        />
        <Stat
          label="Beta"
          value={f.beta != null ? f.beta.toFixed(2) : "—"}
        />
        <Stat
          label="P/B"
          value={f.price_to_book != null ? f.price_to_book.toFixed(2) : "—"}
        />
        <Stat
          label="Industry"
          value={f.industry ?? "—"}
        />
      </div>
    </div>
  );
}

function PriceChart({
  detail,
  showTaiex,
}: {
  detail: StockDetail;
  showTaiex: boolean;
}) {
  const chartData = useMemo(() => {
    const taiexByDate = new Map(
      detail.taiex_history.map((b) => [b.date, b.close]),
    );
    return detail.history.map((b) => ({
      date: b.date,
      close: b.close,
      taiex: taiexByDate.get(b.date) ?? null,
    }));
  }, [detail.history, detail.taiex_history]);

  // Normalize TAIEX to the same starting price as the stock so they overlay
  // visually. Compute scale = first stock close / first taiex close.
  const taiexScaled = useMemo(() => {
    const firstStock = chartData.find((d) => d.close != null)?.close;
    const firstTaiex = chartData.find((d) => d.taiex != null)?.taiex;
    if (!firstStock || !firstTaiex) return chartData;
    const scale = firstStock / firstTaiex;
    return chartData.map((d) => ({
      ...d,
      taiex_scaled: d.taiex != null ? d.taiex * scale : null,
    }));
  }, [chartData]);

  if (chartData.length === 0) {
    return (
      <div className="empty" style={{ height: 320 }}>
        No price history available for this period.
      </div>
    );
  }

  return (
    <div style={{ width: "100%", height: 360 }}>
      <ResponsiveContainer>
        <ComposedChart data={taiexScaled} margin={{ top: 16, right: 24, left: 0, bottom: 8 }}>
          <CartesianGrid stroke="rgba(255,255,255,0.05)" strokeDasharray="2 6" />
          <XAxis
            dataKey="date"
            tick={{ fill: "#6b7589", fontSize: 11 }}
            tickFormatter={(d) => d.slice(5)}
            minTickGap={32}
          />
          <YAxis
            tick={{ fill: "#6b7589", fontSize: 11 }}
            tickFormatter={(v) =>
              v >= 1000 ? `${(v / 1000).toFixed(1)}k` : v.toFixed(0)
            }
            domain={["auto", "auto"]}
          />
          <Tooltip
            contentStyle={{
              background: "#11161f",
              border: "1px solid rgba(255,255,255,0.1)",
              borderRadius: 8,
              fontSize: 12,
            }}
            labelStyle={{ color: "#e8ecf2" }}
            formatter={(value, name) => {
              const v = typeof value === "number" ? value : null;
              if (v == null) return ["—", name as string];
              return [
                name === "TAIEX (scaled)"
                  ? v.toFixed(2)
                  : `NT$${v.toFixed(2)}`,
                name as string,
              ];
            }}
          />
          <Line
            type="monotone"
            dataKey="close"
            name={detail.ticker}
            stroke="#6384ff"
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4 }}
          />
          {showTaiex && (
            <Line
              type="monotone"
              dataKey="taiex_scaled"
              name="TAIEX (scaled)"
              stroke="#a78bfa"
              strokeDasharray="4 3"
              strokeWidth={1.5}
              dot={false}
              connectNulls
            />
          )}
          {detail.trades.map((t, i) => (
            <ReferenceDot
              key={`t-${i}`}
              x={t.date}
              y={t.price}
              r={6}
              fill={t.type === "buy" ? "#34d399" : "#f87171"}
              stroke="white"
              strokeWidth={1.5}
              ifOverflow="extendDomain"
            />
          ))}
          {detail.dividends.map((d, i) => {
            const onDate = chartData.find((b) => b.date === d.date);
            if (!onDate || onDate.close == null) return null;
            return (
              <ReferenceDot
                key={`d-${i}`}
                x={d.date}
                y={onDate.close}
                r={4}
                fill="#fbbf24"
                stroke="white"
                strokeWidth={1.2}
                ifOverflow="extendDomain"
              />
            );
          })}
        </ComposedChart>
      </ResponsiveContainer>
      <div
        className="muted"
        style={{
          fontSize: 11,
          marginTop: 6,
          display: "flex",
          gap: 16,
          justifyContent: "center",
          flexWrap: "wrap",
        }}
      >
        <LegendDot color="#6384ff" /> Price
        <LegendDot color="#34d399" /> Buy
        <LegendDot color="#f87171" /> Sell
        <LegendDot color="#fbbf24" /> Dividend
        {showTaiex && (
          <>
            <LegendDot color="#a78bfa" /> TAIEX (scaled to start)
          </>
        )}
      </div>
    </div>
  );
}

function ActivityList({ detail }: { detail: StockDetail }) {
  type Row = { date: string; kind: "buy" | "sell" | "div"; text: string };
  const rows: Row[] = [];
  for (const t of detail.trades) {
    rows.push({
      date: t.date,
      kind: t.type,
      text: `${t.type.toUpperCase()} ${t.shares} shares @ NT$${t.price.toFixed(2)}${
        t.fee ? ` · fee NT$${t.fee.toFixed(0)}` : ""
      }${t.notes ? ` · ${t.notes}` : ""}`,
    });
  }
  for (const d of detail.dividends) {
    rows.push({
      date: d.date,
      kind: "div",
      text: `Dividend NT$${d.amount.toFixed(2)}${d.notes ? ` · ${d.notes}` : ""}`,
    });
  }
  rows.sort((a, b) => (a.date < b.date ? 1 : -1));

  if (rows.length === 0) {
    return <div className="empty" style={{ padding: 16 }}>No activity yet.</div>;
  }

  return (
    <div className="stock-activity-list">
      {rows.map((r, i) => (
        <div key={i} className={`stock-activity-row stock-activity-${r.kind}`}>
          <span className="stock-activity-date">{r.date}</span>
          <span className="stock-activity-text">{r.text}</span>
        </div>
      ))}
    </div>
  );
}

function Stat({
  label,
  value,
  sub,
  className,
}: {
  label: string;
  value: string;
  sub?: string;
  className?: string;
}) {
  return (
    <div className="stock-stat">
      <div className="micro-label">{label}</div>
      <div className={`stock-stat-value ${className ?? ""}`}>{value}</div>
      {sub && <div className={`muted ${className ?? ""}`} style={{ fontSize: 11 }}>{sub}</div>}
    </div>
  );
}

function LegendDot({ color }: { color: string }) {
  return (
    <span
      style={{
        display: "inline-block",
        width: 8,
        height: 8,
        borderRadius: 4,
        background: color,
        marginRight: 4,
        verticalAlign: "middle",
      }}
    />
  );
}
