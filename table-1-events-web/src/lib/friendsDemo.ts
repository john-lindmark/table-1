// Dev server only (`?demo`): friends, profiles, sharing and trade matches on the Library demo, as the iOS Debug demo
// does. Two friends hold for-trade copies of the demo account's wants and want some of its for-trade copies; one
// player from an event shares For trade publicly. Matching runs matchLines, the same rules as the server. Sent holds one
// request by id and one by email (an address only, as the server shows every email ask).
import { applyWants, binderById, bindersNow, liveWants, allocItemKey, type Alloc, type WantOp } from "./binders";
import { coverPrinting, oracleIndexById, type Catalog } from "./catalog";
import { loadDemoLists } from "./libraryDemo";
import { loadPrices, usdPrice } from "./prices";
import {
  DEFAULT_SHARING, linesValue, matchLines, sees, setFriendsDemo, shownLines, type CopyIn, type FriendsDemo, type FriendsList,
  sentRequest, type Person, type ProfileCard, type ProfileData, type Relation, type SectionKind, type Sharing, type SharedLinkData, type TradeMatch, type Visibility,
  type WantIn,
} from "./friends";

const id = (n: number) => `d0000000-0000-0000-0000-0000000f${String(n).padStart(4, "0")}`;
export const DEMO_FRIEND = id(1);
/** `/l/<DEMO_LINK>?demo`: a share link to Mara's deck. */
export const DEMO_LINK = "demoMaraPublicDeckLink";

interface Someone {
  person: Person;
  profile: Visibility;
  forTrade: Visibility;
  wants: Visibility;
  copies: CopyIn[];
  wanted: WantIn[];
  decks: { id: string; name: string; format: string; cards: number }[];
  deckEntries: Map<string, ProfileCard[]>;
  record?: { match_wins: number; match_losses: number; match_draws: number; events_played: number };
}

const p = (n: number, name: string, extra: Partial<Person> = {}): Person =>
  ({ user_id: id(n), display_name: name, handle: null, avatar_url: null, ...extra });

class Demo implements FriendsDemo {
  list: FriendsList = {
    friends: [p(1, "Mara Quinn", { handle: "maraq" }), p(2, "Theo Vance")],
    incoming: [p(4, "Sam Okafor")], blocked: [],
    outgoing: [sentRequest({ email: "jo.ng@example.com", at: "2026-10-18T09:30:00Z" }), sentRequest(p(5, "Lee Park"))],
  };
  sharing: Sharing = { ...DEFAULT_SHARING, for_trade: "friends", wants: "friends" };
  private people = new Map<string, Someone>();
  private playedWith = [p(3, "Ines Ruiz", { shared_events: 3 }), p(6, "Kai Brandt", { shared_events: 2 }), p(4, "Sam Okafor", { shared_events: 1 })];

