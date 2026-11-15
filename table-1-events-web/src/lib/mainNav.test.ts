import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MAIN_TABS, remembered, storeSub, storedSub, subOfPath, tabHref, type TabId } from "./mainNav";

/* The main navigation (contract/main-nav-2026-11-14.md) against testdata/main-nav/cases.json: the tab table, the
   remembered sub-tab, and which tab and sub-tab each web path belongs to. */

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const cases = JSON.parse(read("../../../testdata/main-nav/cases.json")) as {
  tabs: { id: TabId; label: string; default: string; subs: { id: string; label: string; web: string; fullScreen?: boolean }[] }[];
  remembered: { tab: TabId; stored: string | null; want: string }[];
  routes: { path: string; tab: TabId | null; sub: string | null }[];
};

describe("main nav", () => {
  it("has the shared tabs, sub-tabs, labels, defaults and paths in order", () => {
    expect(MAIN_TABS.map((t) => t.id)).toEqual(cases.tabs.map((t) => t.id));
    for (const want of cases.tabs) {
      const t = MAIN_TABS.find((x) => x.id === want.id)!;
      expect(t.label).toBe(want.label);
      expect(t.default).toBe(want.default);
      expect(t.subs.map((s) => [s.id, s.label, s.web, !!s.fullScreen])).toEqual(want.subs.map((s) => [s.id, s.label, s.web, !!s.fullScreen]));
    }
  });

  it.each(cases.remembered.map((c) => [`${c.tab} ${JSON.stringify(c.stored)}`, c]))("remembers %s", (_, c) => {
    expect(remembered(c.tab, c.stored)).toBe(c.want);
  });

  it.each(cases.routes.map((c) => [c.path, c]))("puts %s on its tab", (_, c) => {
    expect(subOfPath(c.path)).toEqual({ tab: c.tab, sub: c.sub });
  });

  it("ignores a trailing slash", () => {
    expect(subOfPath("/library/wants/")).toEqual({ tab: "collection", sub: "wants" });
  });
});

describe("stored sub-tabs", () => {
  // Tests run in node: a stand-in localStorage.
  beforeEach(() => {
    const m = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (k: string) => m.get(k) ?? null, setItem: (k: string, v: string) => void m.set(k, String(v)), clear: () => m.clear(),
    });
  });
  afterEach(() => vi.unstubAllGlobals());

  it("keeps a place in localStorage t1.nav.sub.<tab> and links the top tab to it", () => {
    expect(tabHref("collection")).toBe("/library");
    storeSub("collection", "wants");
    expect(localStorage.getItem("t1.nav.sub.collection")).toBe("wants");
    expect(tabHref("collection")).toBe("/library/wants");
    storeSub("account", "settings");
    expect(tabHref("account")).toBe("/me/settings");
    storeSub("insights", "rankings");
    expect(tabHref("insights")).toBe("/insights/rankings");
  });

  it("never keeps the life tracker or a value that isn't the tab's", () => {
    storeSub("events", "events");
    storeSub("events", "tracker");
    expect(storedSub("events")).toBe("events");
    storeSub("collection", "rankings");
    expect(storedSub("collection")).toBeNull();
    localStorage.setItem("t1.nav.sub.insights", "bogus");
    expect(tabHref("insights")).toBe("/insights");
  });
});
