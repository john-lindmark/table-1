import { describe, expect, it } from "vitest";
import { NAV_GROUPS, PEEK_W, isTypingTarget, navKeyFor, peekPosition, sidebarOn } from "./desktop";

const ID = "8f3c1d2e-0000-4000-8000-000000000000";

describe("navKeyFor", () => {
  it("marks every sidebar item on its own screen", () => {
    for (const g of NAV_GROUPS) for (const it of g.items) expect(navKeyFor(it.to)).toBe(it.key);
  });

  it("keeps Events marked inside an event, as organizer or player", () => {
    expect(navKeyFor(`/e/${ID}`)).toBe("events");
    expect(navKeyFor(`/e/${ID}/add`)).toBe("events");
    expect(navKeyFor(`/p/${ID}`)).toBe("events");
    expect(navKeyFor("/join/ABCD")).toBe("events");
  });

  it("keeps the parent marked on pushed Library screens", () => {
    expect(navKeyFor(`/library/card/${ID}`)).toBe("cards");
    expect(navKeyFor(`/library/binder/${ID}`)).toBe("binders");
    expect(navKeyFor(`/library/trade/${ID}`)).toBe("trades");
    expect(navKeyFor("/library/trade/new")).toBe("trades");
    expect(navKeyFor(`/library/match/${ID}`)).toBe("matches");
    expect(navKeyFor("/library/find")).toBe("decks");
    expect(navKeyFor("/library/import/deck")).toBe("decks");
    expect(navKeyFor("/library/import/cube")).toBe("cubes");
    expect(navKeyFor(`/library/ranking/${ID}/screen/F`)).toBe("rankings");
    expect(navKeyFor(`/library/list/${ID}/rankings`)).toBe("rankings");
  });

  it("puts a list under Decks or Cubes by its kind, Decks when unknown", () => {
    const cube = () => "cube" as const;
    expect(navKeyFor(`/library/list/${ID}`, cube)).toBe("cubes");
    expect(navKeyFor(`/library/list/${ID}/stats/pack`, cube)).toBe("cubes");
    expect(navKeyFor(`/library/list/${ID}`, () => "deck")).toBe("decks");
    expect(navKeyFor(`/library/list/${ID}`)).toBe("decks");
  });

  it("puts profiles and friend screens under Friends", () => {
    expect(navKeyFor(`/u/${ID}`)).toBe("friends");
    expect(navKeyFor(`/u/${ID}/deck/${ID}`)).toBe("friends");
    expect(navKeyFor("/friends/add")).toBe("friends");
  });

  it("ignores a trailing slash and marks nothing on pages outside the app", () => {
    expect(navKeyFor("/library/cards/")).toBe("cards");
    expect(navKeyFor("/privacy")).toBeNull();
  });
});

describe("sidebarOn", () => {
  it("shows on app screens", () => {
    for (const p of ["/", `/e/${ID}`, `/p/${ID}`, "/library", `/library/list/${ID}`, "/me", "/friends", `/u/${ID}`]) {
      expect(sidebarOn(p)).toBe(true);
    }
  });

  it("stays off full-screen and public pages", () => {
    for (const p of ["/life", `/life/${ID}`, "/sign-in", "/terms", "/privacy", "/delete-account", "/auth/confirm", `/s/${ID}`, "/dev/events"]) {
      expect(sidebarOn(p)).toBe(false);
    }
  });
});

describe("peekPosition", () => {
  const H = Math.round(PEEK_W * (680 / 488));

  it("sits right of the pointer, centered on it", () => {
    expect(peekPosition(400, 450, 1440, 900)).toEqual({ left: 424, top: 450 - H / 2 });
  });

  it("flips left of the pointer near the right edge", () => {
    expect(peekPosition(1300, 450, 1440, 900).left).toBe(1300 - 24 - PEEK_W);
  });

  it("stays inside the window top and bottom", () => {
    expect(peekPosition(400, 10, 1440, 900).top).toBe(8);
    expect(peekPosition(400, 890, 1440, 900).top).toBe(900 - H - 8);
  });
});

describe("isTypingTarget", () => {
  const el = (tagName: string, extra: Record<string, unknown> = {}) => ({ tagName, ...extra }) as unknown as Element;

  it("lets / through to text fields", () => {
    expect(isTypingTarget(el("INPUT", { type: "text" }))).toBe(true);
    expect(isTypingTarget(el("INPUT", { type: "search" }))).toBe(true);
    expect(isTypingTarget(el("TEXTAREA"))).toBe(true);
    expect(isTypingTarget(el("DIV", { isContentEditable: true }))).toBe(true);
  });

  it("takes / for search from buttons, switches and the page", () => {
    expect(isTypingTarget(el("INPUT", { type: "checkbox" }))).toBe(false);
    expect(isTypingTarget(el("BUTTON"))).toBe(false);
    expect(isTypingTarget(null)).toBe(false);
  });
});
