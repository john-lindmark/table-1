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
import type { Board, Entry, ListKind } from "./lists";
import { rankingLabel } from "./rankings";

export type Visibility = "private" | "friends" | "public";
export const VISIBILITIES: Visibility[] = ["private", "friends", "public"];
/** "Anyone" always means anyone on Table 1; the UI never says "Public" (contract § UX rules 1). The wire value stays `public`. */
export const VIS_LABEL: Record<Visibility, string> = { private: "Private", friends: "Friends", public: "Anyone" };
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
  /** A profile's friends list (profile_friends): also the viewer's friend. */
  mutual?: boolean;
}

/** A request you sent: to an account (asked by id: a Person) or to an address (asked by email: `{email, at}` with no
 *  user_id, account or not, so the server never says whose it is). Older servers sent email asks as a Person. */
export interface SentRequest { key: string; person: Person | null; email: string | null; at: string | null }

export interface FriendsList { friends: Person[]; incoming: Person[]; outgoing: SentRequest[]; blocked: Person[] }

/** friends_list as sent: outgoing rows are a Person or `{email, at}`. */
export interface FriendsListWire { friends: Person[]; incoming: Person[]; outgoing: (Person | { email: string; at?: string })[]; blocked: Person[] }

export function sentRequest(r: Person | { email: string; at?: string; user_id?: null }): SentRequest {
  if ("user_id" in r && r.user_id) return { key: r.user_id, person: r, email: null, at: r.at ?? null };
  const email = (r as { email?: string }).email ?? "";
  return { key: `email:${email}`, person: null, email, at: r.at ?? null };
}

export const sentLabel = (r: SentRequest) => r.person?.display_name ?? r.email ?? "";

export function parseFriendsList(w: FriendsListWire): FriendsList {
  return { friends: w.friends ?? [], incoming: w.incoming ?? [], outgoing: (w.outgoing ?? []).map(sentRequest), blocked: w.blocked ?? [] };
}

/* ── sharing ─────────────────────────────────────────────────────────── */

export type SharePart = "profile" | "library" | "all_cards" | "for_trade" | "wants" | "binders" | "decks" | "cubes" | "record"
  | "friends" | "listed" | "rankings";
export const LIBRARY_PARTS: SharePart[] = ["all_cards", "for_trade", "wants", "binders", "decks", "cubes"];
export const PART_LABEL: Record<SharePart, string> = {
  profile: "Profile", library: "Library", all_cards: "All cards", for_trade: "For trade", wants: "Wants", binders: "Binders",
  decks: "Decks", cubes: "Cubes", record: "Record", friends: "Friends", listed: "You in friends' lists", rankings: "Rankings",
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
  friends: "Your list, on your profile",
  listed: "You, on friends' profiles",
  rankings: "Your cube and set rankings, except Only me",
};
/** Library parts can be "Same as Library". */
export const inherits = (p: SharePart) => LIBRARY_PARTS.includes(p);
/** Friends on profiles (§ Friends on profiles): missing from an older server, read as the server's defaults. */
const PART_DEFAULT: Partial<Record<SharePart, Visibility>> = { friends: "private", listed: "friends", rankings: "private" };

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
  /** Who sees your friends list on your profile; who sees you in your friends' lists. */
  friends?: Visibility;
  listed?: Visibility;
  /** Who sees your Rankings section (contract § Rankings on profiles); missing from an older server, which has none. */
  rankings?: Visibility;
  items: ShareItem[];
  /** Live share links (contract/share-links-2026-10-23.md); missing from a server without them. */
  links?: PartLink[];
}

/* ── share links (contract/share-links-2026-10-23.md) ───────────────────── */

/** "Anyone with the link" for one part: whoever holds it sees that part and nothing else, signed out too. */
export interface PartLink { part: SectionKind; id: string | null; token: string; created_at?: string }

/** A part of your Library you can share: All cards, For trade, Wants, or one binder, deck or cube. */
export interface ShareTarget { part: SectionKind; id: string | null; name: string | null; for_trade?: boolean }

