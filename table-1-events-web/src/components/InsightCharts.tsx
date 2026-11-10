import { useState } from "react";
import { fit, heat, pct, pct1, segments, spread, ticks, type Heat } from "../lib/insightCharts";

/* Insights charts in the Table 1 look: hairline axes on the surface, mono labels, no fills or shadows, grey for context
   and teal only for the series the brief is about. Positions come from lib/insightCharts (shared with the apps). */

const C = { surface: "var(--color-t1-surface)", hover: "var(--color-t1-surface-hover)", text: "var(--color-t1-text)", muted: "var(--color-t1-muted)",
            accent: "var(--color-t1-accent)", warning: "var(--color-t1-warning)", disabled: "var(--color-t1-disabled)", error: "var(--color-t1-error, #f2a3e5)" };
const W = 640;

export interface LineSeries { id: string | number; label: string; values: (number | null)[]; highlighted?: boolean }
export interface Marker { index: number; label: string; ban: boolean }

/** Share lines over time with change markers and labels at the line ends. */
export function LineChart({ series, count, markers = [], xLabels = [], height = 200, format = pct, labelWidth = 120, endLabels = true, fitY = false, reference }: {
  series: LineSeries[]; count: number; markers?: Marker[]; xLabels?: [number, string][]; height?: number;
  format?: (x: number) => string; labelWidth?: number;
  /** Labels at the line ends. Off where a picker under the chart names the lines, so the plot runs to the right edge. */
  endLabels?: boolean;
  /** Scale the y axis to the values (and the reference) instead of starting at 0, e.g. win rates around 50%. */
  fitY?: boolean;
  /** A dashed line across the chart with its own end label, e.g. the average win rate in scope. */
  reference?: { label: string; value: number };
}) {
  const left = 40, right = endLabels ? labelWidth : 4, top = 16, bottom = 18;
  const w = W - left - right, h = height - top - bottom;
  const all = [...series.flatMap((s) => s.values.filter((v): v is number => v != null)), ...(reference ? [reference.value] : [])];
  const yt = fitY && all.length ? ticks(Math.min(...all), Math.max(...all), 3) : ticks(0, Math.max(Math.max(0, ...all), 0.05), 3);
  const yMin = yt[0] ?? 0, yMax = yt[yt.length - 1] || 1;
  const x = (i: number) => left + (w * i) / Math.max(1, count - 1);
  const y = (v: number) => top + h * (1 - (v - yMin) / Math.max(1e-9, yMax - yMin));
  const ends = [
    ...series.map((s) => ({ id: s.id, label: s.label, v: [...s.values].reverse().find((v) => v != null) ?? null, fill: s.highlighted ? C.accent : C.muted })),
    ...(reference ? [{ id: "reference", label: reference.label, v: reference.value as number | null, fill: C.text }] : []),
  ].filter((e) => e.v != null);
  const endY = spread(ends.map((e) => y(e.v!)), 12, top, top + h);
  const ordered = [...series].sort((a, b) => Number(!!a.highlighted) - Number(!!b.highlighted));
  return (
    <svg viewBox={`0 0 ${W} ${height}`} className="w-full h-auto block" role="img"
         aria-label={ends.map((e) => `${e.label} ${format(e.v!)}`).join(", ")}>
      {yt.map((t) => (
        <g key={t}>
          <line x1={left} x2={left + w} y1={y(t)} y2={y(t)} stroke={C.hover} strokeWidth={1} />
          <text x={left - 6} y={y(t)} fill={C.muted} fontSize={10} textAnchor="end" dominantBaseline="middle">{format(t)}</text>
        </g>
      ))}
      {/* kept inside the right edge, which has no end labels to make room when they're off */}
      {xLabels.map(([i, l]) => <text key={i} x={Math.min(x(i), W - l.length * 3.2)} y={height - 2} fill={C.muted} fontSize={10} textAnchor="middle">{l}</text>)}
      {markers.filter((m) => m.index >= 0 && m.index < count).map((m) => (
        <g key={`${m.index}${m.label}`}>
          <line x1={x(m.index)} x2={x(m.index)} y1={top} y2={top + h} stroke={m.ban ? C.warning : C.disabled} strokeDasharray="3 3" />
          <text x={x(m.index) + 3} y={10} fill={m.ban ? C.warning : C.muted} fontSize={9}>{m.label}</text>
        </g>
      ))}
      {reference && <line x1={left} x2={left + w} y1={y(reference.value)} y2={y(reference.value)} stroke={C.text} strokeDasharray="4 3" />}
      {ordered.map((s) => segments(s.values).map((seg, k) => seg.length === 1
        ? <circle key={`${s.id}-${k}`} cx={x(seg[0][0])} cy={y(seg[0][1])} r={1.8} fill={s.highlighted ? C.accent : C.muted} />
        : <polyline key={`${s.id}-${k}`} fill="none" points={seg.map(([i, v]) => `${x(i)},${y(v)}`).join(" ")}
                    stroke={s.highlighted ? C.accent : C.muted} strokeOpacity={s.highlighted ? 1 : 0.55} strokeWidth={s.highlighted ? 2 : 1} />))}
      {endLabels && ends.map((e, k) => (
        <text key={e.id} x={left + w + 6} y={endY[k]} fill={e.fill} fontSize={10} dominantBaseline="middle">
          {`${e.label} ${format(e.v!)}`.slice(0, 22)}
        </text>
      ))}
    </svg>
  );
}

