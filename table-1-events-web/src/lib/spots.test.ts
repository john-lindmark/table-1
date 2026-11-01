import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { SPOTS, copyProblems, spots } from "./spots";
import { appStoreListing, playListing, LIMITS } from "../../../tools/spots/storeCopy.mjs";

/* The feature spots file (contract/feature-spots-2026-11-01.md): copy within its limits, a shot for every spot
   the apps and the landing page show, routes the shooter can open, and store copy inside Apple's and Google's limits. */
describe("feature spots", () => {
  it("keys are unique and copy is within limits", () => {
    const keys = SPOTS.spots.map((s) => s.key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(copyProblems()).toEqual([]);
  });

  it("every onboarding or store spot has its shot", () => {
    for (const s of SPOTS.spots.filter((x) => x.onboarding || x.store)) {
      const path = new URL(`../../../marketing/bundle/spots/shots/${s.key}.png`, import.meta.url);
      expect(existsSync(path), `${s.key}.png: run tools/spots/run.sh`).toBe(true);
    }
  });

  it("shots open screens the dev server has", () => {
    const app = readFileSync(new URL("../App.tsx", import.meta.url), "utf8");
    for (const s of SPOTS.spots) {
      const path = s.shot.route.split("?")[0];
      // A route pattern with its params replaced matches the start of the shot's path.
      const patterns = [...app.matchAll(/path="([^"]+)"/g)].map((m) => m[1]);
      const matches = patterns.some((p) => {
        const re = new RegExp("^" + p.replace(/:[A-Za-z]+/g, "[^/]+").replace(/\*/g, ".*") + "$");
        return re.test(path);
      });
      expect(matches, `${s.key}: ${path}`).toBe(true);
      if (s.shot.file) expect(existsSync(new URL(`../../../${s.shot.file}`, import.meta.url)), s.shot.file).toBe(true);
    }
  });

  it("the apps' carousel has at least three spots", () => {
    expect(spots().length).toBeGreaterThanOrEqual(3);
  });

  it("store copy fits Apple's and Google's fields", () => {
    const a = appStoreListing(SPOTS);
    expect(a.name.length).toBeLessThanOrEqual(LIMITS.appStore.name);
    expect(a.subtitle.length).toBeLessThanOrEqual(LIMITS.appStore.subtitle);
    expect(a.promotionalText.length).toBeLessThanOrEqual(LIMITS.appStore.promotionalText);
    expect(a.description.length).toBeLessThanOrEqual(LIMITS.appStore.description);
    expect(a.keywords.length).toBeLessThanOrEqual(LIMITS.appStore.keywords);
    const p = playListing(SPOTS);
    expect(p.title.length).toBeLessThanOrEqual(LIMITS.play.title);
    expect(p.shortDescription.length).toBeLessThanOrEqual(LIMITS.play.shortDescription);
    expect(p.fullDescription.length).toBeLessThanOrEqual(LIMITS.play.fullDescription);
    // Every spot is in both descriptions, in order.
    let at = -1;
    for (const s of SPOTS.spots.filter((x) => x.store)) {
      const i = a.description.indexOf(s.title.toUpperCase());
      expect(i, s.key).toBeGreaterThan(at);
      at = i;
      expect(p.fullDescription).toContain(s.title.toUpperCase());
    }
  });
});
