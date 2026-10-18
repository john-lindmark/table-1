// Friends, public profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md). Friendships are
// mutual; every part of the Library is private until its owner shares it (Account → Sharing). The server checks who
// may see what on every read, so this store only holds what came back. Trade matches put your wants next to friends'
// for-trade copies (and theirs next to yours) in trade_confirm's order. Same rules as
// apps/ios/Table1/Library/Friends.swift.
import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { isLibraryDemo } from "./libraryDemo";
import { loadTrades, saveTrade, type Trade, type TradeLine } from "./trades";
import type { Condition, Finish } from "./collection";

export type Visibility = "private" | "friends" | "public";
export const VISIBILITIES: Visibility[] = ["private", "friends", "public"];
export const VIS_LABEL: Record<Visibility, string> = { private: "Private", friends: "Friends", public: "Public" };
/** What it asks of a viewer (the server's vis_ok): public 0, friends 1, private 3 (only you). */
export const asks = (v: Visibility) => (v === "public" ? 0 : v === "friends" ? 1 : 3);

export type Relation = "self" | "friend" | "requested" | "incoming" | "blocked" | "none";

export interface Person {
  user_id: string;
  display_name: string;
  handle: string | null;
  avatar_url: string | null;
  since?: string;
  at?: string;
  shared_events?: number;
  relation?: Relation;
}

export interface FriendsList { friends: Person[]; incoming: Person[]; outgoing: Person[]; blocked: Person[] }

/* ── sharing ─────────────────────────────────────────────────────────── */

export type SharePart = "profile" | "library" | "all_cards" | "for_trade" | "wants" | "binders" | "decks" | "cubes" | "record";
export const LIBRARY_PARTS: SharePart[] = ["all_cards", "for_trade", "wants", "binders", "decks", "cubes"];
export const PART_LABEL: Record<SharePart, string> = {
  profile: "Profile", library: "Library", all_cards: "All cards", for_trade: "For trade", wants: "Wants", binders: "Binders",
  decks: "Decks", cubes: "Cubes", record: "Record",
};
export const PART_DETAIL: Record<SharePart, string> = {
  profile: "Who can open your profile at all",
  library: "The default for everything in it",
  all_cards: "Your whole collection",
  for_trade: "Copies in for-trade binders, as one list. Trade matches read this",
  wants: "Your wishlist, without max prices",
  binders: "The default for each binder",
  decks: "The default for each deck",
  cubes: "The default for each cube",
  record: "Lifetime wins, losses and draws",
};
/** Library parts can be "Same as Library". */
export const inherits = (p: SharePart) => p !== "profile" && p !== "library" && p !== "record";

export interface ShareItem { kind: "binder" | "deck" | "cube"; id: string; name: string; for_trade?: boolean; visibility: Visibility | null }

export interface Sharing {
  profile: Visibility;
  library: Visibility;
  all_cards: Visibility | null;
  for_trade: Visibility | null;
  wants: Visibility | null;
  binders: Visibility | null;
  decks: Visibility | null;
  cubes: Visibility | null;
  record: Visibility;
  items: ShareItem[];
}

export const DEFAULT_SHARING: Sharing = {
  profile: "friends", library: "private", all_cards: null, for_trade: null, wants: null, binders: null, decks: null, cubes: null,
  record: "private", items: [],
};

export const groupOf = (kind: ShareItem["kind"]): SharePart => (kind === "binder" ? "binders" : kind === "cube" ? "cubes" : "decks");

/** What a part is set to after following "Same as …" up the tree. */
export function effective(s: Sharing, p: SharePart): Visibility {
  return s[p] ?? (inherits(p) ? s.library : "private");
}

export const effectiveItem = (s: Sharing, item: ShareItem): Visibility => item.visibility ?? effective(s, groupOf(item.kind));

/** Who it actually reaches: the profile caps every part. */
export const reach = (s: Sharing, v: Visibility): Visibility => (asks(s.profile) >= asks(v) ? s.profile : v);
/** The part is set wider than the profile lets it go. */
export const capped = (s: Sharing, v: Visibility) => asks(s.profile) > asks(v);

