// What Discord's Get Guild Member answer means for the join row (contract/discord-2026-10-29.md §7).
//   200                          in the server
//   404 Unknown Member / User    not in it (or no such Discord account any more)
//   anything else                don't know (bot not in the server, rate limited, Discord down): the web shows the invite

export interface Membership {
  /** The account has a Discord id (/link or Discord sign-in). Without one there's nothing to ask Discord. */
  linked: boolean;
  /** In the Table 1 server; null when Discord couldn't say. */
  member: boolean | null;
}

const UNKNOWN_MEMBER = 10007;
const UNKNOWN_USER = 10013;

export function memberFrom(status: number, body: { code?: number } | null): boolean | null {
  if (status === 200) return true;
  if (status === 404 && (body?.code === UNKNOWN_MEMBER || body?.code === UNKNOWN_USER)) return false;
  return null;
}

export const isSnowflake = (s: unknown): s is string => typeof s === "string" && /^[0-9]{5,25}$/.test(s);
