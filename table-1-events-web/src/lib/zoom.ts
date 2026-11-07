/* Zooming a made picture (deck image, top 100): the picture fits the box at scale 1 and zooms to MAX_ZOOM around
   the pointer; while it's smaller than the box it stays centered, and once larger it can't be dragged past an edge. */

export const MAX_ZOOM = 8;
/** Double-click / double-tap from fitted. */
export const STEP_ZOOM = 3;

export interface Size { w: number; h: number }
/** Scale over the fitted size, and the picture's top-left corner in the box. */
export interface View { s: number; x: number; y: number }

/** The picture's size at scale 1: as large as fits the box. */
export function fitted(box: Size, img: Size): Size {
  if (img.w <= 0 || img.h <= 0) return { w: 0, h: 0 };
  const b = Math.min(box.w / img.w, box.h / img.h);
  return { w: img.w * b, h: img.h * b };
}

/** Centered on any axis where it's smaller than the box; otherwise kept covering the box edge to edge. */
export function clamp(v: View, box: Size, fit: Size): View {
  const w = fit.w * v.s, h = fit.h * v.s;
  const x = w <= box.w ? (box.w - w) / 2 : Math.min(0, Math.max(box.w - w, v.x));
  const y = h <= box.h ? (box.h - h) / 2 : Math.min(0, Math.max(box.h - h, v.y));
  return { s: v.s, x, y };
}

export function fitView(box: Size, fit: Size): View { return clamp({ s: 1, x: 0, y: 0 }, box, fit); }

/** Scale to `s` (kept in 1…MAX_ZOOM) keeping the picture point under (px, py) where it is. */
export function zoomTo(v: View, s: number, px: number, py: number, box: Size, fit: Size): View {
  const next = Math.min(MAX_ZOOM, Math.max(1, s));
  const k = next / v.s;
  return clamp({ s: next, x: px - (px - v.x) * k, y: py - (py - v.y) * k }, box, fit);
}

export function pan(v: View, dx: number, dy: number, box: Size, fit: Size): View {
  return clamp({ s: v.s, x: v.x + dx, y: v.y + dy }, box, fit);
}

/** Double-click: fitted ↔ STEP_ZOOM around the point. */
export function toggle(v: View, px: number, py: number, box: Size, fit: Size): View {
  return v.s > 1.01 ? fitView(box, fit) : zoomTo(v, STEP_ZOOM, px, py, box, fit);
}

/** The row under a made picture's preview: touch screens hold for the browser's image menu, mice right-click. */
export function previewHint(coarse = typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches): string {
  return coarse ? "Tap to zoom · hold to copy, save or share" : "Click to zoom · right-click to copy or save";
}
