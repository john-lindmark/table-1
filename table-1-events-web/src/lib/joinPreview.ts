/** The event behind a scanned join QR, shown over sign-in (contract/qr-sign-up-2026-10-23.md). */
export interface JoinHeader {
  title: string;
  facts: string;
}

/** event_preview's JSON → the header's name and facts line; null when there's nothing to show (the page shows the code). */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function joinHeader(w: any): JoinHeader | null {
  const text = (s: unknown) => (typeof s === "string" && s.trim() ? s.trim() : null);
  const name = text(w?.name);
  if (!w?.event_id || w.access === "none" || !name) return null;
  const players: number = w.players ?? 0;
  const count = w.capacity > 0 ? `${players}/${w.capacity} players` : players === 1 ? "1 player" : `${players} players`;
  const organizer = text(w.organizer_name);
  const facts = [text(w.format_label), text(w.venue_name), organizer && `Run by ${organizer}`, count]
    .filter(Boolean)
    .join(" · ");
  return { title: name, facts };
}

/** Tell players before they join (contract/friends-sharing-2026-10-18.md § UX rules 9): Nearby, invitations and joins
 *  by code. Same words as iOS / Android `JoinNotice`. */
export const JOIN_NOTICE = "Your name shows in this event's pairings and standings, to its players and anyone with its standings link.";