export const linkUrl = (token: string) => `https://table-1.site/l/${token}`;
export const PART_TITLE: Record<string, string> = { all_cards: "All cards", for_trade: "For trade", wants: "Wants" };
export const targetTitle = (t: { part: string; name?: string | null }) => t.name ?? PART_TITLE[t.part] ?? t.part;
export const isItemPart = (part: string) => part === "binder" || part === "deck" || part === "cube";

/** What a link shows, for "Anyone with it sees …". */
export function shareWhat(part: string): string {
  switch (part) {
    case "all_cards": return "every card you own";
    case "for_trade": return "the copies in your for-trade binders";
    case "wants": return "your wishlist";
    case "binder": return "every card in this binder, with condition and language";
    default: return `every card in this ${part}`;
  }
}

/** The confirm before making a link. */
export function shareConfirm(part: string): string {
  let m = `Anyone with the link sees ${shareWhat(part)}, even without a Table 1 account. Nothing else on your profile shows. You can stop sharing it any time.`;
  if (part === "all_cards") m += " Your total value is never shown.";
  if (part === "wants") m += " Your max prices are never shown.";
  return m;
}

/** The same part on your profile, for people the settings already reach. */
export const profilePartUrl = (me: string, t: ShareTarget) => `https://table-1.site/u/${me}/${t.part}${t.id ? `/${t.id}` : ""}`;
export const linkMatches = (t: { part: string; id: string | null }, l: PartLink) => l.part === t.part && (l.id ?? null) === (t.id ?? null);
export const linkFor = (s: Sharing | null, t: { part: string; id: string | null }) => s?.links?.find((l) => linkMatches(t, l)) ?? null;

/** Who a target reaches on Table 1 once the profile cap applies. */
export function targetReach(s: Sharing, t: ShareTarget): Visibility {
  if (!isItemPart(t.part)) return reach(s, effective(s, t.part as SharePart));
  const item = s.items.find((i) => i.id === t.id) ?? { kind: t.part as ShareItem["kind"], id: t.id ?? "", name: t.name ?? "",
                                                     visibility: t.part === "deck" ? "private" as Visibility : null };
  return reach(s, effectiveItem(s, item));
}

/** What a link shows before its cards. */
export interface SharedLinkData {
  part: SectionKind; id?: string; name?: string; format?: string; for_trade?: boolean; cards: number;
  owner: { display_name: string; avatar_url?: string }; mine: boolean;
}
export const sharedTitle = (d: SharedLinkData) => targetTitle({ part: d.part, name: d.name ?? null });
export const sharedByline = (d: SharedLinkData) => (d.mine ? "Your link · anyone with it sees this" : `Shared by ${d.owner.display_name}`);

export const DEFAULT_SHARING: Sharing = {
  profile: "friends", library: "private", all_cards: null, for_trade: null, wants: null, binders: null, decks: null, cubes: null,
  record: "private", friends: "private", listed: "friends", rankings: "private", items: [],
};

export const groupOf = (kind: ShareItem["kind"]): SharePart => (kind === "binder" ? "binders" : kind === "cube" ? "cubes" : "decks");

/** What a part is set to after following "Same as …" up the tree. */
export function effective(s: Sharing, p: SharePart): Visibility {
  return s[p] ?? (inherits(p) ? s.library : PART_DEFAULT[p] ?? "private");
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
  const parts = [...LIBRARY_PARTS, "record" as SharePart, "friends" as SharePart, "rankings" as SharePart].filter((p) => reach(s, effective(s, p)) !== "private").length;
  return parts + s.items.filter((i) => i.visibility != null && reach(s, effectiveItem(s, i)) !== "private").length;
}

export const sharingSummary = (s: Sharing) => {
  const n = sharedCount(s);
  return `Profile ${VIS_LABEL[s.profile].toLowerCase()} · ${n === 0 ? "nothing shared" : `${n} shared`}`;
};

