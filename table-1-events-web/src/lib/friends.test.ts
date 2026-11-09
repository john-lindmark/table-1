import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_SHARING, capped, copyNote, effective, sharedCardCount, sharedEntries, sharedListKind, effectiveItem, linesValue, matchLines, matchShort, parseCardRow, parseFriendsList, profileValue,
  friendRowDetail, friendsDetail, friendsOwnDetail, type Person,
  reach, sees, seesLine, sentLabel, sharedCount, sharingSummary, viewAs, VIS_LABEL, widening, wideningMessage, type ProfileData, shownLines, wantTier, type CopyIn, type MatchLine, type Sharing, type TradeMatch, type WantIn,
} from "./friends";
import { redactPath, screenName } from "./analytics";

/* Friends, sharing and trade matches (contract/friends-sharing-2026-10-18.md). The matcher runs the shared cases in
   testdata/trade-matches/cases.json (the same as the server's 80_friends_sharing_test.sql); apps/ios FriendsTests and
   Android FriendsTest read the same file. */

interface Case {
  name: string;
  wants: WantIn[];
  copies: CopyIn[];
  lines: { card_id: string; finish: string; condition: string; lang: string; qty: number; want: string; over_max: boolean }[];
}
const cases: Case[] = JSON.parse(readFileSync(new URL("../../../testdata/trade-matches/cases.json", import.meta.url), "utf8")).cases;

describe("matchLines", () => {
  it("has the shared cases", () => expect(cases.length).toBeGreaterThanOrEqual(5));
  for (const c of cases) {
    it(c.name, () => {
      const got = matchLines(c.wants, c.copies).map((l) => ({
        card_id: l.card_id, finish: l.finish, condition: l.condition, lang: l.lang, qty: l.qty, want: wantTier(l.want), over_max: !!l.over_max,
      }));
      expect(got).toEqual(c.lines);
    });
  }

  it("shows under-max lines first, dearest first; value skips over-max", () => {
    const w = { oracle_id: "o" };
    const l = (card_id: string, qty: number, usd: number, over: boolean): MatchLine =>
      ({ card_id, finish: "nonfoil", condition: "NM", lang: "en", qty, want: w, usd, over_max: over });
    const lines = [l("a", 1, 50, true), l("b", 1, 1, false), l("c", 2, 3, false)];
    expect(shownLines(lines).map((x) => x.card_id)).toEqual(["c", "b", "a"]);
    expect(linesValue(lines, true)).toBe(7);
    expect(linesValue(lines, false)).toBe(57);
  });

  it("summarises a match", () => {
    const m = { have_copies: 3, want_copies: 2 } as TradeMatch;
    expect(matchShort(m)).toBe("Has 3 · wants 2");
    expect(matchShort({ ...m, have_copies: 0 })).toBe("Wants 2");
  });
});

describe("sharing rules", () => {
  it("starts private", () => {
    for (const p of ["all_cards", "for_trade", "wants", "binders", "decks", "cubes", "record"] as const) {
      expect(effective(DEFAULT_SHARING, p)).toBe("private");
    }
    expect(sharedCount(DEFAULT_SHARING)).toBe(0);
    expect(sharingSummary(DEFAULT_SHARING)).toBe("Profile friends · nothing shared");
  });

  it("follows Same as … up the tree; an item's own setting wins", () => {
    const s: Sharing = { ...DEFAULT_SHARING, library: "friends", decks: "private" };
    expect(effective(s, "wants")).toBe("friends");
    const deck = { kind: "deck" as const, id: "d", name: "Burn", visibility: null };
    expect(effectiveItem(s, deck)).toBe("private");
    const own = { ...deck, visibility: "public" as const };
    expect(effectiveItem(s, own)).toBe("public");
    expect(sharedCount({ ...s, items: [own] })).toBe(6);
  });

  it("lets the profile cap every part", () => {
    const s: Sharing = { ...DEFAULT_SHARING, for_trade: "public" };
    expect(capped(s, "public")).toBe(true);
    expect(reach(s, "public")).toBe("friends");
    expect(reach({ ...s, profile: "public" }, "public")).toBe("public");
    expect(reach({ ...s, profile: "private" }, "public")).toBe("private");
  });

  it("matches the server's vis_ok", () => {
    const rows: [number, Sharing["profile"], Sharing["profile"], boolean][] = [
      [3, "private", "private", true], [1, "friends", "friends", true], [1, "friends", "private", false], [1, "private", "public", false],
      [0, "public", "public", true], [0, "friends", "public", false], [0, "public", "friends", false], [-1, "public", "public", false],
    ];
    for (const [level, profile, part, want] of rows) expect(sees(level, profile, part)).toBe(want);
  });
});

