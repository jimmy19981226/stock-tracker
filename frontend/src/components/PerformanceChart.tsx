import {
  Area,
  AreaChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import type { EarningsByCurrency } from "../api";
import { fmtMoney } from "../format";

interface Props {
  history: EarningsByCurrency;
}

const REALIZED_COLOR = "#6384ff"; // blue
const DIVIDENDS_COLOR = "#fbbf24"; // amber
const TOTAL_COLOR = "#a78bfa"; // purple — used for the latest-value highlight

export function PerformanceChart({ history }: Props) {
  const currencies = Object.keys(history);
  const empty = currencies.length === 0;

  if (empty) {
    return (
      <div className="panel">
        <h2>Cumulative Earnings</h2>
        <div className="empty">
          Record some sells or dividends and we'll plot cumulative earnings here.
        </div>
      </div>
    );
  }

  return (
    <div className="panel">
      <div style={{ marginBottom: 6 }}>
        <h2 style={{ margin: 0 }}>Cumulative Earnings</h2>
        <div
          className="muted"
          style={{ fontSize: 12, marginTop: 6, lineHeight: 1.5 }}
        >
          Realized P/L from closed positions plus all dividend payouts. The
          stack height = total earned.
        </div>
      </div>

      {currencies.map((currency, idx) => {
        const points = history[currency];
        const last = points[points.length - 1];
        const realized = last?.realized ?? 0;
        const dividends = last?.dividends ?? 0;
        const total = last?.total ?? 0;

        return (
          <div
            key={currency}
            style={{
              marginTop: idx === 0 ? 14 : 28,
            }}
          >
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
                  label="Realized"
                  value={fmtMoney(realized, currency)}
                  color={REALIZED_COLOR}
                />
                <Stat
                  label="Dividends"
                  value={fmtMoney(dividends, currency)}
                  color={DIVIDENDS_COLOR}
                />
                <Stat
                  label="Total"
                  value={fmtMoney(total, currency)}
                  color={TOTAL_COLOR}
                  emphasized
                />
              </div>
            </div>

            <ResponsiveContainer width="100%" height={300}>
              <AreaChart
                data={points}
                margin={{ top: 8, right: 16, left: 0, bottom: 0 }}
              >
                <defs>
                  <linearGradient
                    id={`grad-r-${currency}`}
                    x1="0"
                    y1="0"
                    x2="0"
                    y2="1"
                  >
                    <stop
                      offset="0%"
                      stopColor={REALIZED_COLOR}
                      stopOpacity={0.55}
                    />
                    <stop
                      offset="100%"
                      stopColor={REALIZED_COLOR}
                      stopOpacity={0.05}
                    />
                  </linearGradient>
                  <linearGradient
                    id={`grad-d-${currency}`}
                    x1="0"
                    y1="0"
                    x2="0"
                    y2="1"
                  >
                    <stop
                      offset="0%"
                      stopColor={DIVIDENDS_COLOR}
                      stopOpacity={0.55}
                    />
                    <stop
                      offset="100%"
                      stopColor={DIVIDENDS_COLOR}
                      stopOpacity={0.05}
                    />
                  </linearGradient>
                </defs>
                <CartesianGrid
                  strokeDasharray="2 6"
                  stroke="rgba(255,255,255,0.05)"
                  vertical={false}
                />
                <XAxis
                  dataKey="date"
                  tick={{ fontSize: 11, fill: "#6b7589" }}
                  tickLine={false}
                  axisLine={{ stroke: "rgba(255,255,255,0.06)" }}
                  minTickGap={50}
                />
                <YAxis
                  tick={{ fontSize: 11, fill: "#6b7589" }}
                  tickLine={false}
                  axisLine={false}
                  tickFormatter={(v) =>
                    v >= 1_000_000
                      ? `${(v / 1_000_000).toFixed(1)}M`
                      : v >= 1000
                        ? `${(v / 1000).toFixed(0)}k`
                        : `${v}`
                  }
                  width={56}
                />
                <Tooltip
                  content={<EarningsTooltip currency={currency} />}
                  cursor={{
                    stroke: "rgba(255,255,255,0.12)",
                    strokeWidth: 1,
                  }}
                />
                <Legend
                  wrapperStyle={{ fontSize: 12, paddingTop: 8 }}
                  iconType="circle"
                  iconSize={8}
                />
                <Area
                  name="Realized"
                  type="monotone"
                  dataKey="realized"
                  stackId="earnings"
                  stroke={REALIZED_COLOR}
                  strokeWidth={2}
                  fill={`url(#grad-r-${currency})`}
                  isAnimationActive
                  animationDuration={500}
                />
                <Area
                  name="Dividends"
                  type="monotone"
                  dataKey="dividends"
                  stackId="earnings"
                  stroke={DIVIDENDS_COLOR}
                  strokeWidth={2}
                  fill={`url(#grad-d-${currency})`}
                  isAnimationActive
                  animationDuration={500}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        );
      })}
    </div>
  );
}

interface TooltipPayloadItem {
  name?: string;
  dataKey?: string | number;
  value?: number;
  color?: string;
}

function EarningsTooltip({
  active,
  payload,
  label,
  currency,
}: {
  active?: boolean;
  payload?: TooltipPayloadItem[];
  label?: string;
  currency: string;
}) {
  if (!active || !payload || payload.length === 0) return null;

  const realized = payload.find((p) => p.dataKey === "realized")?.value ?? 0;
  const dividends = payload.find((p) => p.dataKey === "dividends")?.value ?? 0;
  const total = realized + dividends;

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
        {label}
      </div>
      <Row label="Realized" value={realized} color={REALIZED_COLOR} currency={currency} />
      <Row
        label="Dividends"
        value={dividends}
        color={DIVIDENDS_COLOR}
        currency={currency}
      />
      <div
        style={{
          height: 1,
          background: "rgba(255,255,255,0.08)",
          margin: "6px 0",
        }}
      />
      <Row
        label="Total"
        value={total}
        color={TOTAL_COLOR}
        currency={currency}
        emphasized
      />
    </div>
  );
}

function Row({
  label,
  value,
  color,
  currency,
  emphasized,
}: {
  label: string;
  value: number;
  color: string;
  currency: string;
  emphasized?: boolean;
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
      <span
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 6,
          color: emphasized ? color : "var(--text)",
          fontWeight: emphasized ? 700 : 500,
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
      </span>
      <span
        style={{
          fontVariantNumeric: "tabular-nums",
          fontWeight: emphasized ? 700 : 600,
          color: emphasized ? color : "var(--text)",
        }}
      >
        {fmtMoney(value, currency)}
      </span>
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
            display: "inline-block",
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
