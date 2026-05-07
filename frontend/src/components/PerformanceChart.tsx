import { useMemo, useState } from "react";
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
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
  TWD: "#ffa657",
  USD: "#79c0ff",
};

export function PerformanceChart({ history }: Props) {
  const [hoverCurrency, setHoverCurrency] = useState<string | null>(null);

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

  return (
    <div className="panel">
      <h2>Cumulative Realized P/L</h2>

      {empty ? (
        <div className="empty">
          Record some sells and we'll plot cumulative realized P/L here.
        </div>
      ) : (
        <ResponsiveContainer width="100%" height={320}>
          <LineChart data={rows} margin={{ top: 6, right: 16, left: 0, bottom: 0 }}>
            <CartesianGrid strokeDasharray="2 4" stroke="#2d3744" />
            <XAxis
              dataKey="date"
              tick={{ fontSize: 11, fill: "#8b95a5" }}
              minTickGap={40}
            />
            <YAxis
              tick={{ fontSize: 11, fill: "#8b95a5" }}
              tickFormatter={(v) =>
                v >= 1000 ? `${(v / 1000).toFixed(0)}k` : `${v}`
              }
              width={60}
            />
            <Tooltip
              contentStyle={{
                background: "#1a2028",
                border: "1px solid #2d3744",
                borderRadius: 6,
                fontSize: 12,
              }}
              formatter={(value: number, name: string) => [
                fmtMoney(value, name),
                name,
              ]}
            />
            <Legend
              wrapperStyle={{ fontSize: 12 }}
              onMouseEnter={(o) => setHoverCurrency(String(o.dataKey))}
              onMouseLeave={() => setHoverCurrency(null)}
            />
            {currencies.map((c) => (
              <Line
                key={c}
                type="monotone"
                dataKey={c}
                stroke={CURRENCY_COLORS[c] ?? "#4a9eff"}
                strokeWidth={
                  hoverCurrency === null || hoverCurrency === c ? 2.2 : 1
                }
                dot={false}
                connectNulls
                isAnimationActive={false}
              />
            ))}
          </LineChart>
        </ResponsiveContainer>
      )}
    </div>
  );
}