describe("profile_cards rows", () => {
  it("parses each section's shape", () => {
    expect(parseCardRow("all_cards", ["c", "foil", 3])).toEqual({ cardId: "c", finish: "foil", qty: 3 });
    expect(parseCardRow("binder", ["c", "nonfoil", "LP", "ja", 2])).toEqual({ cardId: "c", finish: "nonfoil", condition: "LP", lang: "ja", qty: 2 });
    expect(parseCardRow("deck", ["c", "side", 4])).toEqual({ cardId: "c", board: "side", qty: 4 });
    expect(parseCardRow("wants", ["o", null, null, 1])).toEqual({ oracleId: "o", cardId: null, finish: null, qty: 1 });
    expect(parseCardRow("wants", ["o"])).toBeNull();
  });
});

describe("profile and match addresses", () => {
  const U = "8f3c1e2a-0000-4000-8000-000000000001", D = "2b1d0000-0000-4000-8000-000000000002";
  it("never sends account, binder or list ids", () => {
    expect(redactPath(`/u/${U}`)).toBe("/u/:id");
    expect(redactPath(`/u/${U}/deck/${D}`)).toBe("/u/:id/deck/:id");
    expect(redactPath(`/u/${U}/for_trade`)).toBe("/u/:id/for_trade");
    expect(redactPath(`/library/match/${U}`)).toBe("/library/match/:id");
  });
  it("names the screens", () => {
    expect(screenName("/friends")).toBe("friends");
    expect(screenName("/friends/add")).toBe("friend_add");
    expect(screenName("/sharing")).toBe("sharing");
    expect(screenName(`/u/${U}`)).toBe("profile");
    expect(screenName(`/u/${U}/binder/${D}`)).toBe("profile_cards");
    expect(screenName("/library/matches")).toBe("trade_matches");
    expect(screenName(`/library/match/${U}`)).toBe("trade_match");
  });
});

describe("privacy fixes (contract § Privacy fixes)", () => {
  it("decodes Sent rows asked by id and by email", () => {
    const l = parseFriendsList({
      friends: [], incoming: [], blocked: [],
      outgoing: [
        { email: "jo@example.com", at: "2026-10-18T10:00:00Z" },
        { user_id: "u1", display_name: "Lee Park", handle: null, avatar_url: null, at: "2026-10-17T10:00:00Z" },
      ],
    });
    expect(l.outgoing.map((r) => [r.person?.user_id ?? null, r.email, r.at, sentLabel(r)])).toEqual([
      [null, "jo@example.com", "2026-10-18T10:00:00Z", "jo@example.com"],
      ["u1", null, "2026-10-17T10:00:00Z", "Lee Park"],
    ]);
    expect(new Set(l.outgoing.map((r) => r.key)).size).toBe(2);
  });

  it("reads older servers' Person-only Sent rows, and a null user_id as an address", () => {
    const l = parseFriendsList({
      friends: [], incoming: [], blocked: [],
      outgoing: [{ user_id: "u2", display_name: "Kai", handle: null, avatar_url: null },
                 { user_id: null, email: "x@example.com", at: "2026-10-15T10:00:00Z" } as never],
    });
    expect(l.outgoing.map((r) => r.person?.user_id ?? r.email)).toEqual(["u2", "x@example.com"]);
    expect(l.outgoing[0].at).toBeNull();
  });

  it("shows the collection value on your own profile only", () => {
    const profile = (relation: ProfileData["relation"], value_usd?: number): ProfileData => ({
      user_id: "u", display_name: "A", handle: null, avatar_url: null, relation, friends_since: null, visible: true,
      sections: { all_cards: { cards: 10, printings: 8, ...(value_usd == null ? {} : { value_usd }) } },
    });
    expect(profileValue(profile("self", 42.5))).toBe(42.5);
    expect(profileValue(profile("friend"))).toBeNull();
    // An older server still sends it to others: not shown.
    expect(profileValue(profile("friend", 42.5))).toBeNull();
    expect(profileValue({ ...profile("self"), sections: {} })).toBeNull();
  });
});