/** Who a part reaches once the profile cap applies (Record and the Library parts). */
export const reachOf = (s: Sharing, p: SharePart): Visibility => (p === "profile" ? s.profile : reach(s, effective(s, p)));
export const reachOfItem = (s: Sharing, item: ShareItem): Visibility => reach(s, effectiveItem(s, item));

/** The settings after one change, as the server would store them. */
export const withPart = (s: Sharing, p: SharePart, v: Visibility | null): Sharing => ({ ...s, [p]: v });
export const withItem = (s: Sharing, item: ShareItem, v: Visibility | null): Sharing =>
  ({ ...s, items: s.items.map((i) => (i.id === item.id && i.kind === item.kind ? { ...i, visibility: v } : i)) });

/** What newly reaches friends and anyone (contract § UX rules 4). Empty = only narrows or does nothing: no question. */
export interface Widening { friends: string[]; anyone: string[]; all_cards_to_anyone: boolean; profile_to_anyone: boolean }

const SHOWN_PARTS: [SharePart, string][] = [["profile", "your profile"], ["record", "your record"], ["friends", "your friends"],
  ["rankings", "your rankings"], ["all_cards", "All cards"], ["for_trade", "For trade"], ["wants", "Wants"]];
/** Widening also names you in your friends' lists (the Sharing summary lines don't: it shows on their profiles). */
const WIDENING_PARTS: [SharePart, string][] = [...SHOWN_PARTS.slice(0, 3), ["listed", "you in your friends' lists"], ...SHOWN_PARTS.slice(3)];

export function widening(a: Sharing, b: Sharing): Widening {
  const w: Widening = { friends: [], anyone: [], all_cards_to_anyone: false, profile_to_anyone: false };
  const add = (name: string, to: Visibility) => (to === "public" ? w.anyone : w.friends).push(name);
  for (const [p, name] of WIDENING_PARTS) {
    const ra = reachOf(a, p), rb = reachOf(b, p);
    if (asks(rb) >= asks(ra)) continue;
    add(name, rb);
    if (p === "all_cards" && rb === "public") w.all_cards_to_anyone = true;
    if (p === "profile" && rb === "public") w.profile_to_anyone = true;
  }
  const before = new Map(a.items.map((i) => [`${i.kind}:${i.id}`, i]));
  for (const kind of ["binder", "deck", "cube"] as const) {
    for (const to of ["public", "friends"] as const) {
      const opened = b.items.filter((i) => {
        if (i.kind !== kind || reachOfItem(b, i) !== to) return false;
        const old = before.get(`${i.kind}:${i.id}`);
        return asks(to) < asks(old ? reachOfItem(a, old) : "private");
      });
      if (opened.length === 1) add(opened[0].name, to);
      else if (opened.length > 1) add(`${opened.length} ${kind}s`, to);
    }
  }
  return w;
}

export const wideningEmpty = (w: Widening) => !w.friends.length && !w.anyone.length;
export const wideningTitle = (w: Widening) => (w.anyone.length ? "Show to anyone on Table 1?" : "Show to friends?");
export const wideningMessage = (w: Widening) => [
  w.anyone.length ? `Anyone on Table 1 will see: ${w.anyone.join(", ")}.` : null,
  w.friends.length ? `Friends will see: ${w.friends.join(", ")}.` : null,
  w.all_cards_to_anyone ? "Every card you own. Your total value is never shown." : null,
  w.profile_to_anyone ? "Your profile shows up when people search your name." : null,
].filter(Boolean).join("\n\n");

/** The line per audience at the top of Sharing (contract § UX rules 5): level 1 friends, 0 anyone. Name and photo always show. */
export function seesLine(s: Sharing, level: number): string {
  const names = ["your name and photo"];
  if (level >= asks(s.profile)) {
    for (const [p, name] of SHOWN_PARTS) if (p !== "profile" && sees(level, s.profile, effective(s, p))) names.push(name);
    for (const kind of ["binder", "deck", "cube"] as const) {
      const n = s.items.filter((i) => i.kind === kind && sees(level, s.profile, effectiveItem(s, i))).length;
      if (n > 0) names.push(`${n} ${kind}${n === 1 ? "" : "s"}`);
    }
  }
  return `${level >= 1 ? "Friends see: " : "Anyone on Table 1 sees: "}${names.join(", ")}.`;
}

