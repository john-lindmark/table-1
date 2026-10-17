/**
 * Avatars (contract/avatars-2026-10-16.md): initials on a muted tile picked from the account id, or the
 * player's photo from the public `avatars` bucket. Same rules on every platform; no Supabase import here so
 * the rules test without env.
 */

/** Muted tints near the surface's lightness: a quiet tile, never mistaken for the teal accent. */
export const AVATAR_PALETTE = [
  "#4A3F6B",
  "#5B3E5A",
  "#63414A",
  "#5E4A38",
  "#4D5236",
  "#36524A",
  "#3A4C66",
  "#4B4B5E",
] as const;

const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;

/** First letter or digit of the first and last word; one word gives one letter; nothing gives "?". */
export function avatarInitials(name: string): string {
  const firsts = name
    .split(/\s+/)
    .map((w) => [...w].find((c) => LETTER_OR_DIGIT.test(c)))
    .filter((c): c is string => c != null);
  if (firsts.length === 0) return "?";
  return (firsts.length > 1 ? firsts[0] + firsts[firsts.length - 1] : firsts[0]).toUpperCase();
}

/** The account id when there is one, so a player looks the same everywhere; a guest's name otherwise. */
export function avatarSeed(userId: string | null | undefined, name: string): string {
  return userId ? userId.toLowerCase() : name.trim().toLowerCase();
}

/** FNV-1a 32-bit over the seed's UTF-8 bytes, mod the palette. */
export function avatarColorIndex(seed: string): number {
  let h = 2166136261;
  for (const b of new TextEncoder().encode(seed)) h = Math.imul(h ^ b, 16777619) >>> 0;
  return h % AVATAR_PALETTE.length;
}

export function avatarColor(userId: string | null | undefined, name: string): string {
  return AVATAR_PALETTE[avatarColorIndex(avatarSeed(userId, name))];
}
