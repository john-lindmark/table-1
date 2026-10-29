import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { needsNameFor } from "./discordSignIn";

/* Discord accounts take the name step like email (contract/discord-sign-in-2026-10-29.md) against
   testdata/discord-sign-in/cases.json (also iOS DiscordSignInTests and Android DiscordSignInTest). */

interface Cases {
  needsName: { name: string; providers: string[]; first_name: string | null; needs: boolean }[];
}

const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/discord-sign-in/cases.json", import.meta.url), "utf8"));

describe("discord sign-in", () => {
  it.each(cases.needsName)("needs a name: $name", (c) => {
    expect(needsNameFor(c.providers, c.first_name)).toBe(c.needs);
  });
});
