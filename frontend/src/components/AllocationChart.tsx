import { Cell, Pie, PieChart, ResponsiveContainer, Tooltip } from "recharts";
import type { Holding } from "../api";
import { fmtMoney } from "../format";

interface Props {
  holdings: Holding[];
  names?: Record<string, string>;
}

const PALETTE = [
  "#4d8bff", // electric blue
  "#7aa9ff", // light blue
  "#38bdf8", // sky
  "#2dd4bf", // teal
  "#34d399", // green
  "#818cf8", // indigo
  "#fbbf24", // amber
  "#60a5fa", // blue
  "#fb7185", // rose
  "#94a3b8", // slate
];
const OTHER_COLOR = "#2a3142";
const TOP_N = 8;
const SMALL_PCT_THRESHOLD = 0.02; // <2% rolls into "Other"

interface Slice {
  name: string;
  value: number;
  color: string;
  pct: number;
  isOther?: boolean;
}

interface AllocTooltipPayloadItem {
  payload?: Slice;
}

function AllocationTooltip({
  active,
  payload,
  currency,
}: {
  active?: boolean;
  payload?: AllocTooltipPayloadItem[];
  currency: string;
}) {
  if (!active || !payload || payload.length === 0 || !payload[0].payload) {
    return null;
  }
  const s = payload[0].payload;
  return (
    <div
      style={{
        background: "#161c27",
        border: "1px solid rgba(255,255,255,0.08)",
        borderRadius: 10,
        fontSize: 12,
        boxShadow: "0 12px 36px -12px rgba(0,0,0,0.6)",
        padding: "10px 14px",
        minWidth: 180,
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          marginBottom: 8,
          fontSize: 11,
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          color: "#a8b3c7",
        }}
      >
        <span
          style={{
            width: 10,
            height: 10,
            borderRadius: 3,
            background: s.color,
          }}
        />
        {s.name}
      </div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          gap: 16,
          padding: "2px 0",
        }}
      >
        <span style={{ color: "var(--text)" }}>Value</span>
        <span
          style={{
            fontVariantNumeric: "tabular-nums",
            fontWeight: 700,
            color: "var(--text)",
          }}
        >
          {fmtMoney(s.value, currency)}
        </span>
      </div>
      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          gap: 16,
          padding: "2px 0",
        }}
      >
        <span style={{ color: "var(--text)" }}>Share</span>
        <span
          style={{
            fontVariantNumeric: "tabular-nums",
            fontWeight: 600,
            color: "var(--accent)",
          }}
        >
          {(s.pct * 100).toFixed(1)}%
        </span>
      </div>
    </div>
  );
}

interface WedgeLabelProps {
  cx?: number;
  cy?: number;
  midAngle?: number;
  innerRadius?: number;
  outerRadius?: number;
  percent?: number;
  name?: string;
}

function renderWedgeLabel(props: WedgeLabelProps) {
  const { cx, cy, midAngle, innerRadius, outerRadius, percent, name } = props;
  if (
    cx === undefined ||
    cy === undefined ||
    midAngle === undefined ||
    innerRadius === undefined ||
    outerRadius === undefined ||
    percent === undefined ||
    !name
  ) {
    return null;
  }
  // Only label wedges that have room — otherwise text overlaps neighbors.
  if (percent < 0.05) return null;
  const RADIAN = Math.PI / 180;
  const radius = innerRadius + (outerRadius - innerRadius) * 0.55;
  const x = cx + radius * Math.cos(-midAngle * RADIAN);
  const y = cy + radius * Math.sin(-midAngle * RADIAN);
  // Compact "Other" label — full count is in the legend below.
  const displayName = name.startsWith("Other") ? "Other" : name;
  // Two-line label: ticker on top, percentage below.
  return (
    <text
      x={x}
      y={y}
      fill="#0e0e1c"
      textAnchor="middle"
      dominantBaseline="central"
      fontWeight={700}
      style={{ pointerEvents: "none" }}
    >
      <tspan x={x} dy="-0.4em" fontSize={12}>
        {displayName}
      </tspan>
      <tspan x={x} dy="1.25em" fontSize={10} fillOpacity={0.65}>
        {(percent * 100).toFixed(percent >= 0.1 ? 0 : 1)}%
      </tspan>
    </text>
  );
}

