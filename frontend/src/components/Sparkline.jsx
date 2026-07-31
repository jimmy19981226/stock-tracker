import React, { useId, useMemo, useState } from "react";

// Dependency-free responsive line+area chart with hover/touch scrubbing.
// `data` is [{ date: Date, value: number }]. Renders nothing for < 2 points.
//
// Single series, so there's no legend — the card title names what's plotted.
// Mark specs follow the house chart rules: 2px line, ~10% area wash, an 8px
// end marker ringed in the surface colour, and hairline solid gridlines one
// step off the surface. The min/max and date range are labelled directly so
// every value is readable WITHOUT hovering — the tooltip enhances, it never
// gates.
export default function Sparkline({ data, height = 190, formatValue, formatScale, formatDate }) {
  const gradId = useId();
  const [hover, setHover] = useState(null); // index under the cursor
  const W = 1000; // viewBox width (scales to container via CSS)
  const H = height;
  const PAD = 8;

  const geom = useMemo(() => {
    if (!data || data.length < 2) return null;
    const xs = data.map((d) => d.date.getTime());
    const ys = data.map((d) => d.value);
    const minX = Math.min(...xs);
    const maxX = Math.max(...xs);
    const minY = Math.min(...ys);
    const maxY = Math.max(...ys);
    const spanX = maxX - minX || 1;
    const spanY = maxY - minY || 1;
    const px = (t) => PAD + ((t - minX) / spanX) * (W - 2 * PAD);
    const py = (v) => H - PAD - ((v - minY) / spanY) * (H - 2 * PAD);
    const pts = data.map((d) => [px(d.date.getTime()), py(d.value)]);
    const line = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(" ");
    const area = `${line} L${pts[pts.length - 1][0].toFixed(1)},${H - PAD} L${pts[0][0].toFixed(1)},${H - PAD} Z`;
    // Three recessive gridlines. Solid hairlines, never dashed.
    const grid = [0.25, 0.5, 0.75].map((f) => PAD + f * (H - 2 * PAD));
    return { pts, line, area, minY, maxY, grid };
  }, [data, H]);

  if (!geom) return null;

  const up = data[data.length - 1].value >= data[0].value;
  const stroke = up ? "var(--up)" : "var(--down)";
  const active = hover != null ? data[hover] : null;
  const activePt = hover != null ? geom.pts[hover] : null;
  const endPt = geom.pts[geom.pts.length - 1];

  function pickNearest(clientX, target) {
    const rect = target.getBoundingClientRect();
    const x = ((clientX - rect.left) / rect.width) * W;
    let best = 0;
    let bestD = Infinity;
    geom.pts.forEach((p, i) => {
      const d = Math.abs(p[0] - x);
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    });
    setHover(best);
  }

  const fmtV = (v) => (formatValue ? formatValue(v) : String(v));
  const fmtD = (d) => (formatDate ? formatDate(d) : "");
  // The gutter gets a compact form when one is supplied; the tooltip always
  // shows the full-precision value.
  const fmtS = (v) => (formatScale ? formatScale(v) : fmtV(v));

  return (
    <div className="spark">
      {active && (
        <div
          className="spark-tip"
          role="status"
          // Clamped so the tooltip never hangs off either edge of the card.
          style={{ left: `${Math.min(88, Math.max(12, (activePt[0] / W) * 100))}%` }}
        >
          <span className="spark-tip-val">{fmtV(active.value)}</span>
          <span className="spark-tip-date">{fmtD(active.date)}</span>
        </div>
      )}

      {/* The scale lives in its own gutter beside the plot, never on top of
          it — a label overlapping the line was the first thing that broke when
          this was rendered. */}
      <div className="spark-plot">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        className="spark-svg"
        role="img"
        aria-label={`Trend from ${fmtV(data[0].value)} to ${fmtV(data[data.length - 1].value)}`}
        onMouseMove={(e) => pickNearest(e.clientX, e.currentTarget)}
        onMouseLeave={() => setHover(null)}
        onTouchStart={(e) => pickNearest(e.touches[0].clientX, e.currentTarget)}
        onTouchMove={(e) => pickNearest(e.touches[0].clientX, e.currentTarget)}
        onTouchEnd={() => setHover(null)}
      >
        <defs>
          <linearGradient id={gradId} x1="0" y1="0" x2="0" y2="1">
            {/* ~10% wash, not a saturated block. */}
            <stop offset="0%" stopColor={stroke} stopOpacity="0.16" />
            <stop offset="100%" stopColor={stroke} stopOpacity="0" />
          </linearGradient>
        </defs>

        {geom.grid.map((y) => (
          <line
            key={y}
            x1="0"
            y1={y}
            x2={W}
            y2={y}
            stroke="var(--stroke-soft)"
            strokeWidth="1"
            vectorEffect="non-scaling-stroke"
          />
        ))}

        <path d={geom.area} fill={`url(#${gradId})`} />
        <path
          d={geom.line}
          fill="none"
          stroke={stroke}
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          vectorEffect="non-scaling-stroke"
        />

        {/* End marker: 8px, ringed in the surface colour so it stays legible
            wherever the line ends. Hidden while scrubbing so there's only ever
            one focal dot. */}
        {!activePt && (
          <circle cx={endPt[0]} cy={endPt[1]} r="4" fill={stroke}
                  stroke="var(--card)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
        )}

        {activePt && (
          <>
            <line
              x1={activePt[0]} y1={PAD} x2={activePt[0]} y2={H - PAD}
              stroke="var(--muted)" strokeWidth="1"
              vectorEffect="non-scaling-stroke" strokeOpacity="0.45"
            />
            <circle cx={activePt[0]} cy={activePt[1]} r="4.5" fill={stroke}
                    stroke="var(--card)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
          </>
        )}
      </svg>
        <div className="spark-scale" aria-hidden="true">
          <span>{fmtS(geom.maxY)}</span>
          <span>{fmtS(geom.minY)}</span>
        </div>
      </div>

      <div className="spark-dates">
        <span>{fmtD(data[0].date)}</span>
        <span>{fmtD(data[data.length - 1].date)}</span>
      </div>
    </div>
  );
}