  async build(c: Catalog) {
    const b = bindersNow();
    const lists = await loadDemoLists();
    this.sharing.items = [
      ...b.binders.map((x) => ({ kind: "binder" as const, id: x.id, name: x.name, for_trade: x.for_trade, visibility: null })),
      ...lists.map((l) => ({ kind: l.kind, id: l.id, name: l.name, visibility: null })),
    ];
    if (!liveWants().length) {
      // Three wants from the demo lists, as the iOS demo seeds them: any printing, one with a max price, one printing.
      const ids = [...new Set(lists.flatMap((l) => l.versions[l.versions.length - 1]?.entries.map((e) => e.cardId) ?? []))].sort().slice(0, 3);
      const ops: WantOp[] = ids.flatMap((cardId, i) => {
        const pi = c.printingIndex.get(cardId);
        return pi == null ? [] : [{ oracle_id: c.oId[c.pOracle[pi]], card_id: i === 2 ? cardId : null, qty: 2 - (i % 2), max_usd: i === 1 ? 5 : null }];
      });
      if (ops.length) await applyWants(ops);
    }
    const wants = liveWants();
    const trade = [...b.allocs.values()].filter((a) => a.qty > 0 && binderById(a.binderId)?.for_trade);
    await loadPrices([...trade.map((a) => a.cardId), ...wants.flatMap((w) => (w.cardId ? [w.cardId] : []))]);
    const copy = (cardId: string, oracle: string, qty: number, condition: CopyIn["condition"] = "NM"): CopyIn =>
      ({ oracle_id: oracle, card_id: cardId, finish: "nonfoil", condition, lang: "en", qty, usd: usdPrice(cardId, "nonfoil", condition) });
    const mara: CopyIn[] = [], theo: CopyIn[] = [];
    const coverIds: string[] = [];
    wants.forEach((w, i) => {
      const oi = oracleIndexById(c, w.oracleId);
      if (oi < 0) return;
      const cardId = w.cardId ?? c.pId[coverPrinting(c, oi)];
      coverIds.push(cardId);
      (i % 2 === 0 ? mara : theo).push(copy(cardId, w.oracleId, i % 2 === 0 ? w.qty + 1 : 1, i % 2 === 0 ? "NM" : "LP"));
    });
    await loadPrices(coverIds);
    for (const x of [...mara, ...theo]) x.usd = usdPrice(x.card_id, "nonfoil", x.condition);
    const oracleOf = (a: Alloc) => {
      const pi = c.printingIndex.get(a.cardId);
      return pi == null ? null : c.oId[c.pOracle[pi]];
    };
    const tradeOracles = trade.sort((a, b) => (a.cardId < b.cardId ? -1 : 1)).map(oracleOf).filter((o): o is string => !!o);
    const deck = lists.find((l) => l.kind === "deck");
    const entries = deck?.versions[deck.versions.length - 1]?.entries ?? [];
    this.people.set(id(1), {
      person: this.list.friends[0], profile: "friends", forTrade: "friends", wants: "friends", copies: mara,
      wanted: tradeOracles.slice(0, 2).map((o) => ({ oracle_id: o, qty: 1 })),
      decks: deck ? [{ id: id(9001), name: "Mono-red prowess", format: deck.format,
                       cards: entries.filter((e) => e.board !== "maybe").reduce((n, e) => n + e.qty, 0) }] : [],
      deckEntries: new Map([[id(9001), entries.map((e) => ({ cardId: e.cardId, board: e.board, qty: e.qty }))]]),
      record: { match_wins: 23, match_losses: 14, match_draws: 2, events_played: 11 },
    });
    this.people.set(id(2), {
      person: this.list.friends[1], profile: "friends", forTrade: "friends", wants: "friends", copies: theo,
      wanted: tradeOracles.slice(2, 3).map((o) => ({ oracle_id: o, qty: 2 })), decks: [], deckEntries: new Map(),
    });
    this.people.set(id(3), {
      person: this.playedWith[0], profile: "public", forTrade: "public", wants: "private",
      copies: mara.slice(0, 1).map((x) => ({ ...x, qty: 1, condition: "MP" })), wanted: [], decks: [], deckEntries: new Map(),
    });
  }

  relation(uid: string): Relation {
    const has = (l: Person[]) => l.some((x) => x.user_id === uid);
    const asked = this.list.outgoing.some((x) => x.person?.user_id === uid);
    return has(this.list.friends) ? "friend" : has(this.list.incoming) ? "incoming" : asked ? "requested"
      : has(this.list.blocked) ? "blocked" : "none";
  }

  private level = (uid: string) => (this.relation(uid) === "blocked" ? -1 : this.relation(uid) === "friend" ? 1 : 0);

  private person(uid: string): Person {
    return this.people.get(uid)?.person ?? [...this.list.incoming, ...this.list.outgoing.flatMap((x) => (x.person ? [x.person] : [])), ...this.list.blocked, ...this.playedWith]
      .find((x) => x.user_id === uid) ?? { ...p(7, "Nadia Stone", { handle: "nstone" }), user_id: uid };
  }

  search(q: string): Person[] {
    const t = q.trim().toLowerCase();
    const hits = [...this.playedWith, ...(t.length >= 2 ? [p(7, "Nadia Stone", { handle: "nstone", shared_events: 0 })] : [])];
    return hits.filter((x) => !t || x.display_name.toLowerCase().includes(t) || (x.handle ?? "").startsWith(t))
      .map((x) => ({ ...x, relation: this.relation(x.user_id) }));
  }

  request(uid: string) {
    const i = this.list.incoming.findIndex((x) => x.user_id === uid);
    if (i >= 0) {
      this.list.friends.push(...this.list.incoming.splice(i, 1));
      return "friends";
    }
    if (this.relation(uid) === "friend") return "friends";
    if (this.relation(uid) === "none") this.list.outgoing.unshift(sentRequest(this.person(uid)));
    return "requested";
  }

