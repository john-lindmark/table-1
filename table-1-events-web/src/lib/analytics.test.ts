import { describe, expect, it } from "vitest";
import { redactPath, redactSearch, redactUrl, screenName, scrubProperties, stripQuery } from "./analytics";

const ORIGIN = "https://table-1.site";
const UUID = "8f3c1d2e-0000-4000-8000-000000000000";

describe("redactPath", () => {
  it("strips the join code so it never reaches analytics", () => {
    expect(redactPath("/join/ABCD")).toBe("/join/:id");
  });

  it("strips event ids from every event-scoped route", () => {
    expect(redactPath(`/e/${UUID}`)).toBe("/e/:id");
    expect(redactPath(`/e/${UUID}/add`)).toBe("/e/:id/add");
    expect(redactPath(`/p/${UUID}`)).toBe("/p/:id");
    expect(redactPath(`/s/${UUID}`)).toBe("/s/:id");
  });

  it("strips match, card, list and trade ids", () => {
    expect(redactPath(`/life/${UUID}`)).toBe("/life/:id");
    expect(redactPath(`/library/card/${UUID}`)).toBe("/library/card/:id");
    expect(redactPath(`/library/list/${UUID}`)).toBe("/library/list/:id");
    expect(redactPath(`/library/list/${UUID}/v/3`)).toBe("/library/list/:id/v/3");
    expect(redactPath(`/library/trade/${UUID}`)).toBe("/library/trade/:id");
  });

  it("keeps the words that aren't ids", () => {
    expect(redactPath("/library/trade/new")).toBe("/library/trade/new");
    expect(redactPath("/library/import/cube")).toBe("/library/import/cube");
    expect(redactPath("/life")).toBe("/life");
  });

  it("leaves paths without an identifier alone", () => {
    expect(redactPath("/")).toBe("/");
    expect(redactPath("/join")).toBe("/join");
    expect(redactPath("/library/cards")).toBe("/library/cards");
  });

  it("does not redact a path that merely starts with the same letters", () => {
    expect(redactPath("/events/list")).toBe("/events/list");
    expect(redactPath("/lifetime/x")).toBe("/lifetime/x");
  });
});

describe("QR join links", () => {
  it("redacts the code in /j/ paths", () => {
    expect(redactPath("/j/ABCD")).toBe("/j/:id");
  });
  it("drops the QR secret and OAuth return values from the query", () => {
    expect(redactSearch("?s=abc123")).toBe("");
    expect(redactSearch("?code=xyz&utm_source=flyer")).toBe("?utm_source=flyer");
    expect(redactSearch("")).toBe("");
  });
});

describe("redactUrl", () => {
  it("redacts path and query on this site and drops the hash", () => {
    expect(redactUrl(`${ORIGIN}/j/ABCD?s=secret&utm_source=flyer#access_token=t`, ORIGIN)).toBe(
      `${ORIGIN}/j/:id?utm_source=flyer`,
    );
  });
  it("keeps only the origin of other sites", () => {
    expect(redactUrl("https://accounts.google.com/o/oauth2/auth?client_id=x", ORIGIN)).toBe("https://accounts.google.com");
  });
  it("returns nothing for what isn't a URL", () => {
    expect(redactUrl("http://[bad", ORIGIN)).toBe("");
  });
});

describe("stripQuery", () => {
  it("removes PostgREST filters and fragments", () => {
    expect(stripQuery(`https://x.supabase.co/rest/v1/participants?id=eq.${UUID}`)).toBe(
      "https://x.supabase.co/rest/v1/participants",
    );
    expect(stripQuery("/e/x#y")).toBe("/e/x");
    expect(stripQuery("/library")).toBe("/library");
  });
});

