// Alert text for `deck.found` (contract/deck-finder-2026-10-15.md § Jobs): a deck search the player started has
// finished. `data` comes from t1_private.deck_finder_push_data: job_id, status (deck / question / not_found /
// error) and the headline (name, placement, event, date), the question, or the message. The app opens the search.
export function deckFoundCopy(d: Record<string, unknown>): { title: string; body: string } {
  const s = (k: string) => (typeof d[k] === "string" ? (d[k] as string).trim() : "");
  switch (s("status")) {
    case "deck": {
      const where = ["placement", "event", "date"].map(s).filter(Boolean).join(" · ");
      return { title: "Deck found", body: `${s("name") || "A list"}${where ? ` · ${where}` : ""}. Tap to create it.` };
    }
    case "question":
      return { title: "Which deck?", body: `${s("question") || "The deck finder has a question."} Tap to answer.` };
    case "not_found":
      return { title: "No list found", body: s("message") || "Nothing suitable turned up. Try naming the archetype and format." };
    default:
      return { title: "Deck finder", body: s("message") || "The search couldn't finish. Try again." };
  }
}
