import { useSyncExternalStore } from "react";

/**
 * Desktop web (contract/web-desktop-2026-10-22.md). From DESKTOP_MIN_WIDTH up, a sidebar replaces the
 * Events | Collection | Insights | Account tabs, screens sit in a centered column, and the busiest screens split into two
 * columns. Phones and tablets keep the mobile layout unchanged.
 */
export const DESKTOP_MIN_WIDTH = 1024;
export const DESKTOP_QUERY = `(min-width: ${DESKTOP_MIN_WIDTH}px)`;
/** A mouse or trackpad: hover previews only make sense with one. */
const HOVER_QUERY = "(hover: hover) and (pointer: fine)";

function matches(query: string): boolean {
  return typeof window !== "undefined" && !!window.matchMedia?.(query).matches;
}

/** One listener per query however many components ask (every card row asks whether to preview). */
const media = new Map<string, { list: MediaQueryList; subscribe: (f: () => void) => () => void }>();
function mediaFor(query: string) {
  let m = media.get(query);
  if (!m) {
    const list = window.matchMedia(query);
    m = {
      list,
      subscribe: (f) => {
        list.addEventListener("change", f);
        return () => list.removeEventListener("change", f);
      },
    };
    media.set(query, m);
  }
  return m;
}

const noSubscribe = () => () => {};
function useMedia(query: string): boolean {
  const m = typeof window !== "undefined" && "matchMedia" in window ? mediaFor(query) : null;
  return useSyncExternalStore(m?.subscribe ?? noSubscribe, () => m?.list.matches ?? false, () => false);
}

/** True on a desktop-width window. Layout that CSS alone can't express (reordering, extra columns) reads this. */
export function useDesktop(): boolean {
  return useMedia(DESKTOP_QUERY);
}

/** True on a desktop-width window with a mouse or trackpad. */
export function useHoverPreview(): boolean {
  const wide = useMedia(DESKTOP_QUERY);
  const hover = useMedia(HOVER_QUERY);
  return wide && hover;
}

/** "desktop" or "mobile", for analytics. */
export function layoutNow(): "desktop" | "mobile" {
  return matches(DESKTOP_QUERY) ? "desktop" : "mobile";
}

/** The card hover preview's size, so it can flip to the pointer's other side near the window's edge. */
export const PEEK_W = 250;
const PEEK_H = Math.round(PEEK_W * (680 / 488));
const GAP = 24;

/** Where the preview goes for a pointer at (x, y) in a w × h window: right of the pointer unless that runs off
 *  the edge, and never above or below the window. */
export function peekPosition(x: number, y: number, w: number, h: number) {
  const left = x + GAP + PEEK_W <= w ? x + GAP : Math.max(8, x - GAP - PEEK_W);
  const top = Math.min(Math.max(8, y - PEEK_H / 2), Math.max(8, h - PEEK_H - 8));
  return { left, top };
}

export type NavKey =
  | "events" | "find" | "life"
  | "library" | "cards" | "add" | "binders" | "wants" | "decks" | "cubes" | "rankings" | "trades" | "matches" | "import"
  | "constructed" | "limited"
  | "account" | "friends" | "sharing";

export interface NavItem {
  key: NavKey;
  title: string;
  to: string;
}

/** The sidebar, top to bottom: Play, then the Collection tab's screens, Insights, then Account. */
export const NAV_GROUPS: { title: string; items: NavItem[] }[] = [
  {
    title: "Play",
    items: [
      { key: "events", title: "Events", to: "/" },
      { key: "find", title: "Find", to: "/find" },
      { key: "life", title: "Life tracker", to: "/life" },
    ],
  },
  {
    title: "Collection",
    items: [
      { key: "library", title: "Overview", to: "/library" },
      { key: "cards", title: "All cards", to: "/library/cards" },
      { key: "add", title: "Add cards", to: "/library/add" },
      { key: "binders", title: "Binders", to: "/library/binders" },
      { key: "wants", title: "Wants", to: "/library/wants" },
      { key: "decks", title: "Decks", to: "/library/decks" },
      { key: "cubes", title: "Cubes", to: "/library/cubes" },
      { key: "rankings", title: "Rankings", to: "/library/rankings" },
      { key: "trades", title: "Trades", to: "/library/trades" },
      { key: "matches", title: "Trade matches", to: "/library/matches" },
      { key: "import", title: "Import and export", to: "/library/import" },
    ],
  },
  {
    title: "Insights",
    items: [
      { key: "constructed", title: "Constructed", to: "/insights" },
      { key: "limited", title: "Arena draft", to: "/insights/limited" },
    ],
  },
  {
    title: "Account",
    items: [
      { key: "account", title: "Account", to: "/me" },
      { key: "friends", title: "Friends", to: "/friends" },
      { key: "sharing", title: "Sharing", to: "/sharing" },
    ],
  },
];

