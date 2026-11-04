// What the bot sends ranking-image (index.ts), checked. Pure, for the tests.
import { MAX_CARDS } from "./picture.ts";

/** Points to pixels, the Scryfall size the cards are fetched in, and resvg's image rendering. Every card is drawn at
 *  exactly the small image's 146 px (168 pt × 146/168), so no image is resampled and nearest-neighbour costs nothing:
 *  smoothing and per-card clip layers were the render's CPU, and a top 50 at 1.5× with them hit the edge's limit
 *  (546 WORKER_RESOURCE_LIMIT, 2026-11-04). On a Mac a top 50 went 629 → 79 ms of rendering. */
export const layoutFor = (_n: number): { scale: number; art: "small" | "normal"; imageRendering: 0 | 1 } =>
  ({ scale: 146 / 168, art: "small", imageRendering: 1 });

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
