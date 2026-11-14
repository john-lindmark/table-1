// Alert text for `deck.read` (contract/deck-photo-lists-2026-11-13.md § The push): the decklist read from a player's
// deck photo is ready, once per photo. Queued by deck_photo_read_finish; the app opens the photo's decklist.
export function deckReadCopy(d: Record<string, unknown>): { title: string; body: string } {
  const name = typeof d.event_name === "string" && d.event_name.trim() ? d.event_name.trim() : "";
  const cards = Math.max(0, Math.round(Number(d.cards) || 0));
  const check = Math.max(0, Math.round(Number(d.check) || 0));
  const from = name ? ` from ${name}` : "";
  const count = `${cards} ${cards === 1 ? "card" : "cards"}`;
  const body = check
    ? `${count} read from your deck photo${from}, ${check} to check. Tap to correct it and add it to your decks.`
    : `${count} read from your deck photo${from}. Tap to check it and add it to your decks.`;
  return { title: "Your decklist is ready", body };
}