/** Your own profile as a friend (level 1) or anyone (level 0) would get it from profile_view (contract § UX rules 5). */
export function viewAs(d: ProfileData, s: Sharing, level: number): ProfileData {
  const visible = level >= asks(s.profile);
  const base: ProfileData = { ...d, relation: level >= 1 ? "friend" : "none", visible, sections: {} };
  if (!visible) return base;
  const ok = (v: Visibility) => sees(level, s.profile, v);
  const items = new Map(s.items.map((i) => [i.id, i]));
  const itemOk = (id: string, group: SharePart) => {
    const i = items.get(id);
    return ok(i ? effectiveItem(s, i) : effective(s, group));
  };
  const src = d.sections;
  const tradeOk = ok(effective(s, "for_trade"));
  const tradeBinders = (src.binders ?? []).filter((b) => b.for_trade && (tradeOk || itemOk(b.id, "binders")));
  const all = src.all_cards && ok(effective(s, "all_cards")) ? { cards: src.all_cards.cards, printings: src.all_cards.printings } : undefined;
  return {
    ...base,
    sections: {
      ...(all ? { all_cards: all } : {}),
      ...(tradeBinders.length ? { for_trade: { cards: tradeBinders.reduce((n, b) => n + b.cards, 0) } } : {}),
      ...(src.wants && ok(effective(s, "wants")) ? { wants: src.wants } : {}),
      binders: (src.binders ?? []).filter((b) => itemOk(b.id, "binders")),
      decks: (src.decks ?? []).filter((l) => itemOk(l.id, "decks")),
      cubes: (src.cubes ?? []).filter((l) => itemOk(l.id, "cubes")),
      ...(src.record && ok(s.record) ? { record: src.record } : {}),
      // How many a viewer would see depends on each friend's own setting, which isn't yours to know.
      ...(ok(effective(s, "friends")) ? { friends: {} } : {}),
      // Shared rankings only; a ranking of one of your cubes only while that cube reaches them.
      ...(src.rankings && ok(effective(s, "rankings"))
        ? { rankings: src.rankings.filter((r) => r.sharing !== "private" && (r.subject.kind !== "list" || itemOk(r.subject.id, "cubes"))) }
        : {}),
    },
  };
}

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
    /** value_usd: your own profile only (older servers sent it to anyone who saw All cards). */
    all_cards?: { cards: number; printings?: number; value_usd?: number };
    for_trade?: { cards: number };
    wants?: { cards: number };
    binders?: { id: string; name: string; for_trade: boolean; cards: number }[];
    decks?: { id: string; name: string; format: string; cards: number }[];
    cubes?: { id: string; name: string; format: string; cards: number }[];
    record?: { match_wins: number; match_losses: number; match_draws: number; events_played: number };
    /** The friends list reaches you; mutual: how many shown are your friends too (missing in View as). */
    friends?: { mutual?: number };
    /** Rankings the viewer may open, newest first (contract § Rankings on profiles). */
    rankings?: ProfileRanking[];
  };
}

/** A ranking on a profile: as Rankings lists it, plus what it ranks (a cube by list id, or a set as `set:<KEY>`). */
export interface ProfileRanking {
  id: string; name: string; sharing: "cube" | "private"; mine: boolean; top: number; ranked: number;
  sorted?: number; categories?: number; updated_at?: string;
  subject: { id: string; kind: "list" | "set" | "cube"; name: string; set?: string | null };
}

/** The collection's value, shown on your own profile only. */
export const profileValue = (p: ProfileData): number | null => (p.relation === "self" ? p.sections.all_cards?.value_usd ?? null : null);