/** One horizontal bar with its value and change. */
export function Bar({ label, value, max, min = 0, detail, change, highlighted, format = pct, reference, onClick }: {
  label: string; value: number; max: number; min?: number; detail?: string | null; change?: number | null; highlighted?: boolean;
  format?: (x: number) => string; reference?: number | null; onClick?: () => void;
}) {
  const span = Math.max(1e-9, max - min);
  const frac = Math.max(0, Math.min(1, (value - min) / span));
  const body = (
    <>
      <span className="flex items-center gap-2 w-full">
        <span className="text-[13px] truncate flex-1 text-left">{label}</span>
        {change != null && Math.abs(change) >= 0.0005 && (
          <span className={`text-[11px] tabular-nums ${change > 0 ? "text-t1-text" : "text-t1-muted"}`}>
            {change > 0 ? "▲" : "▼"} {Math.abs(change * 100) >= 10 ? Math.round(Math.abs(change * 100)) : Math.abs(change * 100).toFixed(1)}
          </span>
        )}
        <span className={`text-[13px] tabular-nums ${highlighted ? "text-t1-accent" : ""}`}>{format(value)}</span>
      </span>
      <span className="relative block w-full h-1 bg-t1-surface-hover">
        <span className={`absolute inset-y-0 left-0 ${highlighted ? "bg-t1-accent" : "bg-t1-muted"}`} style={{ width: `${frac * 100}%` }} />
        {reference != null && <span className="absolute inset-y-0 w-px bg-t1-text" style={{ left: `${Math.max(0, Math.min(1, (reference - min) / span)) * 100}%` }} />}
      </span>
      {detail && <span className="t1-label truncate w-full text-left">{detail}</span>}
    </>
  );
  const cls = "bg-t1-surface px-4 py-3 flex flex-col gap-1.5 w-full";
  return onClick
    ? <button type="button" onClick={onClick} className={`${cls} hover:bg-t1-surface-hover`}>{body}</button>
    : <div className={cls}>{body}</div>;
}

/** Before → after for a ban study. */
export function SlopeChart({ rows, leftTitle, rightTitle, height = 220 }: {
  rows: { id: number; label: string; before: number; after: number; highlighted?: boolean }[]; leftTitle: string; rightTitle: string; height?: number;
}) {
  const top = 22, bottom = 8, labelW = 190, x0 = labelW, x1 = W - labelW + 60, h = height - top - bottom;
  const maxV = Math.max(0.05, ...rows.flatMap((r) => [r.before, r.after]));
  const y = (v: number) => top + h * (1 - v / maxV);
  const ly = spread(rows.map((r) => y(r.before)), 13, top, top + h);
  const ry = spread(rows.map((r) => y(r.after)), 13, top, top + h);
  return (
    <svg viewBox={`0 0 ${W} ${height}`} className="w-full h-auto block" role="img" aria-label={rows.map((r) => `${r.label} ${pct(r.before)} to ${pct(r.after)}`).join(", ")}>
      <text x={x0} y={11} fill={C.muted} fontSize={10} textAnchor="middle">{leftTitle.toUpperCase()}</text>
      <text x={x1} y={11} fill={C.muted} fontSize={10} textAnchor="middle">{rightTitle.toUpperCase()}</text>
      {[x0, x1].map((xx) => <line key={xx} x1={xx} x2={xx} y1={top} y2={top + h} stroke={C.hover} />)}
      {rows.map((r, k) => (
        <g key={r.id}>
          <line x1={x0} y1={y(r.before)} x2={x1} y2={y(r.after)} stroke={r.highlighted ? C.accent : C.muted} strokeOpacity={r.highlighted ? 1 : 0.6} strokeWidth={r.highlighted ? 2 : 1} />
          <text x={x0 - 8} y={ly[k]} fill={r.highlighted ? C.accent : C.muted} fontSize={10} textAnchor="end" dominantBaseline="middle">{`${r.label.length > 22 ? `${r.label.slice(0, 21)}…` : r.label} ${pct(r.before)}`}</text>
          <text x={x1 + 8} y={ry[k]} fill={r.highlighted ? C.accent : C.muted} fontSize={10} dominantBaseline="middle">{pct(r.after)}</text>
        </g>
      ))}
    </svg>
  );
}