/** The server's check: a viewer at `level` (3 you, 1 friend, 0 any other account, -1 blocked) sees it. */
export const sees = (level: number, profile: Visibility, part: Visibility) =>
  level >= 3 || (level >= 0 && level >= asks(profile) && level >= asks(part));

export function sharedCount(s: Sharing): number {
  const parts = [...LIBRARY_PARTS, "record" as SharePart].filter((p) => reach(s, effective(s, p)) !== "private").length;
  return parts + s.items.filter((i) => i.visibility != null && reach(s, effectiveItem(s, i)) !== "private").length;
}

export const sharingSummary = (s: Sharing) => {
  const n = sharedCount(s);
  return `Profile ${VIS_LABEL[s.profile].toLowerCase()} · ${n === 0 ? "nothing shared" : `${n} shared`}`;
};

/* ── profiles ────────────────────────────────────────────────────────── */

export interface ProfileData {
  user_id: string;
  display_name: string;
  handle: string | null;
  avatar_url: string | null;
  relation: Relation;
  friends_since: string | null;
  visible: boolean;
  sections: {
    all_cards?: { cards: number; printings?: number; value_usd?: number };
    for_trade?: { cards: number };
    wants?: { cards: number };
    binders?: { id: string; name: string; for_trade: boolean; cards: number }[];
    decks?: { id: string; name: string; format: string; cards: number }[];
    cubes?: { id: string; name: string; format: string; cards: number }[];
    record?: { match_wins: number; match_losses: number; match_draws: number; events_played: number };
  };
}

export const sectionCount = (p: ProfileData) =>
  [p.sections.all_cards, p.sections.for_trade, p.sections.wants, p.sections.record].filter(Boolean).length
  + (p.sections.binders?.length ?? 0) + (p.sections.decks?.length ?? 0) + (p.sections.cubes?.length ?? 0);

export type SectionKind = "all_cards" | "for_trade" | "wants" | "binder" | "deck" | "cube";

/** One row of profile_cards, whatever the section's shape. */
export interface ProfileCard {
  cardId: string | null;
  oracleId?: string;
  finish?: Finish | null;
  condition?: Condition;
  lang?: string;
  board?: string;
  qty: number;
}

/** all_cards [card, finish, qty] · for_trade / binder [card, finish, condition, lang, qty] · deck / cube
 *  [card, board, qty] · wants [oracle, card?, finish?, qty] */
export function parseCardRow(section: SectionKind, r: unknown[]): ProfileCard | null {
  const s = (i: number) => (typeof r[i] === "string" ? (r[i] as string) : null);
  const n = (i: number) => (typeof r[i] === "number" ? (r[i] as number) : null);
  switch (section) {
    case "all_cards": return n(2) == null ? null : { cardId: s(0), finish: s(1) as Finish, qty: n(2)! };
    case "for_trade": case "binder":
      return n(4) == null ? null : { cardId: s(0), finish: s(1) as Finish, condition: s(2) as Condition, lang: s(3) ?? "en", qty: n(4)! };
    case "deck": case "cube": return n(2) == null ? null : { cardId: s(0), board: s(1) ?? "main", qty: n(2)! };
    case "wants": return n(3) == null ? null : { oracleId: s(0) ?? "", cardId: s(1), finish: s(2) as Finish | null, qty: n(3)! };
  }
}

/* ── trade matches ───────────────────────────────────────────────────── */

export interface WantKey { oracle_id: string; card_id?: string | null; finish?: Finish | null }
export const wantTier = (w: WantKey) => (w.finish ? "exact" : w.card_id ? "printing" : "any");

export interface MatchLine {
  card_id: string;
  finish: Finish;
  condition: Condition;
  lang: string;
  binder_id?: string | null;
  qty: number;
  want: WantKey;
  usd: number | null;
  over_max?: boolean | null;
}

export interface TradeMatch extends Person {
  friend: boolean;
  they_have: MatchLine[];
  they_want: MatchLine[];
  have_copies: number;
  want_copies: number;
  have_usd: number;
  want_usd: number;
}

export const matchShort = (m: TradeMatch) =>
  [m.have_copies ? `Has ${m.have_copies}` : null, m.want_copies ? `${m.have_copies ? "wants" : "Wants"} ${m.want_copies}` : null]
    .filter(Boolean).join(" · ");
