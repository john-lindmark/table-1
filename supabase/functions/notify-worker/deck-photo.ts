// Alert text for `event.deck_photo` (contract/event-night-2026-10-16.md § 7 "Once your last match is in"): ten
// minutes after a player's last match is in (`why` "last") or the event is finished ("over"), when no photo of their
// deck is up yet. Queued by t1_private.deck_photo_nudge_send; the app opens Deck photos on Take a photo.
export function deckPhotoCopy(d: Record<string, unknown>): { title: string; body: string } {
  const name = typeof d.event_name === "string" && d.event_name.trim() ? d.event_name.trim() : "";
  const body = d.why === "over"
    ? `${name || "Your event"} is over. Tap to add a photo of your deck.`
    : `That was your last match${name ? ` in ${name}` : ""}. Tap to add a photo of your deck.`;
  return { title: "Add your deck photo", body };
}