/** Win rate against how late a card is taken, with the fitted line: above it is underdrafted. */
export function Scatter({ points, height = 300, onPick }: {
  points: { id: string; label: string; x: number; y: number }[]; height?: number; onPick?: (id: string) => void;
}) {
  const [hover, setHover] = useState<string | null>(null);
  const left = 44, bottom = 22, top = 10, right = 12, w = W - left - right, h = height - top - bottom;
  const xt = ticks(Math.min(...points.map((p) => p.x)), Math.max(...points.map((p) => p.x)), 4);
  const yt = ticks(Math.min(...points.map((p) => p.y)), Math.max(...points.map((p) => p.y)), 4);
  const sx = (v: number) => left + (w * (v - xt[0])) / Math.max(1e-9, xt[xt.length - 1] - xt[0]);
  const sy = (v: number) => top + h * (1 - (v - yt[0]) / Math.max(1e-9, yt[yt.length - 1] - yt[0]));
  const f = fit(points.map((p) => p.x), points.map((p) => p.y));
  const res = (p: { x: number; y: number }) => (f ? p.y - (f.a + f.b * p.x) : 0);
  const ranked = [...points].sort((a, b) => res(b) - res(a));
  const named = new Set([...ranked.slice(0, 3), ...ranked.slice(-2)].map((p) => p.id));
  return (
    <svg viewBox={`0 0 ${W} ${height}`} className="w-full h-auto block" role="img" aria-label="Win rate in hand against average pick taken">
      {yt.map((t) => (
        <g key={t}>
          <line x1={left} x2={left + w} y1={sy(t)} y2={sy(t)} stroke={C.hover} />
          <text x={left - 6} y={sy(t)} fill={C.muted} fontSize={10} textAnchor="end" dominantBaseline="middle">{pct(t)}</text>
        </g>
      ))}
      {xt.map((t) => <text key={t} x={sx(t)} y={height - 4} fill={C.muted} fontSize={10} textAnchor="middle">{Number.isInteger(t) ? t : t.toFixed(1)}</text>)}
      {f && <line x1={sx(xt[0])} y1={sy(f.a + f.b * xt[0])} x2={sx(xt[xt.length - 1])} y2={sy(f.a + f.b * xt[xt.length - 1])} stroke={C.text} strokeDasharray="4 3" />}
      {points.map((p) => {
        const r = res(p);
        const color = r >= 0.02 ? C.accent : r <= -0.02 ? C.error : C.muted;
        return (
          <g key={p.id} onMouseEnter={() => setHover(p.id)} onMouseLeave={() => setHover(null)} onClick={() => onPick?.(p.id)} className={onPick ? "cursor-pointer" : ""}>
            <rect x={sx(p.x) - 3} y={sy(p.y) - 3} width={6} height={6} fill={color} fillOpacity={r >= 0.02 || r <= -0.02 ? 1 : 0.6} />
            <rect x={sx(p.x) - 8} y={sy(p.y) - 8} width={16} height={16} fill="transparent"><title>{`${p.label}: ${pct1(p.y)}, pick ${p.x.toFixed(1)}`}</title></rect>
            {(named.has(p.id) || hover === p.id) && <text x={sx(p.x) + 6} y={sy(p.y)} fill={color} fontSize={10} dominantBaseline="middle">{p.label}</text>}
          </g>
        );
      })}
    </svg>
  );
}