export const sectionCount = (p: ProfileData) =>
  [p.sections.all_cards, p.sections.for_trade, p.sections.wants, p.sections.record, p.sections.friends].filter(Boolean).length
  + (p.sections.binders?.length ?? 0) + (p.sections.decks?.length ?? 0) + (p.sections.cubes?.length ?? 0) + (p.sections.rankings?.length ?? 0);

/** A ranking's row on a profile, under its subject's name: the label, how far it is, and Only me on your own. */
export const profileRankingDetail = (r: Pick<ProfileRanking, "name" | "sharing" | "mine" | "top" | "ranked">) =>
  [rankingLabel(r.name), `${r.ranked}/${r.top} ranked`, r.mine && r.sharing === "private" ? "Only me" : null].filter(Boolean).join(" · ");

export type SectionKind = "all_cards" | "for_trade" | "wants" | "binder" | "deck" | "cube";

/* ── friends on profiles (contract § Friends on profiles; cases in testdata/sharing/cases.json `profile_friends`) ── */

/** The Friends row on someone's profile: "3 mutual", or nothing. */
export const friendsDetail = (mutual: number | null | undefined) => (mutual && mutual > 0 ? `${mutual} mutual` : null);
/** The Friends row on your own profile: who it reaches. */
export const friendsOwnDetail = (reach: Visibility) =>
  reach === "private" ? "Only you" : reach === "friends" ? "Seen by friends" : "Seen by anyone";
/** One person in the list: "You", "Mutual friend", or their handle. */
export const friendRowDetail = (p: Person) =>
  p.relation === "self" ? "You" : p.mutual ? "Mutual friend" : p.handle ? `@${p.handle}` : null;

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

/* ── shared decks and cubes (contract/shared-lists-grouping-2026-10-20.md §1) ───────────────────────────── */

export const sharedListKind = (section: SectionKind): ListKind | null => (section === "deck" ? "deck" : section === "cube" ? "cube" : null);

/** The shared rows as list lines (profile_cards sends no finish, so copies are non-foil), merged per card and board. */
export function sharedEntries(rows: ProfileCard[]): Entry[] {
  const by = new Map<string, Entry>();
  for (const r of rows) {
    if (!r.cardId || r.qty <= 0) continue;
    const board = (r.board ?? "main") as Board;
    const key = `${board}|${r.cardId}`;
    const e = by.get(key);
    if (e) e.qty += r.qty;
    else by.set(key, { cardId: r.cardId, board, qty: r.qty });
  }
  return [...by.values()];
}

/** A shared deck's count leaves out Considering, like the profile row. */
export const sharedCardCount = (rows: ProfileCard[], kind: ListKind | null) =>
  rows.filter((r) => kind !== "deck" || r.board !== "maybe").reduce((n, r) => n + r.qty, 0);

/** The first version's note on a copy, so its history says where it came from (owner null: your own profile). */
export const copyNote = (owner: string | null, name: string) => (owner ? `Copied from ${owner}'s ${name}` : `Copied from ${name}`);

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
  requestByEmail(email: string): void;
  cancelEmail(email: string): void;
  block(id: string, on: boolean): void;
  profile(id: string): ProfileData;
  cards(id: string, section: SectionKind, item: string | null): ProfileCard[];
  friendsOf(id: string): Person[];
  matches(only: string | null): TradeMatch[];
  shared(token: string): SharedLinkData;
  sharedCards(token: string): ProfileCard[];
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
    set({ list: d ? { ...d.list } : parseFriendsList(await rpc<FriendsListWire>("friends_list")), error: null });
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
  const d = demoOn();
  if (d) d.requestByEmail(email);
  else await rpc("friend_request_by_email", { p_email: email });
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

/** Cancels a request you made by email (an `{email, at}` row in Sent). */
export async function cancelEmailRequest(email: string) {
  const d = demoOn();
  if (d) d.cancelEmail(email);
  else await rpc<{ removed: boolean }>("friend_cancel_email", { p_email: email });
  capture("friend_request_cancelled", { via: "email" });
  await loadFriends();
}

