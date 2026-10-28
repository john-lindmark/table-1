/**
 * Insights chart maths (contract/insights-2026-10-24.md). The same answers as the Python reference
 * testdata/insight-charts/make_cases.py, iOS InsightCharts.swift and Android InsightCharts.kt; insightCharts.test.ts
 * checks this file against its cases.
 */

/** 1, 2, 2.5 or 5 × a power of ten: the smallest at least `raw`. */
export function niceStep(raw: number): number {
  if (raw <= 0) return 1;
  const base = 10 ** Math.floor(Math.log10(raw));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * base >= raw - 1e-12) return Math.round(m * base * 1e12) / 1e12;
  return 10 * base;
}

/** Evenly spaced round values covering lo…hi with about `count` intervals; lo == hi widens to one step. */
export function ticks(lo0: number, hi0: number, count: number): number[] {
  let lo = Math.min(lo0, hi0), hi = Math.max(lo0, hi0);
  if (hi === lo) hi = lo + (Math.abs(lo) * 0.1 || 1);
  const step = niceStep((hi - lo) / Math.max(1, count));
  const start = Math.floor(lo / step + 1e-9) * step, end = Math.ceil(hi / step - 1e-9) * step;
  const n = Math.round((end - start) / step);
  return Array.from({ length: n + 1 }, (_, i) => Math.round((start + i * step) * 1e10) / 1e10);
}

/** Runs of non-null values as [index, value]; a null breaks the line. */
export function segments(values: (number | null)[]): [number, number][][] {
  const out: [number, number][][] = [];
  let cur: [number, number][] = [];
  values.forEach((v, i) => {
    if (v == null) { if (cur.length) { out.push(cur); cur = []; } } else cur.push([i, v]);
  });
  if (cur.length) out.push(cur);
  return out;
}

/** 90% Wilson interval for a win rate; [0, 1] with no games. */
export interface Heat { label: string; tone: "up" | "down" | "even" | "none"; strength: number; dim: boolean; ink: boolean }
/** A matchup grid cell: its number, tone and fill strength. Under `minimum` matches it still shows, dimmed: half the
 *  fill and muted text (testdata/insight-charts make_cases.py `heat`). */
export function heat(wins: number, losses: number, minimum = 30): Heat {
  const n = wins + losses;
  if (n === 0) return { label: "", tone: "none", strength: 0, dim: false, ink: false };
  const wr = wins / n, d = wr - 0.5;
  const tone = Math.abs(d) < 0.03 ? "even" : d > 0 ? "up" : "down";
  const dim = n < minimum;
  const strength = (tone === "even" ? 0 : Math.min(1, 0.25 + Math.abs(d) * 4)) * (dim ? 0.5 : 1);
  return { label: String(Math.floor(wr * 100 + 0.5)), tone, strength: Math.round(strength * 10000) / 10000, dim, ink: Math.abs(d) >= 0.08 && !dim };
}

export function wilson(wins: number, n: number, z = 1.6449): [number, number] {
  if (n <= 0) return [0, 1];
  const p = wins / n, d = 1 + (z * z) / n;
  const c = (p + (z * z) / (2 * n)) / d;
  const h = (z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))) / d;
  return [Math.max(0, c - h), Math.min(1, c + h)];
}

/** Least-squares line y = a + b·x; null with fewer than two distinct x. */
export function fit(xs: number[], ys: number[]): { a: number; b: number } | null {
  const n = xs.length;
  if (n < 2) return null;
  const mx = xs.reduce((s, x) => s + x, 0) / n, my = ys.reduce((s, y) => s + y, 0) / n;
  const sxx = xs.reduce((s, x) => s + (x - mx) ** 2, 0);
  if (sxx === 0) return null;
  const b = xs.reduce((s, x, i) => s + (x - mx) * (ys[i] - my), 0) / sxx;
  return { a: my - b * mx, b };
}