export const matchSummary = (m: TradeMatch) =>
  [m.have_copies ? `Has ${m.have_copies} you want` : null, m.want_copies ? `Wants ${m.want_copies} you have` : null]
    .filter(Boolean).join(" · ");

export interface WantIn { oracle_id: string; card_id?: string | null; finish?: Finish | null; qty: number; max_usd?: number | null }
export interface CopyIn {
  oracle_id: string; card_id: string; finish: Finish; condition: Condition; lang: string; binder_id?: string | null; qty: number;
  usd?: number | null;
}

/**
 * The server's matching (t1_private.want_match) in the browser, for the dev demo and the shared cases in
 * testdata/trade-matches. Wants for that printing and finish take copies first, then wants for that printing in any
 * finish, then wants for any printing; within a want NM first, then cheaper (no price last), then English. A copy is
 * used once; a want up to its qty.
 */
export function matchLines(wants: WantIn[], copies: CopyIn[]): MatchLine[] {
  const crank = (c: string) => ({ NM: 0, LP: 1, MP: 2, HP: 3 } as Record<string, number>)[c] ?? 4;
  const order = copies.map((_, i) => i).sort((a, b) => {
    const x = copies[a], y = copies[b];
    if (crank(x.condition) !== crank(y.condition)) return crank(x.condition) - crank(y.condition);
    const p = x.usd ?? null, q = y.usd ?? null;
    if (p != null && q != null && p !== q) return p - q;
    if (p != null && q == null) return -1;
    if (p == null && q != null) return 1;
    if ((x.lang === "en") !== (y.lang === "en")) return x.lang === "en" ? -1 : 1;
    return a - b;
  });
  const left = copies.map((c) => c.qty);
  const got = new Map<number, { qty: number; tier: number; want: WantIn }[]>();
  const tiers: [number, (w: WantIn) => boolean, (w: WantIn, c: CopyIn) => boolean][] = [
    [0, (w) => !!w.card_id && !!w.finish, (w, c) => c.card_id === w.card_id && c.finish === w.finish],
    [1, (w) => !!w.card_id && !w.finish, (w, c) => c.card_id === w.card_id],
    [2, (w) => !w.card_id, (w, c) => c.oracle_id === w.oracle_id],
  ];
  for (const [tier, isTier, meets] of tiers) {
    for (const w of wants) {
      if (w.qty <= 0 || !isTier(w)) continue;
      let need = w.qty;
      for (const i of order) {
        if (need <= 0) break;
        if (left[i] <= 0 || !meets(w, copies[i])) continue;
        const n = Math.min(need, left[i]);
        left[i] -= n;
        need -= n;
        got.set(i, [...(got.get(i) ?? []), { qty: n, tier, want: w }]);
      }
    }
  }
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return [...got.keys()].sort((a, b) => a - b).map((i) => {
    const c = copies[i], parts = got.get(i)!;
    const first = parts.reduce((m, p) => (p.tier < m.tier ? p : m));
    const over = parts.some((p) => p.want.max_usd != null && c.usd != null && c.usd > p.want.max_usd);
    return {
      card_id: c.card_id, finish: c.finish, condition: c.condition, lang: c.lang, binder_id: c.binder_id ?? null,
      qty: parts.reduce((n, p) => n + p.qty, 0),
      want: { oracle_id: first.want.oracle_id, card_id: first.want.card_id ?? null, finish: first.want.finish ?? null },
      usd: c.usd ?? null, over_max: over,
    };
  }).sort((a, b) => cmp(a.card_id, b.card_id) || cmp(a.finish, b.finish) || cmp(a.condition, b.condition) || cmp(a.lang, b.lang));
}

/** They have: under-max first, dearest first (the server's order). */
export const shownLines = (lines: MatchLine[]) => [...lines].sort((a, b) =>
  Number(!!a.over_max) - Number(!!b.over_max) || (b.usd ?? -1) - (a.usd ?? -1) || (a.card_id < b.card_id ? -1 : 1));

export const linesValue = (lines: MatchLine[], skipOverMax: boolean) =>
  lines.filter((l) => !(skipOverMax && l.over_max)).reduce((n, l) => n + l.qty * (l.usd ?? 0), 0);

