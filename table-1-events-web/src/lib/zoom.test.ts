import { describe, expect, it } from "vitest";
import { MAX_ZOOM, clamp, fitView, fitted, pan, toggle, zoomTo } from "./zoom";

/* Zoom view for the deck image and top 100 image (contract/list-to-collection-2026-10-22.md § Zoom). */

const box = { w: 400, h: 800 };
const img = { w: 1600, h: 900 };
const fit = fitted(box, img);

describe("zoom", () => {
  it("fits the picture and centers it", () => {
    expect(fit).toEqual({ w: 400, h: 225 });
    expect(fitView(box, fit)).toEqual({ s: 1, x: 0, y: 287.5 });
  });

  it("keeps the point under the pointer where it is", () => {
    const v = zoomTo(fitView(box, fit), 2, 100, 400, box, fit);
    expect(v.s).toBe(2);
    // The picture point at (100, 400) was 100 px in, 112.5 px down; at 2× it's 200 / 225 from the corner.
    expect(v.x).toBe(-100);
    // 450 tall still fits 800: centered vertically.
    expect(v.y).toBe(175);
  });

  it("stays between fitted and the most zoom", () => {
    const v = fitView(box, fit);
    expect(zoomTo(v, 0.2, 0, 0, box, fit)).toEqual(v);
    expect(zoomTo(v, 99, 200, 400, box, fit).s).toBe(MAX_ZOOM);
  });

  it("can't be dragged past an edge", () => {
    const v = zoomTo(fitView(box, fit), 4, 200, 400, box, fit);
    expect(pan(v, 10_000, 0, box, fit).x).toBe(0);
    expect(pan(v, -10_000, 0, box, fit).x).toBe(400 - 1600);
    expect(pan(v, 0, 10_000, box, fit).y).toBe(0);
    expect(pan(v, 0, -10_000, box, fit).y).toBe(800 - 900);
  });

  it("double-click goes to 3× and back", () => {
    const v = toggle(fitView(box, fit), 200, 400, box, fit);
    expect(v.s).toBe(3);
    expect(toggle(v, 0, 0, box, fit)).toEqual(fitView(box, fit));
  });

  it("re-centers when the box grows", () => {
    expect(clamp({ s: 1, x: -50, y: 0 }, { w: 800, h: 800 }, fitted({ w: 800, h: 800 }, img))).toEqual({ s: 1, x: 0, y: 175 });
  });
});
