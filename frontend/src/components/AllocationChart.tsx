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
  "#4a9eff",
  "#ffa657",
  "#3fb950",
  "#bc8cff",
  "#f85149",
  "#79c0ff",
  "#ffd166",
  "#39d0d8",
  "#e377c2",
  "#9aa6b2",
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
                  innerRadius={50}
                  outerRadius={85}
                  paddingAngle={2}
                  stroke="#1a2028"
                >
                  {data.map((_, i) => (
                    <Cell key={i} fill={PALETTE[i % PALETTE.length]} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    background: "#1a2028",
                    border: "1px solid #2d3744",
                    borderRadius: 6,
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
