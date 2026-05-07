import type { Holding } from "../api";
import { fmtMoney, fmtPct } from "../format";

interface Props {
  holdings: Holding[];
  names?: Record<string, string>;
}

export function UnrealizedChart({ holdings, names = {} }: Props) {
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
          prices, sorted by amount.
        </div>
      </div>

      {Object.entries(byCurrency).map(([currency, items], idx) => {
        const sorted = [...items].sort(
          (a, b) => (b.unrealized_pl || 0) - (a.unrealized_pl || 0),
        );
        const maxAbs =
          Math.max(...sorted.map((h) => Math.abs(h.unrealized_pl || 0))) || 1;
        const totalPl = sorted.reduce(
          (sum, h) => sum + (h.unrealized_pl || 0),
          0,
        );
        const wins = sorted.filter((h) => (h.unrealized_pl || 0) > 0).length;
        const losses = sorted.filter((h) => (h.unrealized_pl || 0) < 0).length;

        return (
          <div key={currency} style={{ marginTop: idx === 0 ? 14 : 28 }}>
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                alignItems: "flex-end",
                marginBottom: 14,
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
                  gap: 22,
                  alignItems: "center",
                  flexWrap: "wrap",
                  fontVariantNumeric: "tabular-nums",
                }}
              >
                <Stat
                  label="Total"
                  value={fmtMoney(totalPl, currency)}
                  color={totalPl >= 0 ? "var(--green)" : "var(--red)"}
                  emphasized
                />
                <Stat label="Winners" value={`${wins}`} color="var(--green)" />
                <Stat label="Losers" value={`${losses}`} color="var(--red)" />
              </div>
            </div>

            <div className="pl-list">
              {sorted.map((h) => {
                const pl = h.unrealized_pl || 0;
                const pct = h.unrealized_pl_pct || 0;
                const positive = pl >= 0;
                const widthPct = (Math.abs(pl) / maxAbs) * 100;
                return (
                  <div className="pl-row" key={h.ticker}>
                    <div className="pl-ticker">
                      <strong>{h.ticker}</strong>
                      {names[h.ticker] && (
                        <span className="muted">{names[h.ticker]}</span>
                      )}
                    </div>
                    <div className="pl-track">
                      <div className="pl-zero-line" />
                      <div
                        className={positive ? "pl-bar pos" : "pl-bar neg"}
                        style={{ width: `calc(${widthPct / 2}% )` }}
                      />
                    </div>
                    <div
                      className="pl-value"
                      style={{ color: positive ? "var(--green)" : "var(--red)" }}
                    >
                      {fmtMoney(pl, currency)}
                    </div>
                    <div
                      className="pl-pct"
                      style={{ color: positive ? "var(--green)" : "var(--red)" }}
                    >
                      {fmtPct(pct)}
                    </div>
                  </div>
                );
              })}
            </div>
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
