import { readFileSync } from "node:fs";
import { matchPath } from "react-router-dom";
import { describe, expect, it } from "vitest";

/* Universal / app links (contract/universal-links-2026-10-22.md). The apps parse testdata/universal-links/cases.json
   in their own tests; this one checks the three places that must agree with them: every link an app opens is also a
   page here (for phones without the app), and both apple-app-site-association and the Android manifest claim it, while
   the pages left to the browser stay unclaimed. */

type Case = { url: string; to: string | null; browser?: boolean };
const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const cases: Case[] = JSON.parse(read("../../../testdata/universal-links/cases.json")).cases;
const aasa = JSON.parse(read("../../public/.well-known/apple-app-site-association"));
const manifest = read("../../../apps/android/app/src/main/AndroidManifest.xml");
const routes = [...read("../App.tsx").matchAll(/<Route path="([^"]+)"/g)].map((m) => m[1]).filter((p) => p !== "*");

/** Apple's pattern rules: * is any run of characters, ? one character. */
function glob(pattern: string, value: string) {
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
  return new RegExp(`^${re}$`).test(value);
}

/** The first component that matches decides; an exclude means Safari keeps the link. */
function appleClaims(u: URL) {
  type Component = { "/"?: string; "?"?: Record<string, string>; "#"?: string; exclude?: boolean };
  const components: Component[] = aasa.applinks.details[0].components;
  const query = Object.fromEntries(u.searchParams);
  for (const c of components) {
    if (c["/"] !== undefined && !glob(c["/"], u.pathname)) continue;
    if (c["#"] !== undefined && !glob(c["#"], u.hash.slice(1))) continue;
    if (c["?"] && !Object.entries(c["?"]).every(([k, p]) => k in query && glob(p, query[k]))) continue;
    return !c.exclude;
  }
  return false;
}

/** The app-link filter's paths (Android matches by path only). */
function androidClaims(u: URL) {
  const filter = manifest.match(/<intent-filter android:autoVerify="true">[\s\S]*?<\/intent-filter>/)?.[0] ?? "";
  const hosts = [...filter.matchAll(/android:host="([^"]+)"/g)].map((m) => m[1]);
  const paths = [...filter.matchAll(/android:path="([^"]+)"/g)].map((m) => m[1]);
  const prefixes = [...filter.matchAll(/android:pathPrefix="([^"]+)"/g)].map((m) => m[1]);
  return hosts.includes(u.hostname) && (paths.includes(u.pathname) || prefixes.some((p) => u.pathname.startsWith(p)));
}

describe("universal links", () => {
  const opened = cases.filter((c) => c.to && c.to !== "web");

  it.each(opened.map((c) => [c.url, c]))("%s opens in the app, or on the web without it", (_, c) => {
    const u = new URL(c.url);
    expect(appleClaims(u)).toBe(true);
    expect(androidClaims(u)).toBe(true);
    expect(routes.some((r) => matchPath(r, u.pathname.replace(/(.)\/$/, "$1")))).toBe(true);
  });

  it.each(cases.filter((c) => c.browser).map((c) => [c.url, c]))("%s stays in the browser", (_, c) => {
    const u = new URL(c.url);
    expect(appleClaims(u)).toBe(false);
    if (!u.hash && !u.search) expect(androidClaims(u)).toBe(false);
  });

  // The TV display (contract/public-events-leagues-2026-11-13.md § 5) is a web page only: a phone that scans the
  // organizer's Display QR, or a TV's browser, must not be handed to the app.
  it("the TV display stays in the browser and is a page here", () => {
    for (const host of ["table-1.site", "www.table-1.site"]) {
      const u = new URL(`https://${host}/d/8f3c1d2e-0000-4000-8000-000000000000`);
      expect(appleClaims(u)).toBe(false);
      expect(androidClaims(u)).toBe(false);
      expect(routes.some((r) => matchPath(r, u.pathname))).toBe(true);
    }
  });

  // Find, a league and a board (contract/public-events-leagues-2026-11-13.md §§ 1, 3, 4) are pages here, signed in
  // or out. The apps' builds on phones have no screen for them yet, so the links stay in the browser until a build
  // that has one ships and the claim lands in all three places together (AASA, the Android manifest, the cases).
  it("Find, leagues and boards are pages here and stay in the browser", () => {
    for (const path of ["/find", "/league/the-mountain-magic-series", "/boards/modern"]) {
      const u = new URL(`https://table-1.site${path}`);
      expect(appleClaims(u), path).toBe(false);
      expect(androidClaims(u), path).toBe(false);
      expect(routes.some((r) => matchPath(r, u.pathname)), path).toBe(true);
    }
  });

  // Stripe's return pages (contract/entry-fees-2026-11-13.md § 3) are plain web pages: Stripe sends people back to
  // them from the apps' own in-app browser tab, where a claimed link would never load, and the page itself offers
  // the way back into the app.
  it("Stripe's return pages are pages here and stay in the browser", () => {
    for (const host of ["table-1.site", "www.table-1.site"]) {
      for (const path of ["/pay/done", "/pay/connected", "/pay/connect"]) {
        const u = new URL(`https://${host}${path}?e=8f3c1d2e-0000-4000-8000-000000000000&s=cs_test_1`);
        expect(appleClaims(u), path).toBe(false);
        expect(androidClaims(u), path).toBe(false);
        expect(routes.some((r) => matchPath(r, u.pathname)), path).toBe(true);
      }
    }
  });

  // The organizer's print views (contract/room-tools-2026-11-13.md § 5) are web pages only. iPhones keep them in the
  // browser (the exclude sits before the /e/* claim). Android can only claim by prefix: its /e/ prefix still takes the
  // link, and the app hands a path it has no screen for back to the browser.
  it("the print views are pages here and stay in the browser on iPhone", () => {
    for (const what of ["pairings", "pairings-az", "standings", "slips"]) {
      const u = new URL(`https://table-1.site/e/8f3c1d2e-0000-4000-8000-000000000000/print/${what}`);
      expect(appleClaims(u), what).toBe(false);
      expect(routes.some((r) => matchPath(r, u.pathname)), what).toBe(true);
    }
    // The event itself, and its other pages, still open in the app.
    for (const path of ["/e/8f3c1d2e-0000-4000-8000-000000000000", "/e/8f3c1d2e-0000-4000-8000-000000000000/add"]) {
      expect(appleClaims(new URL(`https://table-1.site${path}`)), path).toBe(true);
    }
  });

  // A team's link (contract/teams-finals-alerts-2026-11-13.md § 2) is the event page with the code: the same claim as
  // the event page, and a page here with the code filled in.
  it("a team's link is the event page", () => {
    const u = new URL("https://table-1.site/s/8f3c1d2e-0000-4000-8000-000000000000?team=GLCH7K2M");
    expect(routes.some((r) => matchPath(r, u.pathname))).toBe(true);
    expect(appleClaims(u)).toBe(appleClaims(new URL("https://table-1.site/s/8f3c1d2e-0000-4000-8000-000000000000")));
  });

  it("claims both hosts", () => {
    expect(androidClaims(new URL("https://www.table-1.site/library"))).toBe(true);
    expect(read("../../../apps/ios/project.yml")).toContain('"applinks:table-1.site", "applinks:www.table-1.site"');
  });
});
