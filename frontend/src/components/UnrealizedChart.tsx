import {
  Bar,
  BarChart,
  Cell,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { Holding } from "../api";
import { fmtMoney, fmtPct } from "../format";

interface Props {
  holdings: Holding[];
}

const POS = "#34d399";
const NEG = "#f87171";

export function UnrealizedChart({ holdings }: Props) {
  const open = holdings.filter(
    (h) => h.shares > 0 && h.unrealized_pl !== null,
  );

  if (open.length === 0) {
    return (
      <div className="panel">
        <h2>Unrealized P/L by Position</h2>
        <div className="empty">No open positions yet.</div>
      </div>
    );
  }

  const byCurrency = open.reduce<Record<string, Holding[]>>((acc, h) => {
    (acc[h.currency] ||= []).push(h);
    return acc;
  }, {});

  return (
    <div className="panel">
      <div style={{ marginBottom: 6 }}>
        <h2 style={{ margin: 0 }}>Unrealized P/L by Position</h2>
        <div
          className="muted"
          style={{ fontSize: 12, marginTop: 6, lineHeight: 1.5 }}
        >
          Live paper gain or loss on each open holding at current market
          prices. Sorted by amount.
        </div>
      </div>

      {Object.entries(byCurrency).map(([currency, items], idx) => {
        const sorted = [...items].sort(
          (a, b) => (b.unrealized_pl || 0) - (a.unrealized_pl || 0),
        );
        const data = sorted.map((h) => ({
          ticker: h.ticker,
          pl: h.unrealized_pl || 0,
          pct: h.unrealized_pl_pct || 0,
          mv: h.market_value || 0,
          cost: h.cost_basis,
        }));
        const totalPl = sorted.reduce(
          (sum, h) => sum + (h.unrealized_pl || 0),
          0,
        );
        const wins = sorted.filter((h) => (h.unrealized_pl || 0) > 0).length;
        const losses = sorted.filter((h) => (h.unrealized_pl || 0) < 0).length;
        const height = Math.max(220, sorted.length * 28 + 40);

        return (
          <div key={currency} style={{ marginTop: idx === 0 ? 14 : 28 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "flex-end",
                marginBottom: 8,
                gap: 16,
                flexWrap: "wrap",
              }}
            >
              <div
                className="muted"
                style={{
                  fontSize: 11,
                  fontWeight: 700,
                  textTransform: "uppercase",
                  letterSpacing: "0.1em",
                }}
              >
                {currency}
              </div>
              <div
                style={{
                  display: "flex",
                  gap: 18,
                  alignItems: "center",
                  flexWrap: "wrap",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                <Stat
                  label="Total"
                  value={fmtMoney(totalPl, currency)}
                  color={totalPl >= 0 ? POS : NEG}
                  emphasized
                />
                <Stat label="Winners" value={`${wins}`} color={POS} />
                <Stat label="Losers" value={`${losses}`} color={NEG} />
              </div>
            </div>

            <ResponsiveContainer width="100%" height={height}>
              <BarChart
                data={data}
                layout="vertical"
                margin={{ top: 8, right: 24, left: 0, bottom: 0 }}
              >
                <XAxis
                  type="number"
                  tick={{ fontSize: 11, fill: "#6b7589" }}
                  tickLine={false}
                  axisLine={{ stroke: "rgba(255,255,255,0.06)" }}
                  tickFormatter={(v) =>
                    Math.abs(v) >= 1_000_000
                      ? `${(v / 1_000_000).toFixed(1)}M`
                      : Math.abs(v) >= 1000
                        ? `${(v / 1000).toFixed(0)}k`
                        : `${v}`
                  }
                />
                <YAxis
                  type="category"
                  dataKey="ticker"
                  tick={{ fontSize: 12, fill: "#a8b3c7", fontWeight: 600 }}
                  tickLine={false}
                  axisLine={false}
                  width={64}
                />
                <ReferenceLine
                  x={0}
                  stroke="rgba(255,255,255,0.18)"
                  strokeWidth={1}
                />
                <Tooltip
                  content={<UnrealizedTooltip currency={currency} />}
                  cursor={{ fill: "rgba(255,255,255,0.04)" }}
                />
                <Bar
                  dataKey="pl"
                  radius={[0, 4, 4, 0]}
                  isAnimationActive
                  animationDuration={500}
                >
                  {data.map((d, i) => (
                    <Cell key={i} fill={d.pl >= 0 ? POS : NEG} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        );
      })}
    </div>
  );
}

function Stat({
  label,
  value,
  color,
  emphasized,
}: {
  label: string;
  value: string;
  color: string;
  emphasized?: boolean;
}) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "flex-end",
      }}
    >
      <div
        className="muted"
        style={{
          fontSize: 10,
          textTransform: "uppercase",
          letterSpacing: "0.1em",
          fontWeight: 700,
          display: "flex",
          alignItems: "center",
          gap: 6,
        }}
      >
        <span
          style={{
            width: 8,
            height: 8,
            borderRadius: 2,
            background: color,
          }}
        />
        {label}
      </div>
      <div
        style={{
          fontSize: emphasized ? 20 : 16,
          fontWeight: 700,
          letterSpacing: "-0.01em",
          color: emphasized ? color : "var(--text)",
        }}
      >
        {value}
      </div>
    </div>
  );
}

interface TooltipPayloadItem {
  payload?: {
    ticker: string;
    pl: number;
    pct: number;
    mv: number;
    cost: number;
  };
}

function UnrealizedTooltip({
  active,
  payload,
  currency,
}: {
  active?: boolean;
  payload?: TooltipPayloadItem[];
  currency: string;
}) {
  if (!active || !payload || payload.length === 0 || !payload[0].payload) {
    return null;
  }
  const d = payload[0].payload;
  return (
    <div
      style={{
        background: "#161c27",
        border: "1px solid rgba(255,255,255,0.08)",
        borderRadius: 10,
        fontSize: 12,
        boxShadow: "0 12px 36px -12px rgba(0,0,0,0.6)",
        padding: "10px 14px",
        minWidth: 200,
      }}
    >
      <div
        style={{
          color: "#a8b3c7",
          marginBottom: 8,
          fontSize: 11,
          textTransform: "uppercase",
          letterSpacing: "0.06em",
        }}
      >
        {d.ticker}
      </div>
      <Row label="P/L" value={fmtMoney(d.pl, currency)} color={d.pl >= 0 ? POS : NEG} bold />
      <Row label="Return" value={fmtPct(d.pct)} color={d.pct >= 0 ? POS : NEG} />
      <div style={{ height: 1, background: "rgba(255,255,255,0.08)", margin: "6px 0" }} />
      <Row label="Market Value" value={fmtMoney(d.mv, currency)} />
      <Row label="Cost Basis" value={fmtMoney(d.cost, currency)} />
    </div>
  );
}

function Row({
  label,
  value,
  color,
  bold,
}: {
  label: string;
  value: string;
  color?: string;
  bold?: boolean;
}) {
  return (
    <div
      style={{
        display: "flex",
        justifyContent: "space-between",
        alignItems: "center",
        gap: 16,
        padding: "2px 0",
      }}
    >
      <span style={{ color: "var(--text)" }}>{label}</span>
      <span
        style={{
          fontVariantNumeric: "tabular-nums",
          fontWeight: bold ? 700 : 600,
          color: color ?? "var(--text)",
        }}
      >
        {value}
      </span>
    </div>
  );
}
