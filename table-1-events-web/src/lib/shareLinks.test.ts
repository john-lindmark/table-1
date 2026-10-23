import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { redactPath, screenName } from "./analytics";
import {
  DEFAULT_SHARING, linkFor, linkUrl, profilePartUrl, shareConfirm, sharedByline, sharedTitle, shareWhat, targetReach, targetTitle,
  type SectionKind, type SharedLinkData, type Sharing,
} from "./friends";

/* Share links (contract/share-links-2026-10-23.md) against testdata/share-links/cases.json, which iOS and Android read too. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/share-links/cases.json", import.meta.url), "utf8"));

describe("share links", () => {
  it("builds the link and profile addresses and the wording", () => {
    expect(linkUrl(cases.link_url.token)).toBe(cases.link_url.url);
    for (const t of cases.targets) {
      const target = { part: t.part as SectionKind, id: t.id, name: t.name };
      expect(targetTitle(target)).toBe(t.title);
      expect(shareWhat(t.part)).toBe(t.what);
      expect(shareConfirm(t.part)).toBe(t.confirm);
      expect(profilePartUrl(cases.me, target)).toBe(t.profile_url);
    }
  });

  it("finds a part's live link in sharing_get", () => {
    const s = cases.sharing_get as Sharing;
    expect(linkFor(s, { part: "deck", id: "D1" })?.token).toBe("Ab3_-x9QzLm2pR7tKw4vYc");
    expect(linkFor(s, { part: "wants", id: null })?.token).toBe("Zz9_-x9QzLm2pR7tKw4vYc");
    expect(linkFor(s, { part: "cube", id: "D1" })).toBeNull();
    expect(linkFor(s, { part: "all_cards", id: null })).toBeNull();
    expect(linkFor({ ...DEFAULT_SHARING }, { part: "wants", id: null })).toBeNull(); // an older server sends no links
  });

  it("names a link's page", () => {
    for (const v of cases.shared_view) {
      expect(sharedTitle(v.json as SharedLinkData)).toBe(v.title);
      expect(sharedByline(v.json as SharedLinkData)).toBe(v.byline);
    }
  });

  it("reads who a part reaches with the profile cap, links aside", () => {
    const s: Sharing = { ...DEFAULT_SHARING, profile: "friends", all_cards: "public", items: [{ kind: "deck", id: "D1", name: "Burn", visibility: null }] };
    expect(targetReach(s, { part: "all_cards", id: null, name: null })).toBe("friends");
    expect(targetReach(s, { part: "wants", id: null, name: null })).toBe("private");
    expect(targetReach({ ...s, decks: "friends" }, { part: "deck", id: "D1", name: "Burn" })).toBe("friends");
    // A deck Sharing hasn't heard of yet starts private.
    expect(targetReach({ ...s, decks: "friends" }, { part: "deck", id: "NEW", name: "Brew" })).toBe("private");
  });

  it("keeps tokens out of analytics", () => {
    expect(redactPath("/l/Ab3_-x9QzLm2pR7tKw4vYc")).toBe("/l/:id");
    expect(screenName("/l/Ab3_-x9QzLm2pR7tKw4vYc", () => undefined)).toBe("shared_link");
  });
});
