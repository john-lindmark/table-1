import { useEffect, useState } from "react";
import { capture } from "./telemetry";

/**
 * Foldables (contract/foldables-2026-11-10.md): one rule from a container's own size and the folds crossing it.
 * Folds come from the Viewport Segments API (`window.viewport.segments`, Chrome on Galaxy Z Fold and Pixel Fold):
 * two segments mean the device is folded, and the gap between them is the fold.
 */
export type Fold = { x: number; y: number; w: number; h: number; vertical: boolean; separating: boolean; margin: number };
export type FoldMode = "single" | "wide" | "tabletop" | "book";
export type SizeClass = "compact" | "medium" | "expanded";
export type Rect = [number, number, number, number];
export type FoldLayout = {
  width: SizeClass;
  height: SizeClass;
  mode: FoldMode;
  panes: Rect[];
  rail: boolean;
  rotates: boolean;
};

export const FOLD = { clear: 8, minPane: 120, wide: 840, heightMin: 480 };

const r2 = (n: number) => Math.round(n * 100) / 100;
const rect = (x: number, y: number, w: number, h: number): Rect => [r2(x), r2(y), r2(Math.max(w, 0)), r2(Math.max(h, 0))];

export const widthClass = (w: number): SizeClass => (w < 600 ? "compact" : w < 840 ? "medium" : "expanded");
export const heightClass = (h: number): SizeClass => (h < 480 ? "compact" : h < 900 ? "medium" : "expanded");

export function foldLayout(w: number, h: number, folds: Fold[]): FoldLayout {
  let mode: FoldMode = "single";
  let panes: Rect[] = [rect(0, 0, w, h)];
  for (const f of folds) {
    if (!f.separating) continue;
    const clear = Math.max(FOLD.clear, f.margin ?? 0);
    if (f.vertical) {
      const a = f.x - clear;
      const b = f.x + f.w + clear;
      if (a >= FOLD.minPane && w - b >= FOLD.minPane) {
        mode = "book";
        panes = [rect(0, 0, a, h), rect(b, 0, w - b, h)];
        break;
      }
    } else {
      const a = f.y - clear;
      const b = f.y + f.h + clear;
      if (a >= FOLD.minPane && h - b >= FOLD.minPane) {
        mode = "tabletop";
        panes = [rect(0, 0, w, a), rect(0, b, w, h - b)];
        break;
      }
    }
  }
  if (mode === "single" && w >= FOLD.wide && h >= FOLD.heightMin) {
    const half = (w - 1) / 2;
    mode = "wide";
    panes = [rect(0, 0, half, h), rect(half + 1, 0, w - half - 1, h)];
  }
  return {
    width: widthClass(w),
    height: heightClass(h),
    mode,
    panes,
    rail: mode !== "tabletop" && w > h,
    rotates: Math.min(w, h) >= 600,
  };
}

type Segment = { left: number; top: number; right: number; bottom: number; width: number; height: number };

/** The fold between two viewport segments (side by side: book; stacked: tabletop). */
export function foldFromSegments(segments: readonly Segment[] | null | undefined): Fold[] {
  if (!segments || segments.length < 2) return [];
  const [a, b] = segments;
  if (b.left >= a.right - 0.5) {
    return [{ x: a.right, y: 0, w: Math.max(0, b.left - a.right), h: Math.max(a.height, b.height), vertical: true, separating: true, margin: 0 }];
  }
  if (b.top >= a.bottom - 0.5) {
    return [{ x: 0, y: a.bottom, w: Math.max(a.width, b.width), h: Math.max(0, b.top - a.bottom), vertical: false, separating: true, margin: 0 }];
  }
  return [];
}

/** Design QA without a foldable: `?fold=tabletop|book` puts a 20 px fold across the middle of the window. */
function debugFolds(w: number, h: number): Fold[] {
  const mode = new URLSearchParams(window.location.search).get("fold");
  if (mode === "tabletop") return [{ x: 0, y: h / 2 - 10, w, h: 20, vertical: false, separating: true, margin: 0 }];
  if (mode === "book") return [{ x: w / 2 - 10, y: 0, w: 20, h, vertical: true, separating: true, margin: 0 }];
  return [];
}

export function windowFolds(): Fold[] {
  const segments = (window as unknown as { viewport?: { segments?: Segment[] | null } }).viewport?.segments;
  const real = foldFromSegments(segments);
  return real.length ? real : debugFolds(window.innerWidth, window.innerHeight);
}

/** The window's layout, kept current on resize (folding, unfolding and turning all fire it). */
export function useWindowFold(screen?: string): FoldLayout {
  const read = () => foldLayout(window.innerWidth, window.innerHeight, windowFolds());
  const [layout, setLayout] = useState(read);
  useEffect(() => {
    const on = () => setLayout(read());
    window.addEventListener("resize", on);
    window.visualViewport?.addEventListener("resize", on);
    return () => {
      window.removeEventListener("resize", on);
      window.visualViewport?.removeEventListener("resize", on);
    };
  }, []);
  const posture = layout.mode === "tabletop" || layout.mode === "book" ? layout.mode : "flat";
  useEffect(() => {
    if (posture !== "flat") capture("fold_posture", { posture, width: layout.width, height: layout.height });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [posture]);
  useEffect(() => {
    if (screen && layout.mode !== "single") capture("fold_layout", { mode: layout.mode, screen });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [layout.mode, screen]);
  return layout;
}

/** A pane's absolute position. */
export const paneStyle = ([x, y, w, h]: Rect) => ({ left: x, top: y, width: w, height: h });