describe("scrubProperties", () => {
  it("redacts every URL and path PostHog adds on its own", () => {
    const props: Record<string, unknown> = {
      $current_url: `${ORIGIN}/join/ABCD`,
      $pathname: `/e/${UUID}`,
      $referrer: `${ORIGIN}/j/ABCD?s=secret`,
      $initial_current_url: `${ORIGIN}/library/trade/${UUID}`,
      $initial_referrer: "$direct",
      $session_entry_url: `${ORIGIN}/p/${UUID}?code=oauth`,
      $initial_person_info: { u: `${ORIGIN}/life/${UUID}`, r: "https://t.co/abc" },
      format: "draft",
      games: 3,
    };
    scrubProperties(props, ORIGIN);
    expect(props).toEqual({
      $current_url: `${ORIGIN}/join/:id`,
      $pathname: "/e/:id",
      $referrer: `${ORIGIN}/j/:id`,
      $initial_current_url: `${ORIGIN}/library/trade/:id`,
      $initial_referrer: "$direct",
      $session_entry_url: `${ORIGIN}/p/:id`,
      $initial_person_info: { u: `${ORIGIN}/life/:id`, r: "https://t.co" },
      format: "draft",
      games: 3,
    });
  });
  it("leaves no join code, secret or id anywhere in the output", () => {
    const props = scrubProperties({ $current_url: `${ORIGIN}/j/ZXCV?s=topsecret`, $pathname: "/j/ZXCV" }, ORIGIN);
    expect(JSON.stringify(props)).not.toMatch(/ZXCV|topsecret/);
  });
});

describe("screenName", () => {
  it("names routes with the contract's screen names", () => {
    expect(screenName("/")).toBe("events_home");
    expect(screenName("/me")).toBe("account");
    expect(screenName(`/e/${UUID}`)).toBe("event");
    expect(screenName(`/p/${UUID}`)).toBe("event");
    expect(screenName("/j/ABCD")).toBe("event");
    expect(screenName(`/e/${UUID}/add`)).toBe("add_players");
    expect(screenName("/life")).toBe("life_tracker");
    expect(screenName("/library/rankings")).toBe("rankings");
    expect(screenName(`/library/list/${UUID}/rankings`)).toBe("rankings");
    expect(screenName(`/library/ranking/${UUID}`)).toBe("ranking");
    expect(screenName(`/library/ranking/${UUID}/screen/W`)).toBe("ranking_screen");
    expect(screenName(`/library/ranking/${UUID}/card/${UUID}/F`)).toBe("ranking_card");
    expect(screenName(`/library/ranking/${UUID}/compare/${UUID}/F`)).toBe("ranking_compare");
    expect(screenName(`/library/ranking/${UUID}/pack`)).toBe("ranking_pack");
    expect(screenName(`/library/ranking/${UUID}/changes`)).toBe("ranking_changes");
    expect(screenName(`/life/${UUID}`)).toBe("life_tracker");
    expect(screenName("/library")).toBe("library_home");
    expect(screenName("/library/cards")).toBe("all_cards");
    expect(screenName("/library/add")).toBe("add_cards");
    expect(screenName(`/library/card/${UUID}`)).toBe("card_detail");
    expect(screenName("/library/decks")).toBe("decks");
    expect(screenName("/library/cubes")).toBe("cubes");
    expect(screenName("/library/find")).toBe("deck_finder");
    expect(screenName("/library/import/deck")).toBe("list_import");
    expect(screenName("/library/import")).toBe("collection_import");
    expect(screenName("/library/trades")).toBe("trades");
    expect(screenName("/library/trade/new")).toBe("trade");
    expect(screenName(`/library/list/${UUID}/add`)).toBe("list_add");
    expect(screenName(`/library/list/${UUID}/printing`)).toBe("list_printing");
    expect(screenName(`/library/list/${UUID}/versions`)).toBe("list_versions");
    expect(screenName(`/library/list/${UUID}/v/2`)).toBe("list_versions");
    expect(screenName(`/library/list/${UUID}/stats/hand`)).toBe("sample_hand");
    expect(screenName(`/library/list/${UUID}/stats/odds`)).toBe("draw_odds");
    expect(screenName(`/library/list/${UUID}/stats/pack`)).toBe("sample_pack");
  });
  it("names a list by its kind once it's known", () => {
    expect(screenName(`/library/list/${UUID}`, () => "cube")).toBe("cube");
    expect(screenName(`/library/list/${UUID}`, () => "deck")).toBe("deck");
    expect(screenName(`/library/list/${UUID}`)).toBeUndefined();
    expect(screenName(`/library/list/${UUID}/stats`, () => "deck")).toBe("deck_stats");
    expect(screenName(`/library/list/${UUID}/stats`, () => "cube")).toBe("cube_stats");
  });
  it("leaves unknown routes unnamed", () => {
    expect(screenName("/dev/events")).toBeUndefined();
  });
});
