// What the bot sends ranking-image (index.ts), checked. Pure, for the tests.
import { MAX_CARDS } from "./picture.ts";

/** Points to pixels, and the Scryfall size the cards are fetched in. Scryfall's small images (146 px wide) keep the
 *  render inside an edge function's CPU budget: 100 full-size images took 2.1 s of rendering on a Mac at 1.5×, small
 *  ones 0.8 s at 1×. Up to 50 cards are drawn at 1.5×, more at 1×; either way about 0.75 s (measured 2026-11-03). */
export const layoutFor = (n: number): { scale: number; art: "small" | "normal" } => ({ scale: n > 50 ? 1 : 1.5, art: "small" });

export interface AskCard { oracle_id: string; name: string; card_id: string | null }
export interface Ask { title: string; byline: string; cards: AskCard[] }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The body, or null when it isn't a title, a byline and 1 to 100 cards with Oracle ids. */
export function parseAsk(b: unknown): Ask | null {
  if (!b || typeof b !== "object") return null;
  const o = b as Record<string, unknown>;
  if (typeof o.title !== "string" || typeof o.byline !== "string" || !Array.isArray(o.cards)) return null;
  if (o.cards.length < 1 || o.cards.length > MAX_CARDS) return null;
  const cards: AskCard[] = [];
  for (const c of o.cards as Record<string, unknown>[]) {
    if (!c || typeof c.oracle_id !== "string" || !UUID.test(c.oracle_id) || typeof c.name !== "string") return null;
    const id = typeof c.card_id === "string" && UUID.test(c.card_id) ? c.card_id.toLowerCase() : null;
    cards.push({ oracle_id: c.oracle_id.toLowerCase(), name: c.name.slice(0, 200), card_id: id });
  }
  return { title: o.title.slice(0, 200), byline: o.byline.slice(0, 300), cards };
}
