import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it } from "vitest";
import {
  clearPendingToken, communityRow, DISCORD_HELP, installUrl, inviteUrl, linkTokenFromHash, loadPendingToken, savePendingToken,
} from "./discord";

/* Table 1 for Discord (contract/discord-2026-10-29.md). */

const read = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

describe("discord", () => {
  it("the web's copy of the bot's commands is the bot's", () => {
    expect(JSON.parse(read("./discordCommands.json"))).toEqual(JSON.parse(read("../../../supabase/functions/discord-bot/commands.json")));
  });

  it("every command has a help line and the page shows them all", () => {
    const commands = JSON.parse(read("./discordCommands.json")).commands as { name: string; options?: { type: number; name: string }[] }[];
    const registered: string[] = [];
    for (const c of commands) {
      const subs = (c.options ?? []).filter((o) => o.type === 1);
      if (subs.length) subs.forEach((s) => registered.push(`/${c.name} ${s.name}`));
      else registered.push(`/${c.name}`);
    }
    expect(DISCORD_HELP.map((h) => h.command).sort()).toEqual(registered.sort());
    for (const h of DISCORD_HELP) expect(h.text.length).toBeGreaterThan(10);
  });

  it("the install link asks for the bot with Send Messages and Embed Links only", () => {
    const u = new URL(installUrl("1565382252706140300")!);
    expect(u.origin + u.pathname).toBe("https://discord.com/oauth2/authorize");
    expect(Object.fromEntries(u.searchParams)).toEqual({
      client_id: "1565382252706140300", scope: "bot applications.commands", permissions: "18432",
    });
    expect(installUrl("")).toBeNull();
    expect(installUrl("not an id")).toBeNull();
  });

  it("reads the token out of the bot's link and nothing else", () => {
    expect(linkTokenFromHash("#t=abcDEFghiJKL012345_-xyzABCDEF12")).toBe("abcDEFghiJKL012345_-xyzABCDEF12");
    expect(linkTokenFromHash("t=abcDEFghiJKL012345_-xyzABCDEF12")).toBe("abcDEFghiJKL012345_-xyzABCDEF12");
    expect(linkTokenFromHash("")).toBeNull();
    expect(linkTokenFromHash("#t=short")).toBeNull();
    expect(linkTokenFromHash("#t=abc$DEFghiJKL012345_-xyzABCDEF12")).toBeNull();
    expect(linkTokenFromHash("#access_token=x&refresh_token=y")).toBeNull();
  });

  describe("the token survives a sign-in round trip, for a quarter of an hour", () => {
    beforeEach(() => clearPendingToken());
    it("round-trips", () => {
      savePendingToken("abcDEFghiJKL012345_-xyzABCDEF12", 1000);
      expect(loadPendingToken(1000 + 14 * 60_000)).toBe("abcDEFghiJKL012345_-xyzABCDEF12");
    });
    it("goes stale", () => {
      savePendingToken("abcDEFghiJKL012345_-xyzABCDEF12", 1000);
      expect(loadPendingToken(1000 + 16 * 60_000)).toBeNull();
      expect(loadPendingToken(1000)).toBeNull();
    });
    it("is cleared", () => {
      savePendingToken("abcDEFghiJKL012345_-xyzABCDEF12");
      clearPendingToken();
      expect(loadPendingToken()).toBeNull();
    });
  });

  describe("the Table 1 server", () => {
    it("takes only a discord.gg or discord.com/invite link", () => {
      expect(inviteUrl("https://discord.gg/Ab3-x9")).toBe("https://discord.gg/Ab3-x9");
      expect(inviteUrl(" https://discord.com/invite/Ab3x9/ ")).toBe("https://discord.gg/Ab3x9");
      expect(inviteUrl("https://www.discord.com/invite/Ab3x9")).toBe("https://discord.gg/Ab3x9");
      expect(inviteUrl("")).toBeNull();
      expect(inviteUrl(undefined)).toBeNull();
      expect(inviteUrl("http://discord.gg/Ab3x9")).toBeNull();
      expect(inviteUrl("https://discord.gg.evil.example/Ab3x9")).toBeNull();
      expect(inviteUrl("https://discord.gg/Ab3x9?x=1")).toBeNull();
    });

    const invite = "https://discord.gg/Ab3x9";
    it("offers the invite when it can't know", () => {
      expect(communityRow(invite, false, null)).toBe("join");
      expect(communityRow(invite, true, { linked: false, member: null })).toBe("join");
      expect(communityRow(invite, true, { linked: true, member: null })).toBe("join");
      expect(communityRow(invite, true, "error")).toBe("join");
    });
    it("never offers it to a member, not even while asking", () => {
      expect(communityRow(invite, true, "loading")).toBe("loading");
      expect(communityRow(invite, true, { linked: true, member: true })).toBe("member");
      expect(communityRow(null, true, { linked: true, member: true })).toBe("member");
    });
    it("offers it to a linked account that isn't in", () => {
      expect(communityRow(invite, true, { linked: true, member: false })).toBe("join");
    });
    it("hides without an invite", () => {
      expect(communityRow(null, false, null)).toBe("hidden");
      expect(communityRow(null, true, { linked: true, member: false })).toBe("hidden");
    });
  });
});
