// Singleton fields filed under a 60-card format. Melee and TopDeck file 7-point Highlander and Commander events as
// "Vintage" (2026-10-31: 3 of the first 3 paper Vintage events), which would fill its meta with decks no rule names.
// Real lists run many cards at 2–4 copies (MTGO Challenges Sep–Oct 2026: every Legacy list 11+, 99% of Vintage 8+);
// these fields run at most a basic land or two. Canadian Highlander is singleton by design and never checked.

import type { DeckIn } from "./types.ts";

const BASIC = /^(Snow-Covered )?(Plains|Island|Swamp|Mountain|Forest)$|^Wastes$/;

/** At most two non-basic cards at more than one copy. */
export function singletonDeck(main: [string, number][]): boolean {
  return main.filter(([name, q]) => q > 1 && !BASIC.test(name)).length <= 2;
}

/** Half or more of the event's decks are singleton, in a format that isn't. */
export function singletonField(format: string, decks: DeckIn[]): boolean {
  if (format === "canlander" || !decks.length) return false;
  return decks.filter((d) => singletonDeck(d.main)).length * 2 >= decks.length;
}
