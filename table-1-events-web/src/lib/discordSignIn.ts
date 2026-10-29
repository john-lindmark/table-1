/**
 * Sign in with Discord (contract/discord-sign-in-2026-10-29.md). Discord brings a username, not a real name, so an
 * account made only from email or Discord takes the name step until it has a first name.
 */
export function needsNameFor(providers: string[], firstName: unknown): boolean {
  if (providers.length === 0 || !providers.every((p) => p === "email" || p === "discord")) return false;
  return !String(firstName ?? "").trim();
}