  respond(uid: string, accept: boolean) {
    const i = this.list.incoming.findIndex((x) => x.user_id === uid);
    if (i < 0) return;
    const [x] = this.list.incoming.splice(i, 1);
    if (accept) this.list.friends.push(x);
  }

  remove(uid: string) {
    this.list.friends = this.list.friends.filter((x) => x.user_id !== uid);
    this.list.outgoing = this.list.outgoing.filter((x) => x.person?.user_id !== uid);
  }

  /** An email ask shows as the address, account or not. */
  requestByEmail(email: string) {
    const e = email.toLowerCase();
    if (!this.list.outgoing.some((x) => x.email === e)) this.list.outgoing.unshift(sentRequest({ email: e, at: new Date().toISOString() }));
  }

  cancelEmail(email: string) {
    this.list.outgoing = this.list.outgoing.filter((x) => x.email !== email.toLowerCase());
  }

  block(uid: string, on: boolean) {
    if (on) {
      const x = this.person(uid);
      this.remove(uid);
      this.list.incoming = this.list.incoming.filter((y) => y.user_id !== uid);
      this.list.blocked.unshift(x);
    } else {
      this.list.blocked = this.list.blocked.filter((y) => y.user_id !== uid);
    }
  }

  profile(uid: string): ProfileData {
    const x = this.person(uid), s = this.people.get(uid), lv = this.level(uid);
    const base = { user_id: uid, display_name: x.display_name, handle: x.handle, avatar_url: null, relation: this.relation(uid) };
    if (!s) return { ...base, friends_since: null, visible: false, sections: {} };
    const visible = sees(lv, s.profile, "public");
    const sections: ProfileData["sections"] = {};
    if (visible) {
      sections.binders = [];
      if (sees(lv, s.profile, s.forTrade)) {
        const cards = s.copies.reduce((n, c) => n + c.qty, 0);
        sections.for_trade = { cards };
        sections.binders = [{ id: id(9002), name: "Trade binder", for_trade: true, cards }];
      }
      if (sees(lv, s.profile, s.wants)) sections.wants = { cards: s.wanted.reduce((n, w) => n + w.qty, 0) };
      sections.decks = lv >= 1 ? s.decks : [];
      sections.cubes = [];
      if (lv >= 1 && s.record) sections.record = s.record;
      if (lv >= 1 && uid === DEMO_FRIEND) sections.friends = { mutual: this.friendsOf(uid).filter((f) => f.mutual).length };
      // Mara's rankings in the rankings demo: her own cube's and a Limited set's.
      if (lv >= 1 && uid === DEMO_FRIEND) {
        sections.rankings = [
          { id: "d0000000-0000-0000-0000-0000000aa005", name: "My ranking", sharing: "cube", mine: false, top: 100, ranked: 0,
            subject: { id: "set:FRA", kind: "set", name: "Foundations Remastered", set: "FRA" } },
          { id: "d0000000-0000-0000-0000-0000000aa004", name: "Mara's own order", sharing: "cube", mine: false, top: 100, ranked: 0,
            subject: { id: "d0000000-0000-0000-0000-0000000fc001", kind: "list", name: "Mara's Legacy Cube" } },
        ];
      }
      // Older servers sent value_usd to everyone who sees All cards: the profile must still hide it.
      if (lv >= 1 && uid === DEMO_FRIEND) {
        sections.all_cards = { cards: s.copies.reduce((n, c) => n + c.qty, 0), printings: s.copies.length,
                               value_usd: s.copies.reduce((n, c) => n + c.qty * (c.usd ?? 0), 0) };
      }
    }
    return { ...base, friends_since: lv === 1 ? "2026-09-12T19:00:00Z" : null, visible, sections };
  }

  /** Mara shows her friends list to friends (Theo is yours too); nobody else shares theirs. */
  friendsOf(uid: string): Person[] {
    if (uid !== DEMO_FRIEND || this.level(uid) < 1) return [];
    const rows = [p(2, "Theo Vance"), p(3, "Ines Ruiz"), p(7, "Nadia Stone", { handle: "nstone" })]
      .map((x) => ({ ...x, relation: this.relation(x.user_id), mutual: this.relation(x.user_id) === "friend" }));
    return [...rows.filter((x) => x.mutual), ...rows.filter((x) => !x.mutual)];
  }