/** End labels at screen ys (down is larger) moved apart to at least `gap` and kept inside lo…hi, in input order. */
export function spread(ys: number[], gap: number, lo: number, hi: number): number[] {
  if (!ys.length) return [];
  const order = ys.map((_, i) => i).sort((a, b) => ys[a] - ys[b] || a - b);
  const pos = new Array<number>(ys.length).fill(0);
  let prev: number | null = null;
  for (const i of order) {
    const y: number = prev == null ? Math.max(ys[i], lo) : Math.max(ys[i], prev + gap);
    pos[i] = y;
    prev = y;
  }
  const over = pos[order[order.length - 1]] - hi;
  if (over > 0) {
    let next: number | null = null;
    for (const i of [...order].reverse()) {
      const y: number = next == null ? pos[i] - over : Math.min(pos[i], next - gap);
      pos[i] = Math.max(lo, y);
      next = pos[i];
    }
  }
  return pos;
}

/** 21% / 3.4% (under 10% keeps one decimal), as the briefs write shares. */
export function pct(x: number | null | undefined): string {
  if (x == null) return "–";
  return x >= 0.0995 || x === 0 ? `${Math.round(x * 100)}%` : `${(x * 100).toFixed(1)}%`;
}

/** 57.1%: win rates keep one decimal. */
export function pct1(x: number | null | undefined): string {
  return x == null ? "–" : `${(x * 100).toFixed(1)}%`;
}

/** A Meta now row's win rate, conversion rate (lists that made top 8) and event win rate (first place, of the window's
 *  events with a winner); a part the pack has no number for is left out (make_cases.py `rates`). */
export function rates(wr: number | null | undefined, t8r: number | null | undefined, won: number | null | undefined, wonOf: number | null | undefined): string {
  const parts: string[] = [];
  if (wr != null) parts.push(`Win ${pct1(wr)}`);
  if (t8r != null) parts.push(`Conv ${pct(t8r)}`);
  if (wonOf) parts.push(`1st ${pct((won ?? 0) / wonOf)}`);
  return parts.join(" · ");
}

/** +2.1 / -12: a change in percentage points; under 10 keeps one decimal. */
export function delta(d: number | null | undefined): string {
  if (d == null) return "";
  const v = Math.abs(d * 100);
  return (d >= 0 ? "+" : "-") + (v >= 10 ? String(Math.round(v)) : v.toFixed(1));
}

const MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];

/** Index and upper-case month of each month's first day in a daily series from `start` (yyyy-mm-dd). */
export function months(start: string, days: number): [number, string][] {
  const d0 = Date.parse(`${start.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(d0)) return [];
  const out: [number, string][] = [];
  for (let i = 0; i < days; i++) {
    const d = new Date(d0 + i * 86400000);
    if (d.getUTCDate() === 1) out.push([i, MONTHS[d.getUTCMonth()]]);
  }
  return out;
}

export interface SeriesWindow { offset: number; from: string; days: number; labels: [number, string][] }

/** The last `keep` days of a daily series of `days` from `start` (the chart follows the picked 7/14/30/90-day window):
 *  where to cut, the new first day, its length and axis labels: months past 45 days, else a day label every
 *  (n + 2) / 4 days counted back from the last day, so the newest day is always labelled. */
export function seriesWindow(start: string, days: number, keep: number): SeriesWindow {
  const offset = Math.max(0, days - keep), n = days - offset;
  const d0 = Date.parse(`${start.slice(0, 10)}T00:00:00Z`) + offset * 86400000;
  if (Number.isNaN(d0)) return { offset, from: start, days: n, labels: [] };
  const from = new Date(d0).toISOString().slice(0, 10);
  if (n > 45) return { offset, from, days: n, labels: months(from, n) };
  const step = Math.max(1, Math.floor((n + 2) / 4));
  const labels: [number, string][] = [];
  for (let i = n - 1; i >= 0; i -= step) {
    const d = new Date(d0 + i * 86400000);
    labels.unshift([i, `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`]);
  }
  return { offset, from, days: n, labels };
}

/** "MAY 18" for a yyyy-mm-dd. */
export function shortDay(iso: string): string {
  const d = new Date(`${iso.slice(0, 10)}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? iso : `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}
