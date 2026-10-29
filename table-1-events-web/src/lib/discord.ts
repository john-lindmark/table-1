import { supabase } from "./supabaseClient";
import commands from "./discordCommands.json";

/*
 * Table 1 for Discord on the web (contract/discord-2026-10-29.md §4, §7): the /discord page (what the bot does, the
 * install link, your link status) and /discord/link (the page behind the bot's one-time link). The commands and their
 * help lines are a copy of the bot's commands.json (discord.test.ts keeps them identical).
 */

export interface HelpLine {
  command: string;
  text: string;
}

export const DISCORD_HELP: HelpLine[] = commands.help;

/** Send Messages (2048) + Embed Links (16384): all the bot needs. */
export const BOT_PERMISSIONS = 18432;

export function installUrl(clientId: string): string | null {
  if (!/^[0-9]{5,25}$/.test(clientId)) return null;
  const u = new URL("https://discord.com/oauth2/authorize");
  u.searchParams.set("client_id", clientId);
  u.searchParams.set("scope", "bot applications.commands");
  u.searchParams.set("permissions", String(BOT_PERMISSIONS));
  return u.toString();
}

/** The token out of the bot's link: https://table-1.site/discord/link#t=<token>. Null when there isn't one. */
export function linkTokenFromHash(hash: string): string | null {
  const m = /^#?t=([A-Za-z0-9_-]{20,64})$/.exec(hash.trim());
  return m ? m[1] : null;
}

// The token has to survive a sign-in round trip (Apple, Google, Discord or the email link): sessionStorage keeps it in
// this tab only, and it is cleared the moment it's used or found stale.
const PENDING_KEY = "table1.discord.link";
const PENDING_MINUTES = 15;

export function savePendingToken(token: string, now = Date.now()) {
  try {
    sessionStorage.setItem(PENDING_KEY, JSON.stringify({ token, at: now }));
  } catch { /* storage off: the person can run /link again */ }
}

export function loadPendingToken(now = Date.now()): string | null {
  try {
    const raw = sessionStorage.getItem(PENDING_KEY);
    if (!raw) return null;
    const p = JSON.parse(raw) as { token?: string; at?: number };
    if (!p.token || !p.at || now - p.at > PENDING_MINUTES * 60_000) {
      sessionStorage.removeItem(PENDING_KEY);
      return null;
    }
    return linkTokenFromHash(`#t=${p.token}`);
  } catch {
    return null;
  }
}

export function clearPendingToken() {
  try {
    sessionStorage.removeItem(PENDING_KEY);
  } catch { /* nothing to clear */ }
}

export interface DiscordLinkStatus {
  linked: boolean;
  via: "link" | "sign_in" | null;
  linkedAt: string | null;
}

export async function fetchDiscordLinkStatus(): Promise<DiscordLinkStatus> {
  const { data, error } = await supabase.rpc("discord_link_status");
  if (error) throw error;
  const r = data as { linked: boolean; via: "link" | "sign_in" | null; linked_at: string | null };
  return { linked: r.linked, via: r.via, linkedAt: r.linked_at };
}

export async function confirmDiscordLink(token: string): Promise<{ linkedAt: string | null }> {
  const { data, error } = await supabase.rpc("discord_link_confirm", { p_token: token });
  if (error) throw error;
  return { linkedAt: (data as { linked_at: string | null }).linked_at };
}

export async function unlinkDiscord(): Promise<{ unlinked: boolean; via: "link" | "sign_in" | null }> {
  const { data, error } = await supabase.rpc("discord_unlink_me");
  if (error) throw error;
  return data as { unlinked: boolean; via: "link" | "sign_in" | null };
}

// ---------------------------------------------------------------- the Table 1 server (contract §7 "The Table 1 server")

/** The Table 1 server, for "Open" once you're in it. */
export const COMMUNITY_GUILD_ID = "1565392011295465522";

/** The invite from VITE_DISCORD_INVITE_URL, only a discord.gg or discord.com/invite link. Null hides the join row. */
export function inviteUrl(raw: string | undefined): string | null {
  const m = /^https:\/\/(?:discord\.gg|(?:www\.)?discord\.com\/invite)\/([A-Za-z0-9-]{2,32})\/?$/.exec((raw ?? "").trim());
  return m ? `https://discord.gg/${m[1]}` : null;
}

export interface CommunityMembership {
  /** The account has a Discord id (/link or Discord sign-in). */
  linked: boolean;
  /** In the server; null when Discord couldn't say. */
  member: boolean | null;
}

/** Whether the signed-in account is in the Table 1 server (the discord-community edge function asks Discord). */
export async function fetchCommunityMembership(): Promise<CommunityMembership> {
  const { data, error } = await supabase.functions.invoke("discord-community", { body: {} });
  if (error) throw error;
  const r = data as { linked?: boolean; member?: boolean | null };
  return { linked: r.linked === true, member: typeof r.member === "boolean" ? r.member : null };
}

/**
 * What the join row shows. Signed out, or signed in without a linked Discord account, we can't know, so it's the invite.
 * Signed in, nothing until Discord has answered (a member never sees "Join" flash). Known members see "You're in";
 * an unknown answer or a failed call falls back to the invite.
 */
export type CommunityRow = "join" | "member" | "loading" | "hidden";

export function communityRow(invite: string | null, signedIn: boolean,
  membership: CommunityMembership | "loading" | "error" | null): CommunityRow {
  if (signedIn && membership === "loading") return "loading";
  if (signedIn && membership && typeof membership === "object" && membership.member === true) return "member";
  return invite ? "join" : "hidden";
}