  cards(uid: string, section: SectionKind, item: string | null): ProfileCard[] {
    const s = this.people.get(uid);
    if (!s) return [];
    if (section === "all_cards") return s.copies.map((c) => ({ cardId: c.card_id, finish: c.finish, qty: c.qty }));
    if (section === "for_trade" || section === "binder") {
      return s.copies.map((c) => ({ cardId: c.card_id, finish: c.finish, condition: c.condition, lang: c.lang, qty: c.qty }));
    }
    if (section === "wants") return s.wanted.map((w) => ({ oracleId: w.oracle_id, cardId: w.card_id ?? null, finish: w.finish ?? null, qty: w.qty }));
    if (section === "deck") return s.deckEntries.get(item ?? "") ?? [];
    return [];
  }

  /** DEMO_LINK is Mara's deck, as a stranger opens it; other demo links read as closed (the dev demo has no server). */
  shared(token: string): SharedLinkData {
    const mara = this.people.get(DEMO_FRIEND)?.decks[0];
    if (token !== DEMO_LINK || !mara) throw new Error("This isn't available");
    return { part: "deck", id: mara.id, name: mara.name, format: mara.format, cards: mara.cards, owner: { display_name: "Mara Quinn" }, mine: false };
  }

  sharedCards(token: string): ProfileCard[] {
    return token === DEMO_LINK ? this.cards(DEMO_FRIEND, "deck", this.people.get(DEMO_FRIEND)?.decks[0]?.id ?? null) : [];
  }

  matches(only: string | null): TradeMatch[] {
    const mine: WantIn[] = liveWants().map((w) => ({ oracle_id: w.oracleId, card_id: w.cardId, finish: w.finish, qty: w.qty, max_usd: w.maxUsd }));
    const b = bindersNow();
    const byItem = new Map<string, Alloc[]>();
    for (const a of b.allocs.values()) {
      if (a.qty > 0 && binderById(a.binderId)?.for_trade) byItem.set(allocItemKey(a), [...(byItem.get(allocItemKey(a)) ?? []), a]);
    }
    const myCopies: CopyIn[] = [];
    for (const allocs of byItem.values()) {
      const a = allocs.reduce((m, x) => (x.qty > m.qty ? x : m));
      const o = cardOracle.get(a.cardId);
      if (!o) continue;
      myCopies.push({ oracle_id: o, card_id: a.cardId, finish: a.finish, condition: a.condition, lang: a.lang, binder_id: a.binderId,
                      qty: allocs.reduce((n, x) => n + x.qty, 0), usd: usdPrice(a.cardId, a.finish, a.condition) });
    }
    const out: TradeMatch[] = [];
    for (const s of this.people.values()) {
      const lv = this.level(s.person.user_id);
      if (lv < 0 || (only && only !== s.person.user_id)) continue;
      const have = sees(lv, s.profile, s.forTrade) ? shownLines(matchLines(mine, s.copies)) : [];
      const want = sees(lv, s.profile, s.wants)
        ? matchLines(s.wanted.map((w) => ({ ...w, max_usd: null })), myCopies).map((l) => ({ ...l, over_max: null })) : [];
      const hc = have.reduce((n, l) => n + l.qty, 0), wc = want.reduce((n, l) => n + l.qty, 0);
      if (!hc && !wc) continue;
      out.push({ ...s.person, friend: lv === 1, they_have: have, they_want: want, have_copies: hc, want_copies: wc,
                 have_usd: linesValue(have, true), want_usd: linesValue(want, false) });
    }
    return out.sort((a, b) => b.have_copies + b.want_copies - (a.have_copies + a.want_copies) || Number(b.friend) - Number(a.friend));
  }
}

/** Printing id → oracle id, for your for-trade copies (filled from the catalog when the demo starts). */
const cardOracle = new Map<string, string>();
let started: Promise<void> | null = null;

export function startFriendsDemo(c: Catalog): Promise<void> {
  started ??= (async () => {
    const d = new Demo();
    for (const a of bindersNow().allocs.values()) {
      const pi = c.printingIndex.get(a.cardId);
      if (pi != null) cardOracle.set(a.cardId, c.oId[c.pOracle[pi]]);
    }
    await d.build(c);
    setFriendsDemo(d);
  })();
  return started;
}