/** Cancels a row in Sent, whichever way it was asked. */
export const cancelSent = (r: SentRequest) => (r.person ? removeFriend(r.person.user_id) : cancelEmailRequest(r.email ?? ""));

export async function blockUser(userId: string, on: boolean) {
  const d = demoOn();
  if (d) d.block(userId, on);
  else await rpc("user_block", { p_user_id: userId, p_blocked: on });
  capture("user_blocked", { blocked: on });
  await loadFriends();
  if (on && state.matches) set({ matches: state.matches.filter((m) => m.user_id !== userId) });
}

/* ── report (contract § UX rules 6) ──────────────────────────────────── */

export type ReportReason = "spam" | "harassment" | "offensive_profile" | "offensive_content" | "other";
export const REPORT_REASONS: { value: ReportReason; label: string }[] = [
  { value: "spam", label: "Spam or fake account" },
  { value: "harassment", label: "Harassment" },
  { value: "offensive_profile", label: "Offensive name or photo" },
  { value: "offensive_content", label: "Offensive deck, binder or cube name" },
  { value: "other", label: "Something else" },
];
/** Also block them: on for harassment, off otherwise. */
export const reportBlocksByDefault = (r: ReportReason) => r === "harassment";
export const REPORT_NOTE_MAX = 500;
export type ReportFrom = "profile" | "friends" | "request" | "search" | "trade_match";
export interface ReportContext { from: ReportFrom; kind?: "binder" | "deck" | "cube"; id?: string }
export const BLOCK_MESSAGE = "They won't be able to find you, see your Library or ask to be friends. They won't be told. "
  + "You'll still both be in any event you're both playing.";
export const REPORT_THANKS = "Thanks. We'll look into it. They won't know you reported them.";

export async function reportUser(userId: string, reason: ReportReason, note: string, context: ReportContext, block: boolean) {
  const n = note.trim().slice(0, REPORT_NOTE_MAX);
  if (!demoOn()) {
    await rpc("user_report", { p_user_id: userId, p_reason: reason, p_note: n || null, p_context: context, p_block: block });
  }
  capture("user_reported", { reason, from: context.from, blocked: block });
  if (block) {
    if (demoOn()) demoOn()!.block(userId, true);
    await loadFriends();
    if (state.matches) set({ matches: state.matches.filter((m) => m.user_id !== userId) });
  }
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
  const known = s.items.some((i) => i.id === item.id && i.kind === item.kind);
  await saveSharing(known ? withItem(s, item, v) : { ...s, items: [...s.items, { ...item, visibility: v }] },
    { items: [{ kind: item.kind, id: item.id, visibility: v }] }, item.kind, v);
}

/** Several parts to one value in one save (the once-only offers). */
export async function setAll(parts: SharePart[], v: Visibility) {
  const s = state.sharing;
  if (!s) return;
  const next = parts.reduce((acc, p) => withPart(acc, p, v), s);
  await saveSharing(next, Object.fromEntries(parts.map((p) => [p, v])), parts.join(","), v);
}

/** A deck, cube or binder as Sharing knows it (a new one isn't in sharing_get yet: Same as its group). */
export const shareItemOf = (s: Sharing, kind: ShareItem["kind"], id: string, name: string, forTrade?: boolean): ShareItem =>
  s.items.find((i) => i.kind === kind && i.id === id) ?? { kind, id, name, for_trade: forTrade, visibility: null };

/** An offer made due by an action elsewhere (marking a binder For trade), shown over that screen by <DueOffer>. */
let dueOffer: SharingOffer | null = null;
const dueListeners = new Set<() => void>();
export const offerDue = () => dueOffer;
export function setOfferDue(o: SharingOffer | null) { dueOffer = o; dueListeners.forEach((f) => f()); }
export const subscribeOfferDue = (f: () => void) => { dueListeners.add(f); return () => void dueListeners.delete(f); };

