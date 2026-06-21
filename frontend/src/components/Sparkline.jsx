import React, { useId, useMemo, useState } from "react";

// Dependency-free responsive line+area chart with optional hover scrubbing.
// `data` is [{ date: Date, value: number }]. Renders nothing for < 2 points.
export default function Sparkline({ data, height = 180, formatValue, formatDate }) {
  const gradId = useId();
  const [hover, setHover] = useState(null); // index under the cursor
  const W = 1000; // viewBox width (scales to container via CSS)
  const H = height;
  const PAD = 6;

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
    return { pts, line, area };
  }, [data, H]);

  if (!geom) return null;

  const up = data[data.length - 1].value >= data[0].value;
  const stroke = up ? "var(--up)" : "var(--down)";
  const active = hover != null ? data[hover] : null;
  const activePt = hover != null ? geom.pts[hover] : null;

  function onMove(e) {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * W;
    // nearest point by x
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

  return (
    <div className="spark">
      {active && (
        <div className="spark-tip" role="status">
          <span className="spark-tip-val">{formatValue ? formatValue(active.value) : active.value}</span>
          <span className="spark-tip-date">{formatDate ? formatDate(active.date) : ""}</span>
        </div>
      )}
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        className="spark-svg"
        onMouseMove={onMove}
        onMouseLeave={() => setHover(null)}
        onTouchStart={(e) => onMove(e.touches ? { ...e, clientX: e.touches[0].clientX, currentTarget: e.currentTarget } : e)}
        onTouchMove={(e) => onMove({ clientX: e.touches[0].clientX, currentTarget: e.currentTarget })}
        onTouchEnd={() => setHover(null)}
      >
        <defs>
          <linearGradient id={gradId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={stroke} stopOpacity="0.22" />
            <stop offset="100%" stopColor={stroke} stopOpacity="0" />
          </linearGradient>
        </defs>
        <path d={geom.area} fill={`url(#${gradId})`} />
        <path d={geom.line} fill="none" stroke={stroke} strokeWidth="2.5" vectorEffect="non-scaling-stroke" />
        {activePt && (
          <>
            <line x1={activePt[0]} y1={PAD} x2={activePt[0]} y2={H - PAD} stroke="var(--muted)" strokeWidth="1" vectorEffect="non-scaling-stroke" strokeOpacity="0.5" />
            <circle cx={activePt[0]} cy={activePt[1]} r="4.5" fill={stroke} />
          </>
        )}
      </svg>
    </div>
  );
}