/** Matchup grid: the row archetype's match win rate against each column; under `minMatches` a cell still shows, dimmed.
 *  Rows can outnumber columns (every archetype against the top ones); `same` blanks a row's own column. The picked
 *  cell is outlined and its row and column names sit on the lighter surface. The grid scrolls in its own box (at most
 *  70% of the screen high) with the column names pinned on top and the row names pinned on the left. */
export function Heatmap({ rows, notes, cols, same, cell, minMatches = 30, picked, onPick, overall }: {
  rows: string[]; notes?: (string | null)[]; cols: string[]; same: (r: number, c: number) => boolean;
  cell: (r: number, c: number) => { wins: number; losses: number } | null; minMatches?: number;
  picked?: [number, number] | null; onPick?: (r: number, c: number) => void;
  /** A row's overall record, drawn as the first column ("Overall", column -1 for `picked` and `onPick`). */
  overall?: (r: number) => { wins: number; losses: number } | null;
}) {
  const labelBg = (on: boolean) => on ? "bg-t1-surface-hover" : "bg-t1-surface";
  const color = (h: Heat) => h.tone === "none" ? C.surface : h.tone === "even" ? C.hover
    : `color-mix(in srgb, ${h.tone === "up" ? C.accent : C.error} ${Math.round(h.strength * 100)}%, ${C.surface})`;
  return (
    <div className="overflow-auto max-h-[70dvh] bg-t1-bg">
      <table className="w-full border-separate" style={{ borderSpacing: 1 }}>
        <thead>
          <tr>
            <th className="bg-t1-surface sticky top-0 left-0 z-20 shadow-[0_0_0_1px_var(--color-t1-bg)]" />
            {overall && <th className={`${labelBg(picked?.[1] === -1)} sticky top-0 z-10 shadow-[0_0_0_1px_var(--color-t1-bg)] t1-label px-1 py-2 font-normal align-bottom`} style={{ writingMode: "vertical-rl", transform: "rotate(180deg)" }}>Overall</th>}
            {cols.map((l, c) => <th key={l} className={`${labelBg(picked?.[1] === c)} sticky top-0 z-10 shadow-[0_0_0_1px_var(--color-t1-bg)] t1-label px-1 py-2 font-normal align-bottom`} style={{ writingMode: "vertical-rl", transform: "rotate(180deg)" }}>{l}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, r) => (
            <tr key={row}>
              <th className={`${labelBg(picked?.[0] === r)} sticky left-0 z-10 shadow-[0_0_0_1px_var(--color-t1-bg)] text-[11px] leading-tight font-normal text-left px-2 py-1 w-[112px] min-w-[112px] max-w-[112px]`}>{row}{notes?.[r] && <span className="block text-[9px] uppercase tracking-[1px] text-t1-muted mt-0.5">{notes[r]}</span>}</th>
              {overall && (() => {
                const v = overall(r);
                const h = heat(v?.wins ?? 0, v?.losses ?? 0, minMatches);
                const on = picked?.[0] === r && picked?.[1] === -1;
                return (
                  <td onClick={() => v && onPick?.(r, -1)} title={v ? `${row} overall: ${v.wins}-${v.losses}${h.dim ? " (few matches)" : ""}` : undefined}
                      className={`text-center text-[11px] font-semibold tabular-nums h-9 min-w-9 ${v && onPick ? "cursor-pointer" : ""}`}
                      style={{ background: color(h), boxShadow: on ? `inset 0 0 0 1px ${C.text}` : undefined, color: h.ink ? "var(--color-t1-ink)" : h.dim ? "var(--color-t1-muted)" : undefined }}>
                    {h.label}
                  </td>
                );
              })()}
              {cols.map((col, c) => {
                const own = same(r, c);
                const v = own ? null : cell(r, c);
                const h = heat(v?.wins ?? 0, v?.losses ?? 0, minMatches);
                const on = picked?.[0] === r && picked?.[1] === c;
                return (
                  <td key={col} onClick={() => !own && onPick?.(r, c)}
                      title={v ? `${row} vs ${col}: ${v.wins}-${v.losses}${h.dim ? " (few matches)" : ""}` : undefined}
                      className={`text-center text-[11px] tabular-nums h-9 min-w-9 ${!own && onPick ? "cursor-pointer" : ""}`}
                      style={{ background: color(h), boxShadow: on ? `inset 0 0 0 1px ${C.text}` : undefined, color: h.ink ? "var(--color-t1-ink)" : h.dim ? "var(--color-t1-muted)" : undefined }}>
                    {h.label}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