describe("shared decks and cubes", () => {
  const rows = [
    { cardId: "a", board: "main", qty: 2 }, { cardId: "b", board: "side", qty: 1 }, { cardId: "a", board: "main", qty: 1 },
    { cardId: "a", board: "side", qty: 1 }, { cardId: "c", board: "maybe", qty: 3 }, { cardId: null, board: "main", qty: 1 },
  ];
  it("merges per card and board, non-foil", () => {
    expect(sharedEntries(rows)).toEqual([
      { cardId: "a", board: "main", qty: 3 }, { cardId: "b", board: "side", qty: 1 }, { cardId: "a", board: "side", qty: 1 },
      { cardId: "c", board: "maybe", qty: 3 },
    ]);
  });
  it("counts a deck without Considering", () => {
    expect(sharedCardCount(rows, "deck")).toBe(6);
    expect(sharedCardCount(rows, "cube")).toBe(9);
  });
  it("names where a copy came from", () => {
    expect(copyNote("Sam", "Mono Red")).toBe("Copied from Sam's Mono Red");
    expect(copyNote(null, "Mono Red")).toBe("Copied from Mono Red");
  });
  it("knows which sections are lists", () => {
    expect(sharedListKind("deck")).toBe("deck");
    expect(sharedListKind("cube")).toBe("cube");
    expect(sharedListKind("binder")).toBeNull();
  });
});

/* Sharing UX rules (contract § UX rules 4-5), on testdata/sharing/cases.json: the same file iOS FriendsTests and
   Android SharingRulesTest read. */
describe("sharing UX rules (shared cases)", () => {
  const sc = JSON.parse(readFileSync(new URL("../../../testdata/sharing/cases.json", import.meta.url), "utf8"));
  const settings = (x: Partial<Sharing>): Sharing => ({ ...DEFAULT_SHARING, ...x, items: x.items ?? [] });
  for (const c of sc.widening) {
    it(`widening: ${c.name}`, () => {
      const w = widening(settings(c.before), settings(c.after));
      expect(w).toEqual({ friends: c.friends, anyone: c.anyone, all_cards_to_anyone: c.all_cards_to_anyone, profile_to_anyone: c.profile_to_anyone });
    });
  }
  for (const c of sc.sees) {
    it(`sees: ${c.name}`, () => {
      expect(seesLine(settings(c.settings), 1)).toBe(c.friends);
      expect(seesLine(settings(c.settings), 0)).toBe(c.anyone);
    });
  }
  for (const c of sc.view_as) {
    it(`view as: ${c.name}`, () => {
      const v = viewAs(sc.view_as_profile as ProfileData, settings(c.settings), c.level);
      const s = v.sections;
      expect({
        visible: v.visible, all_cards: s.all_cards?.cards ?? null, value: s.all_cards?.value_usd ?? null, for_trade: s.for_trade?.cards ?? null,
        wants: s.wants?.cards ?? null, binders: (s.binders ?? []).map((b) => b.name), decks: (s.decks ?? []).map((b) => b.name),
        cubes: (s.cubes ?? []).map((b) => b.name), record: !!s.record, friends: !!s.friends,
      }).toEqual(c.want);
    });
  }
  /* Friends on profiles (contract § Friends on profiles). */
  it("friends words", () => {
    for (const d of sc.profile_friends.detail) expect(friendsDetail(d.mutual)).toBe(d.want);
    for (const [v, want] of Object.entries(sc.profile_friends.own)) expect(friendsOwnDetail(v as Sharing["profile"])).toBe(want);
    for (const r of sc.profile_friends.rows) {
      const p: Person = { user_id: "u", display_name: "N", handle: r.handle, avatar_url: null, relation: r.relation, mutual: r.mutual };
      expect(friendRowDetail(p)).toBe(r.want);
    }
  });
  it("reads a server without the friends settings as their defaults", () => {
    const old = { profile: "public", library: "private", all_cards: null, for_trade: null, wants: null, binders: null, decks: null, cubes: null,
                  record: "private", items: [] } as Sharing;
    expect(effective(old, "friends")).toBe("private");
    expect(effective(old, "listed")).toBe("friends");
    expect(widening(old, { ...old, friends: "friends" }).friends).toEqual(["your friends"]);
    expect(widening(old, { ...old, listed: "public" }).anyone).toEqual(["you in your friends' lists"]);
    expect(sharedCount({ ...old, friends: "public" })).toBe(1);
  });
  it("never says Public", () => {
    expect(VIS_LABEL.public).toBe("Anyone");
    expect(wideningMessage(widening(settings({}), settings({ profile: "public", library: "public" }))))
      .toBe("Anyone on Table 1 will see: your profile, All cards, For trade, Wants.\n\nEvery card you own. Your total value is never shown.\n\nYour profile shows up when people search your name.");
  });
});