/* ── store ───────────────────────────────────────────────────────────── */

interface State { list: FriendsList | null; sharing: Sharing | null; matches: TradeMatch[] | null; error: string | null; version: number }
let state: State = { list: null, sharing: null, matches: null, error: null, version: 0 };
const subs = new Set<() => void>();
const set = (patch: Partial<State>) => {
  state = { ...state, ...patch, version: state.version + 1 };
  subs.forEach((s) => s());
};

/** Dev `?demo` stand-in, filled by friendsDemo.ts. */
export interface FriendsDemo {
  list: FriendsList;
  sharing: Sharing;
  search(q: string): Person[];
  request(id: string): string;
  respond(id: string, accept: boolean): void;
  remove(id: string): void;
  block(id: string, on: boolean): void;
  profile(id: string): ProfileData;
  cards(id: string, section: SectionKind, item: string | null): ProfileCard[];
  matches(only: string | null): TradeMatch[];
}
let demo: FriendsDemo | null = null;
export function setFriendsDemo(d: FriendsDemo | null) {
  demo = d;
  set({ list: null, sharing: null, matches: null });
}
const demoOn = () => (isLibraryDemo() ? demo : null);
/** The dev demo before its friends are built: nothing to load yet (and no account to ask). */
const demoPending = () => isLibraryDemo() && !demo;
export const friendsNow = () => state;

export function useFriends() {
  return useSyncExternalStore((cb) => {
    subs.add(cb);
    return () => subs.delete(cb);
  }, () => state);
}

