import {
  Cell,
  Legend,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
} from "recharts";
import type { Holding } from "../api";
import { fmtMoney } from "../format";

interface Props {
  holdings: Holding[];
}

const PALETTE = [
  "#6384ff",
  "#a78bfa",
  "#34d399",
  "#fbbf24",
  "#f472b6",
  "#22d3ee",
  "#fb923c",
  "#60a5fa",
  "#c084fc",
  "#94a3b8",
];

export function AllocationChart({ holdings }: Props) {
  const valued = holdings.filter(
    (h) => h.market_value !== null && h.market_value > 0,
  );

  if (valued.length === 0) {
    return (
      <div className="panel">
        <h2>Allocation</h2>
        <div className="empty">Need price data to show allocation.</div>
      </div>
    );
  }

  // One chart per currency since values aren't comparable across currencies.
  const byCurrency = valued.reduce<Record<string, Holding[]>>((acc, h) => {
    (acc[h.currency] ||= []).push(h);
    return acc;
  }, {});

  return (
    <div className="panel">
      <h2>Allocation</h2>
      {Object.entries(byCurrency).map(([currency, items]) => {
        const data = items.map((h) => ({
          name: h.ticker,
          value: h.market_value as number,
        }));
        return (
          <div key={currency} style={{ marginBottom: 12 }}>
            <div
              className="muted"
              style={{ fontSize: 12, fontWeight: 600, marginBottom: 4 }}
            >
              {currency}
            </div>
            <ResponsiveContainer width="100%" height={220}>
              <PieChart>
                <Pie
                  data={data}
                  dataKey="value"
                  nameKey="name"
                  innerRadius={52}
                  outerRadius={88}
                  paddingAngle={3}
                  stroke="#11161f"
                  strokeWidth={2}
                >
                  {data.map((_, i) => (
                    <Cell key={i} fill={PALETTE[i % PALETTE.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background: "#161c27",
                    border: "1px solid rgba(255,255,255,0.08)",
                    borderRadius: 10,
                    fontSize: 12,
                    boxShadow: "0 12px 36px -12px rgba(0,0,0,0.6)",
                    padding: "8px 12px",
                  }}
                  formatter={(value: number) => fmtMoney(value, currency)}
                />
                <Legend
                  verticalAlign="bottom"
                  height={36}
                  iconSize={10}
                  wrapperStyle={{ fontSize: 12 }}
                />
              </PieChart>
            </ResponsiveContainer>
          </div>
        );
      })}
    </div>
  );
}