/**
 * The sidebar item a screen belongs to, so it stays marked on screens pushed above it (a deck under Decks, a
 * card under All cards). `listKind` says whether a list id is a deck or a cube when it's known locally.
 */
export function navKeyFor(pathname: string, listKind?: (id: string) => "deck" | "cube" | undefined): NavKey | null {
  const p = pathname.replace(/\/+$/, "") || "/";
  if (p === "/" || /^\/(e|p|join|j)\/./.test(p)) return "events";
  if (p === "/life" || p.startsWith("/life/")) return "life";
  // Finding events, a league and a format board (contract/public-events-leagues-2026-11-13.md).
  if (p === "/find" || p.startsWith("/league/") || p.startsWith("/boards/")) return "find";
  if (p === "/me") return "account";
  if (p === "/sharing") return "sharing";
  if (p === "/friends" || p.startsWith("/friends/") || p.startsWith("/u/")) return "friends";
  if (p === "/insights/limited" || p.startsWith("/insights/limited/")) return "limited";
  if (p === "/insights" || p.startsWith("/insights/")) return "constructed";
  if (p === "/library") return "library";
  if (p === "/library/cards" || p.startsWith("/library/card/")) return "cards";
  if (p === "/library/add") return "add";
  if (p === "/library/binders" || p.startsWith("/library/binder/")) return "binders";
  if (p === "/library/wants") return "wants";
  if (p === "/library/decks" || p === "/library/find" || p === "/library/import/deck") return "decks";
  if (p === "/library/cubes" || p === "/library/import/cube") return "cubes";
  if (p === "/library/rankings" || p.startsWith("/library/ranking/") || /^\/library\/list\/[^/]+\/rankings$/.test(p)) return "rankings";
  if (p === "/library/trades" || p.startsWith("/library/trade/")) return "trades";
  if (p === "/library/matches" || p.startsWith("/library/match/")) return "matches";
  if (p === "/library/import") return "import";
  const list = p.match(/^\/library\/list\/([^/]+)/);
  if (list) return listKind?.(list[1]) === "cube" ? "cubes" : "decks";
  if (p.startsWith("/library/")) return "library";
  return null;
}

/**
 * Whether a path gets the desktop sidebar (signed in). Not on the full-screen life tracker, sign-in, the legal
 * pages, the shared standings page, the TV display or dev demos.
 */
export function sidebarOn(pathname: string): boolean {
  const p = pathname.replace(/\/+$/, "") || "/";
  if (p === "/life" || p.startsWith("/life/")) return false;
  if (["/sign-in", "/terms", "/privacy", "/delete-account"].includes(p)) return false;
  // Stripe's return pages (/pay/…) are plain pages, like the shared standings and the TV display.
  if (/^\/(auth|s|d|dev|pay)\//.test(p)) return false;
  return true;
}

/** "/" focuses the screen's search, unless the person is already typing somewhere. */
export function isTypingTarget(el: Element | null): boolean {
  if (!el) return false;
  const tag = el.tagName;
  if (tag === "TEXTAREA" || tag === "SELECT") return true;
  if (tag === "INPUT") {
    const type = (el as HTMLInputElement).type;
    return !["button", "checkbox", "radio", "range", "submit", "reset", "file", "color"].includes(type);
  }
  return (el as HTMLElement).isContentEditable === true;
}