/** Loads the friends list (and optionally sharing / matches) once when a screen mounts. */
export function useFriendsLoad(what: { list?: boolean; sharing?: boolean; matches?: boolean }) {
  const s = useFriends();
  useEffect(() => {
    if (what.list) void loadFriends();
    if (what.sharing) void loadSharing();
    if (what.matches) void loadMatches();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return s;
}

export function resetFriends() {
  set({ list: null, sharing: null, matches: null, error: null });
}

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export async function loadFriends() {
  if (demoPending()) return;
  try {
    const d = demoOn();
    set({ list: d ? { ...d.list } : await rpc<FriendsList>("friends_list"), error: null });
  } catch (e) {
    set({ error: (e as Error).message });
  }
}

export async function searchPeople(query: string): Promise<Person[]> {
  const d = demoOn();
  if (d) return d.search(query);
  const q = query.trim();
  return rpc<Person[]>("friend_search", { p_query: q || null, p_limit: 30 });
}

/** Asks them (or accepts, if they asked you). `via`: search / played_with / email / profile. */
export async function requestFriend(userId: string, via: "search" | "played_with" | "profile"): Promise<string> {
  const d = demoOn();
  const status = d ? d.request(userId) : (await rpc<{ status: string }>("friend_request", { p_user_id: userId })).status;
  capture("friend_request_sent", { via });
  await loadFriends();
  return status;
}

export async function requestFriendByEmail(email: string) {
  if (!demoOn()) await rpc("friend_request_by_email", { p_email: email });
  capture("friend_request_sent", { via: "email" });
  await loadFriends();
}

export async function respondFriend(userId: string, accept: boolean) {
  const d = demoOn();
  if (d) d.respond(userId, accept);
  else await rpc("friend_respond", { p_user_id: userId, p_accept: accept });
  capture("friend_request_responded", { accepted: accept });
  await loadFriends();
}

/** Cancels your request, or unfriends. */
export async function removeFriend(userId: string) {
  const wasFriend = state.list?.friends.some((p) => p.user_id === userId) ?? false;
  const d = demoOn();
  if (d) d.remove(userId);
  else await rpc("friend_remove", { p_user_id: userId });
  capture(wasFriend ? "friend_removed" : "friend_request_cancelled");
  await loadFriends();
  if (state.matches) set({ matches: state.matches.filter((m) => m.user_id !== userId) });
}

export async function blockUser(userId: string, on: boolean) {
  const d = demoOn();
  if (d) d.block(userId, on);
  else await rpc("user_block", { p_user_id: userId, p_blocked: on });
  capture("user_blocked", { blocked: on });
  await loadFriends();
  if (on && state.matches) set({ matches: state.matches.filter((m) => m.user_id !== userId) });
}

export async function loadSharing() {
  if (demoPending()) return;
  try {
    const d = demoOn();
    set({ sharing: d ? { ...d.sharing } : await rpc<Sharing>("sharing_get"), error: null });
  } catch (e) {
    set({ error: (e as Error).message });
  }
}

async function saveSharing(next: Sharing, change: Record<string, unknown>, part: string, v: Visibility | null) {
  const before = state.sharing;
  set({ sharing: next }); // shows at once; put back if the server refuses
  try {
    const d = demoOn();
    if (d) d.sharing = next;
    else set({ sharing: await rpc<Sharing>("sharing_set", { p_settings: change }) });
    capture("sharing_changed", { part, visibility: v ?? "inherit" });
    set({ error: null });
  } catch (e) {
    set({ sharing: before, error: (e as Error).message });
  }
}

export async function setPart(p: SharePart, v: Visibility | null) {
  const s = state.sharing;
  if (!s || s[p] === v || (!inherits(p) && v == null)) return;
  await saveSharing({ ...s, [p]: v }, { [p]: v }, p, v);
}

export async function setItem(item: ShareItem, v: Visibility | null) {
  const s = state.sharing;
  if (!s || item.visibility === v) return;
  await saveSharing({ ...s, items: s.items.map((i) => (i.id === item.id ? { ...i, visibility: v } : i)) },
    { items: [{ kind: item.kind, id: item.id, visibility: v }] }, item.kind, v);
}

export async function fetchProfile(userId: string): Promise<ProfileData> {
  const d = demoOn();
  return d ? d.profile(userId) : rpc<ProfileData>("profile_view", { p_user_id: userId });
}

/** Every row of a section, 5000 at a time. */
export async function fetchProfileCards(userId: string, section: SectionKind, item: string | null): Promise<ProfileCard[]> {
  const d = demoOn();
  if (d) return d.cards(userId, section, item);
  const out: ProfileCard[] = [];
  for (let after = 0; ;) {
    const page = await rpc<{ rows: unknown[][]; more: boolean }>("profile_cards", {
      p_user_id: userId, p_section: section, p_id: item, p_after: after, p_limit: 5000,
    });
    for (const r of page.rows) {
      const c = parseCardRow(section, r);
      if (c) out.push(c);
    }
    after += page.rows.length;
    if (!page.more || !page.rows.length) return out;
  }
}

async function fetchMatches(only: string | null): Promise<TradeMatch[]> {
  const d = demoOn();
  if (d) return d.matches(only);
  return (await rpc<{ people: TradeMatch[] }>("trade_matches", { p_user_id: only })).people;
}

export async function loadMatches() {
  if (demoPending()) return;
  try {
    set({ matches: await fetchMatches(null), error: null });
  } catch (e) {
    set({ error: (e as Error).message });
  }
}

export async function matchWith(userId: string): Promise<TradeMatch | null> {
  const m = (await fetchMatches(userId))[0] ?? null;
  if (m && state.matches) {
    const i = state.matches.findIndex((x) => x.user_id === userId);
    set({ matches: i >= 0 ? state.matches.map((x) => (x.user_id === userId ? m : x)) : [...state.matches, m] });
  }
  return m;
}

/** A trade draft from the match with that person; returns its id (in the trades store once this returns). */
export async function startTradeFromMatch(m: TradeMatch): Promise<string> {
  let id: string;
  if (demoOn()) {
    const line = (l: MatchLine, give: boolean): TradeLine =>
      ({ card_id: l.card_id, finish: l.finish, condition: l.condition, lang: l.lang, qty: l.qty, binder_id: give ? l.binder_id ?? null : null });
    const t: Trade = await saveTrade(null, m.display_name, m.they_want.map((l) => line(l, true)), m.they_have.map((l) => line(l, false)));
    id = t.id;
  } else {
    id = (await rpc<Trade>("trade_match_start", { p_user_id: m.user_id, p_idempotency_key: crypto.randomUUID() })).id;
    await loadTrades();
  }
  capture("trade_started_from_match", { gives: m.want_copies, gets: m.have_copies });
  return id;
}