function groupSmall(items: Holding[]): Slice[] {
  const total = items.reduce((s, h) => s + (h.market_value || 0), 0);
  const sorted = [...items].sort(
    (a, b) => (b.market_value || 0) - (a.market_value || 0),
  );

  const slices: Slice[] = [];
  let otherValue = 0;
  let otherCount = 0;
  for (let i = 0; i < sorted.length; i++) {
    const h = sorted[i];
    const v = h.market_value || 0;
    const pct = total > 0 ? v / total : 0;
    if (i < TOP_N && pct >= SMALL_PCT_THRESHOLD) {
      slices.push({
        name: h.ticker,
        value: v,
        color: PALETTE[slices.length % PALETTE.length],
        pct,
      });
    } else {
      otherValue += v;
      otherCount += 1;
    }
  }
  if (otherValue > 0) {
    slices.push({
      name: `Other · ${otherCount}`,
      value: otherValue,
      color: OTHER_COLOR,
      pct: total > 0 ? otherValue / total : 0,
      isOther: true,
    });
  }
  return slices;
}

export function AllocationChart({ holdings, names = {} }: Props) {
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

  const byCurrency = valued.reduce<Record<string, Holding[]>>((acc, h) => {
    (acc[h.currency] ||= []).push(h);
    return acc;
  }, {});

  return (
    <div className="panel">
      <h2>Allocation · Open Positions</h2>
      {Object.entries(byCurrency).map(([currency, items]) => {
        const slices = groupSmall(items);
        const total = items.reduce((s, h) => s + (h.market_value || 0), 0);
        return (
          <div key={currency} style={{ marginBottom: 8 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "baseline",
                marginBottom: 8,
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
                {currency} · {items.length} positions
              </div>
              <div
                style={{
                  fontSize: 13,
                  fontWeight: 700,
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                {fmtMoney(total, currency)}
              </div>
            </div>

            <ResponsiveContainer width="100%" height={300}>
              <PieChart>
                <Pie
                  data={slices}
                  dataKey="value"
                  nameKey="name"
                  innerRadius="56%"
                  outerRadius="86%"
                  paddingAngle={2}
                  stroke="#16162b"
                  strokeWidth={2}
                  isAnimationActive={false}
                  label={renderWedgeLabel}
                  labelLine={false}
                >
                  {slices.map((s, i) => (
                    <Cell key={i} fill={s.color} />
                  ))}
                </Pie>
                <Tooltip content={<AllocationTooltip currency={currency} />} />
                {/* Center label inside the donut hole */}
                <text
                  x="50%"
                  y="50%"
                  textAnchor="middle"
                  dominantBaseline="central"
                  style={{ pointerEvents: "none" }}
                >
                  <tspan
                    x="50%"
                    dy="-0.6em"
                    fontSize={10}
                    fontWeight={700}
                    fill="#74769b"
                    style={{ letterSpacing: "0.1em" }}
                  >
                    TOTAL
                  </tspan>
                  <tspan
                    x="50%"
                    dy="1.6em"
                    fontSize={16}
                    fontWeight={700}
                    fill="#f3f2ff"
                  >
                    {fmtMoney(total, currency)}
                  </tspan>
                </text>
              </PieChart>
            </ResponsiveContainer>

            <ul className="alloc-legend">
              {slices.map((s) => {
                const fullName = !s.isOther ? names[s.name] : "";
                return (
                  <li key={s.name}>
                    <span
                      className="alloc-dot"
                      style={{ background: s.color }}
                    />
                    <span
                      className="alloc-name"
                      style={{
                        color: s.isOther ? "var(--muted)" : "var(--text)",
                      }}
                    >
                      {s.name}
                      {fullName && (
                        <span
                          className="muted"
                          style={{ marginLeft: 6, fontWeight: 400 }}
                        >
                          {fullName}
                        </span>
                      )}
                    </span>
                    <span className="alloc-pct">
                      {(s.pct * 100).toFixed(1)}%
                    </span>
                    <span className="alloc-val">
                      {fmtMoney(s.value, currency)}
                    </span>
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}
    </div>
  );
}
