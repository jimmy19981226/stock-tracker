import { useMemo } from "react";
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
import type { HistoryByCurrency } from "../api";
import { fmtMoney } from "../format";

interface Props {
  history: HistoryByCurrency;
}

const CURRENCY_COLORS: Record<string, string> = {
  TWD: "#a78bfa",
  USD: "#6384ff",
};

export function PerformanceChart({ history }: Props) {
  const { rows, currencies } = useMemo(() => {
    const allDates = new Set<string>();
    Object.values(history).forEach((series) =>
      series.forEach((p) => allDates.add(p.date)),
    );
    const dates = Array.from(allDates).sort();
    const currencies = Object.keys(history);
    const rows = dates.map((d) => {
      const row: Record<string, string | number> = { date: d };
      currencies.forEach((c) => {
        const point = history[c].find((p) => p.date === d);
        if (point) row[c] = point.value;
      });
      return row;
    });
    return { rows, currencies };
  }, [history]);

  const empty = rows.length === 0 || currencies.length === 0;

  // Latest value summary across currencies for the chart header
  const latestByCurrency = useMemo(() => {
    return currencies.map((c) => {
      const last = rows.length ? Number(rows[rows.length - 1][c] ?? 0) : 0;
      return { currency: c, value: last };
    });
  }, [currencies, rows]);

  return (
    <div className="panel">
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "flex-start",
          marginBottom: 14,
          gap: 16,
          flexWrap: "wrap",
        }}
      >
        <div>
          <h2 style={{ margin: 0 }}>Cumulative Realized P/L</h2>
          <div
            className="muted"
            style={{ fontSize: 12, marginTop: 6, lineHeight: 1.5 }}
          >
            Lifetime gains locked in from closed positions, by currency.
          </div>
        </div>
        <div
          style={{
            display: "flex",
            gap: 18,
            alignItems: "center",
            flexWrap: "wrap",
          }}
        >
          {latestByCurrency.map(({ currency, value }) => (
            <div
              key={currency}
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
                    background:
                      CURRENCY_COLORS[currency] ?? "#6384ff",
                    display: "inline-block",
                  }}
                />
                {currency}
              </div>
              <div
                style={{
                  fontSize: 18,
                  fontWeight: 700,
                  fontVariantNumeric: "tabular-nums",
                  letterSpacing: "-0.01em",
                  color: value >= 0 ? "var(--green)" : "var(--red)",
                }}
              >
                {fmtMoney(value, currency)}
              </div>
            </div>
          ))}
        </div>
      </div>

      {empty ? (
        <div className="empty">
          Record some sells and we'll plot cumulative realized P/L here.
        </div>
      ) : (
        <ResponsiveContainer width="100%" height={340}>
          <AreaChart
            data={rows}
            margin={{ top: 8, right: 16, left: 0, bottom: 0 }}
          >
            <defs>
              {currencies.map((c) => {
                const color = CURRENCY_COLORS[c] ?? "#6384ff";
                return (
                  <linearGradient
                    key={c}
                    id={`grad-${c}`}
                    x1="0"
                    y1="0"
                    x2="0"
                    y2="1"
                  >
                    <stop offset="0%" stopColor={color} stopOpacity={0.35} />
                    <stop offset="100%" stopColor={color} stopOpacity={0} />
                  </linearGradient>
                );
              })}
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
              contentStyle={{
                background: "#161c27",
                border: "1px solid rgba(255,255,255,0.08)",
                borderRadius: 10,
                fontSize: 12,
                boxShadow: "0 12px 36px -12px rgba(0,0,0,0.6)",
                padding: "10px 14px",
              }}
              labelStyle={{
                color: "#a8b3c7",
                marginBottom: 6,
                fontSize: 11,
                textTransform: "uppercase",
                letterSpacing: "0.06em",
              }}
              itemStyle={{ padding: 0, fontWeight: 600 }}
              formatter={(value: number, name: string) => [
                fmtMoney(value, name),
                name,
              ]}
              cursor={{ stroke: "rgba(255,255,255,0.12)", strokeWidth: 1 }}
            />
            <Legend
              wrapperStyle={{ fontSize: 12, paddingTop: 8 }}
              iconType="circle"
              iconSize={8}
            />
            {currencies.map((c) => {
              const color = CURRENCY_COLORS[c] ?? "#6384ff";
              return (
                <Area
                  key={c}
                  type="monotone"
                  dataKey={c}
                  stroke={color}
                  strokeWidth={2.4}
                  fill={`url(#grad-${c})`}
                  dot={false}
                  activeDot={{
                    r: 5,
                    stroke: color,
                    strokeWidth: 2,
                    fill: "#0c1018",
                  }}
                  connectNulls
                  isAnimationActive
                  animationDuration={600}
                />
              );
            })}
          </AreaChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}
