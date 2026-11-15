/* The main navigation (contract/main-nav-2026-11-14.md): four tabs, Play · Cards · Insights · Account, each with
   sub-tabs in a strip above the tab bar. Every client tests this table and the remembered rule against
   testdata/main-nav/cases.json. */

export type TabId = "events" | "collection" | "insights" | "account";

export interface SubTab {
  id: string;
  label: string;
  /** The sub-tab's root on the web. */
  web: string;
  /** Opens over everything (the life tracker): never remembered, never the strip's current cell. */
  fullScreen?: boolean;
}

export interface MainTab {
  id: TabId;
  label: string;
  default: string;
  subs: SubTab[];
}

export const MAIN_TABS: MainTab[] = [
  {
    id: "events", label: "Play", default: "events",
    subs: [
      { id: "events", label: "Events", web: "/" },
      { id: "tracker", label: "Life tracker", web: "/life", fullScreen: true },
    ],
  },
  {
    id: "collection", label: "Cards", default: "collection",
    subs: [
      { id: "collection", label: "Collection", web: "/library" },
      { id: "trade", label: "Trade", web: "/library/trades" },
      { id: "wants", label: "Wants", web: "/library/wants" },
    ],
  },
  {
    id: "insights", label: "Insights", default: "constructed",
    subs: [
      { id: "constructed", label: "Constructed", web: "/insights" },
      { id: "limited", label: "Limited", web: "/insights/limited" },
      { id: "rankings", label: "Rankings", web: "/insights/rankings" },
    ],
  },
  {
    id: "account", label: "Account", default: "profile",
    subs: [
      { id: "profile", label: "Profile", web: "/me" },
      { id: "records", label: "Records", web: "/me/records" },
      { id: "settings", label: "Settings", web: "/me/settings" },
    ],
  },
];

export const tabOf = (tab: TabId): MainTab => MAIN_TABS.find((t) => t.id === tab)!;

/** What a tab opens on for a stored value: the stored sub-tab when it's one of the tab's own places, else the default
 *  (the life tracker isn't a place). */
export function remembered(tab: TabId, stored: string | null | undefined): string {
  const t = tabOf(tab);
  const s = t.subs.find((x) => x.id === stored);
  return s && !s.fullScreen ? s.id : t.default;
}

/** Old addresses of a sub-tab's own screen: they select the sub-tab. */
const ALIASES: Record<string, { tab: TabId; sub: string }> = {
  "/library/rankings": { tab: "insights", sub: "rankings" },
};

/**
 * The tab and sub-tab a web path belongs to. `sub` is set only on a sub-tab's root (the strip shows there); a screen
 * pushed on a tab has its tab and sub null; the full-screen life tracker and pages outside the app belong to no tab.
 */
export function subOfPath(path: string): { tab: TabId | null; sub: string | null } {
  const p = path.replace(/\/+$/, "") || "/";
  if (p === "/life" || p.startsWith("/life/")) return { tab: null, sub: null };
  for (const t of MAIN_TABS) for (const s of t.subs) if (!s.fullScreen && s.web === p) return { tab: t.id, sub: s.id };
  if (ALIASES[p]) return ALIASES[p];
  const tab: TabId | null =
    /^\/(e|p|join|j|nearby|find|league|boards)(\/|$)/.test(p) ? "events"
    : p.startsWith("/library/ranking/") ? "insights"
    : p.startsWith("/library/") ? "collection"
    : p.startsWith("/insights/") ? "insights"
    : /^\/(me|friends|sharing|u|support|discord)(\/|$)/.test(p) ? "account"
    : null;
  return { tab, sub: null };
}

/** The sub-tab's web path. */
export const subPath = (tab: TabId, sub: string) => tabOf(tab).subs.find((s) => s.id === sub)?.web ?? tabOf(tab).subs[0].web;

const key = (tab: TabId) => `t1.nav.sub.${tab}`;

/** The stored sub-tab of a tab on this device (null when none, or storage is off). */
export function storedSub(tab: TabId): string | null {
  try {
    return localStorage.getItem(key(tab));
  } catch {
    return null;
  }
}

/** Keeps the sub-tab a tab is showing; the life tracker and unknown values are never kept. */
export function storeSub(tab: TabId, sub: string) {
  const s = tabOf(tab).subs.find((x) => x.id === sub);
  if (!s || s.fullScreen) return;
  try {
    localStorage.setItem(key(tab), sub);
  } catch {
    /* private window */
  }
}

/** Where a top tab links: its remembered sub-tab's path. */
export const tabHref = (tab: TabId) => subPath(tab, remembered(tab, storedSub(tab)));