/** For trade reaches no one (neither the part nor any for-trade binder) and the offer hasn't been answered. */
export async function offerForTradeIfDue() {
  const me = (await supabase.auth.getSession()).data.session?.user.id ?? null;
  if (offerAnswered("for_trade", me)) return;
  if (!state.sharing) await loadSharing();
  const s = state.sharing;
  if (!s) return;
  if (reachOf(s, "for_trade") === "private" && !s.items.some((i) => i.for_trade && reachOfItem(s, i) !== "private")) setOfferDue("for_trade");
}

/** The once-only "share with friends?" offers (contract § UX rules 8), answered per account on this browser. */
export type SharingOffer = "for_trade" | "matches" | "record";
const offerKey = (o: SharingOffer, userId: string | null) => `table1.sharing_offer.${o}.${userId ?? "none"}`;
export function offerAnswered(o: SharingOffer, userId: string | null): boolean {
  try { return localStorage.getItem(offerKey(o, userId)) === "1"; } catch { return true; }
}
export function answerOffer(o: SharingOffer, userId: string | null, accepted: boolean) {
  try { localStorage.setItem(offerKey(o, userId), "1"); } catch { /* private window: asked again next time */ }
  capture("sharing_offer", { offer: o, accepted });
}

export async function fetchProfile(userId: string): Promise<ProfileData> {
  const d = demoOn();
  return d ? d.profile(userId) : rpc<ProfileData>("profile_view", { p_user_id: userId });
}

/** The friends behind a profile's Friends section that reach you: mutual first, then by name (profile_friends). */
export async function fetchProfileFriends(userId: string): Promise<Person[]> {
  const d = demoOn();
  if (d) return d.friendsOf(userId);
  const out: Person[] = [];
  for (let after = 0; ;) {
    const page = await rpc<{ rows: Person[]; more: boolean }>("profile_friends", { p_user_id: userId, p_after: after, p_limit: 500 });
    out.push(...page.rows);
    after += page.rows.length;
    if (!page.more || !page.rows.length) return out;
  }
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

export async function makeLink(t: ShareTarget, fresh = false): Promise<PartLink> {
  const d = demoOn();
  const old = linkFor(state.sharing, t);
  const l: PartLink = d
    ? (!fresh && old) || { part: t.part, id: t.id, token: crypto.randomUUID().replace(/-/g, "").slice(0, 22) }
    : await rpc<PartLink>("share_link_create", { p_part: t.part, p_id: t.id, p_new: fresh });
  if (state.sharing) {
    const next = { ...state.sharing, links: [...(state.sharing.links ?? []).filter((x) => !linkMatches(t, x)), l] };
    if (d) d.sharing = next;
    set({ sharing: next });
  }
  capture("share_link_created", { part: t.part, new: fresh });
  return l;
}

/** Stop sharing the link: it stops working for anyone holding it. The part's setting doesn't change. */
export async function stopLink(t: ShareTarget) {
  const d = demoOn();
  if (!d) await rpc("share_link_revoke", { p_part: t.part, p_id: t.id });
  if (state.sharing) {
    const next = { ...state.sharing, links: (state.sharing.links ?? []).filter((x) => !linkMatches(t, x)) };
    if (d) d.sharing = next;
    set({ sharing: next });
  }
  capture("share_link_stopped", { part: t.part });
}

/** What a link shows (signed out too: the server checks the link). */
export async function fetchShared(token: string): Promise<SharedLinkData> {
  const d = demoOn();
  return d ? d.shared(token) : rpc<SharedLinkData>("shared_view", { p_token: token });
}

/** Every card behind a link, 5000 at a time, in profile_cards' shapes. */
export async function fetchSharedCards(token: string, part: SectionKind): Promise<ProfileCard[]> {
  const d = demoOn();
  if (d) return d.sharedCards(token);
  const out: ProfileCard[] = [];
  for (let after = 0; ;) {
    const page = await rpc<{ rows: unknown[][]; more: boolean }>("shared_cards", { p_token: token, p_after: after, p_limit: 5000 });
    for (const r of page.rows) {
      const c = parseCardRow(part, r);
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
