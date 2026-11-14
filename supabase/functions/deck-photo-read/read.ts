// Reading a decklist off a deck photo (contract/deck-photo-lists-2026-11-13.md): the instructions for the model,
// the shape it answers in, and how its names become catalog cards. Pure; index.ts does the I/O.

export type Board = "main" | "side" | "out";

/** One card as the model reports it. */
export interface Seen { name: string; qty: number; board: Board; sure: boolean; read?: string }
/** One line of the stored list. card_id null = a title no card matched. */
export interface Entry { card_id: string | null; name: string; qty: number; board: Board; sure: boolean; read?: string }

export interface Pool { kind: "set" | "cube" | "none"; label: string; cards: [string, string][] }
export interface EventInfo { name: string; event_type: string | null; format: string | null; format_label: string | null }
/** A catalog answer for a name outside the pool (deck_photo_read_names). */
export interface Named { q: string; name: string | null; card_id: string | null; exact: boolean | null }

export const SCHEMA = {
  type: "object",
  properties: {
    cards: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          qty: { type: "integer" },
          board: { type: "string", enum: ["main", "side", "out"] },
          sure: { type: "boolean" },
          read: { type: "string" },
        },
        required: ["name", "qty", "board", "sure", "read"],
        additionalProperties: false,
      },
    },
    notes: { type: "string" },
  },
  required: ["cards", "notes"],
  additionalProperties: false,
} as const;

export const SYSTEM = `You read a photo of a Magic: The Gathering deck that a player laid out on a table after an event, so the deck can be written down as a decklist. The photo may be turned sideways or upside down as a whole.

List every card:

- name: the card's English name (a card printed in another language gets its English name). When a card pool is given, the deck was almost certainly built from it: use the pool's exact spelling, and when a title is partly hidden, glared out or blurred, pick the pool card that fits what you can see (the letters showing, the mana cost, the frame color, the art, the type line, the text box). A card outside the pool is fine when you can read its whole title: packs hold cards filed under other sets. Basic lands (Plains, Island, Swamp, Mountain, Forest, Wastes) are always allowed.
- qty: how many copies are in the photo. Cards are often fanned or overlapped so only the title bars show: each title bar is a copy. Players put a die on a pile of basic lands to say how many of that land the deck runs: when a die sits on a land pile, its top face is the count (add two dice on one pile). For a squared pile without a die, count the card edges you can see and give your best estimate.
- board: "main" for the deck itself. "out" for cards that are in the photo but not in the deck: cards lying sideways to the rest of the layout, strays off the playmat or cut off at the photo's edge, another player's cards. "side" only for a clearly separate, upright group that is this deck's sideboard (a row or block set apart from a constructed deck).
- sure: false when you guessed the name from partial evidence or estimated a pile's count; true otherwise (a count read off a die is sure).
- read: only when sure is false, a few words on what you saw ("title hidden, red 2-drop with goblin art", "pile of about 7, no die"); else empty.

Leave out tokens, emblems, counters, sleeves, deck boxes, face-down cards and anything that isn't a Magic card. Never add a card you cannot see because a deck "should" have it. When a deck size is given and the only doubtful numbers are basic land piles, prefer the pile counts that bring the main deck to that size.

notes: one short sentence on anything that made the photo hard to read (cut off, glare, far away), else empty.`;

/** How many cards the main deck should hold, when the event says. */
export function deckSize(e: EventInfo): number | null {
  const f = (e.format ?? "").toLowerCase();
  if ((e.event_type ?? "").toLowerCase() === "limited") return 40;
  if (["commander", "canlander", "canadian_highlander", "pauper_commander", "paupercommander"].includes(f)) return 100;
  if (f === "oathbreaker") return 60;
  if ((e.event_type ?? "").toLowerCase() === "constructed") return 60;
  return null;
}

/** The text beside the photo: the event, the expected size, the pool. */
export function ask(e: EventInfo, pool: Pool): string {
  const size = deckSize(e);
  const lines = [`Event: ${e.name} (${e.format_label || e.format || "Magic"}).`];
  if (size === 40) lines.push("Deck size: a limited deck, usually exactly 40 cards with about 16-18 lands.");
  else if (size === 100) lines.push("Deck size: 100 cards, one copy of each card apart from basic lands.");
  else if (size) lines.push(`Deck size: at least ${size} cards in the main deck, up to 15 in the sideboard.`);
  if (pool.cards.length) {
    lines.push(`Card pool (${pool.label}, ${pool.cards.length} cards), one name per line:`);
    lines.push(pool.cards.map(([n]) => n).join("\n"));
  } else {
    lines.push("No card pool is known for this event: name cards from what you can read.");
  }
  return lines.join("\n");
}

/** Lowercase, no accents or punctuation, single spaces: how names are compared. */
export function norm(s: string): string {
  return s.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/æ/g, "ae").replace(/œ/g, "oe")
    .replace(/['’]/g, "").replace(/[^a-z0-9]+/g, " ").trim();
}

const BASICS = new Set(["plains", "island", "swamp", "mountain", "forest", "wastes"]);
export const isBasic = (name: string) => BASICS.has(norm(name).replace(/^snow covered /, ""));

function trigrams(s: string): Map<string, number> {
  const t = `  ${s} `;
  const m = new Map<string, number>();
  for (let i = 0; i + 3 <= t.length; i++) m.set(t.slice(i, i + 3), (m.get(t.slice(i, i + 3)) ?? 0) + 1);
  return m;
}
/** Dice coefficient over character trigrams, 0–1. */
export function similar(a: string, b: string): number {
  const x = trigrams(a), y = trigrams(b);
  let both = 0, nx = 0, ny = 0;
  for (const [k, v] of x) { nx += v; both += Math.min(v, y.get(k) ?? 0); }
  for (const v of y.values()) ny += v;
  return nx + ny ? (2 * both) / (nx + ny) : 0;
}

export const FUZZY = 0.72;
export const MARGIN = 0.08;

export interface PoolIndex { exact: Map<string, [string, string]>; all: { key: string; card: [string, string] }[] }
export function indexPool(pool: Pool): PoolIndex {
  const exact = new Map<string, [string, string]>();
  const all: PoolIndex["all"] = [];
  for (const card of pool.cards) {
    const whole = norm(card[0]);
    if (!exact.has(whole)) exact.set(whole, card);
    all.push({ key: whole, card });
    const face = norm(card[0].split(" // ")[0]);
    if (face !== whole) {
      if (!exact.has(face)) exact.set(face, card);
      all.push({ key: face, card });
    }
  }
  return { exact, all };
}

/** A name against the pool: the exact card, else the one close card (clearly closer than the runner-up). */
export function inPool(ix: PoolIndex, name: string): { card: [string, string]; exact: boolean } | null {
  const q = norm(name);
  if (!q) return null;
  const hit = ix.exact.get(q) ?? ix.exact.get(norm(name.split(" // ")[0]));
  if (hit) return { card: hit, exact: true };
  if (q.length < 4) return null;
  // Each card's best score over its names (a split card is indexed whole and by its first half).
  const scores = new Map<string, { card: [string, string]; s: number }>();
  for (const { key, card } of ix.all) {
    const s = similar(q, key);
    const had = scores.get(card[1]);
    if (!had || s > had.s) scores.set(card[1], { card, s });
  }
  const ranked = [...scores.values()].sort((x, y) => y.s - x.s);
  const best = ranked[0]?.card ?? null, top = ranked[0]?.s ?? 0, next = ranked[1]?.s ?? 0;
  return best && top >= FUZZY && top - next >= MARGIN ? { card: best, exact: false } : null;
}

/** The model's answer made safe: known boards, counts 1–99, names trimmed, nameless lines dropped. */
export function seen(raw: unknown): { cards: Seen[]; notes: string } {
  const r = (raw ?? {}) as { cards?: unknown; notes?: unknown };
  const cards: Seen[] = [];
  for (const c of Array.isArray(r.cards) ? r.cards.slice(0, 250) : []) {
    const x = (c ?? {}) as Record<string, unknown>;
    const name = String(x.name ?? "").trim().slice(0, 80);
    if (!name) continue;
    const qty = Math.min(99, Math.max(1, Math.round(Number(x.qty) || 1)));
    const board: Board = x.board === "side" || x.board === "out" ? x.board : "main";
    const read = String(x.read ?? "").trim().slice(0, 120);
    cards.push({ name, qty, board, sure: x.sure !== false, ...(read ? { read } : {}) });
  }
  return { cards, notes: String(r.notes ?? "").trim().slice(0, 300) };
}

/** The names the catalog has to settle: everything the pool doesn't hold exactly. */
export function toAsk(cards: Seen[], ix: PoolIndex): string[] {
  const out = new Set<string>();
  for (const c of cards) if (!ix.exact.has(norm(c.name)) && !ix.exact.has(norm(c.name.split(" // ")[0]))) out.add(c.name);
  return [...out];
}

/** The stored list: each seen card as a pool card, else a catalog card, else a bare title to fix; same card and
 *  board merged; main first, then side, then out, in the order seen. */
export function entries(cards: Seen[], ix: PoolIndex, named: Named[]): Entry[] {
  const byQ = new Map(named.map((n) => [n.q, n]));
  const out: Entry[] = [];
  const at = new Map<string, number>();
  for (const c of cards) {
    const pool = inPool(ix, c.name);
    const cat = byQ.get(c.name);
    let e: Entry;
    if (pool?.exact) {
      e = { card_id: pool.card[1], name: pool.card[0], qty: c.qty, board: c.board, sure: c.sure };
    } else if (cat?.card_id && cat.name && cat.exact) {
      // A whole title the catalog knows beats a near miss in the pool.
      e = { card_id: cat.card_id, name: cat.name, qty: c.qty, board: c.board, sure: c.sure };
    } else if (pool) {
      e = { card_id: pool.card[1], name: pool.card[0], qty: c.qty, board: c.board, sure: false, read: c.read || `read as "${c.name}"` };
    } else if (cat?.card_id && cat.name) {
      e = { card_id: cat.card_id, name: cat.name, qty: c.qty, board: c.board, sure: false, read: c.read || `read as "${c.name}"` };
    } else {
      e = { card_id: null, name: c.name, qty: c.qty, board: c.board, sure: false };
    }
    if (c.read && !e.sure && !e.read) e.read = c.read;
    if (e.sure) delete e.read;
    const key = `${e.card_id ?? `?${norm(e.name)}`}|${e.board}`;
    const i = at.get(key);
    if (i === undefined) { at.set(key, out.length); out.push(e); }
    else {
      out[i].qty = Math.min(99, out[i].qty + e.qty);
      if (!e.sure) { out[i].sure = false; out[i].read ??= e.read; }
    }
  }
  const order: Record<Board, number> = { main: 0, side: 1, out: 2 };
  return out.map((e, i) => ({ e, i })).sort((a, b) => order[a.e.board] - order[b.e.board] || a.i - b.i).map((x) => x.e);
}

/** Cards in the deck (main + side) and lines to check. */
export function totals(list: Entry[]): { cards: number; main: number; check: number } {
  let cards = 0, main = 0, check = 0;
  for (const e of list) {
    if (e.board === "out") continue;
    cards += e.qty;
    if (e.board === "main") main += e.qty;
    if (!e.card_id || !e.sure) check++;
  }
  return { cards, main, check };
}

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** The steps the screen shows while the photo is read. */
export const STEP_LOOK = "Looking at the photo";
export function stepPool(pool: Pool): string {
  return pool.cards.length ? `Reading against ${pool.label}: ${plural(pool.cards.length, "card")}` : "Reading every title: no card pool for this event";
}
export function stepDone(list: Entry[]): string {
  const t = totals(list);
  return t.check ? `Read ${plural(t.cards, "card")}: ${t.check} to check` : `Read ${plural(t.cards, "card")}`;
}

/** How a read compares with a reference list (same shape), by card name and board, `out` ignored:
 *  copies in both ÷ copies in the reference (recall) and ÷ copies read (precision). */
export function score(read: { name: string; qty: number; board: string }[], want: { name: string; qty: number; board: string }[]) {
  const bag = (l: { name: string; qty: number; board: string }[]) => {
    const m = new Map<string, number>();
    for (const c of l) if (c.board !== "out") m.set(norm(c.name), (m.get(norm(c.name)) ?? 0) + c.qty);
    return m;
  };
  const a = bag(read), b = bag(want);
  let both = 0, na = 0, nb = 0;
  for (const v of a.values()) na += v;
  for (const [k, v] of b) { nb += v; both += Math.min(v, a.get(k) ?? 0); }
  return { read: na, want: nb, both, recall: nb ? both / nb : 1, precision: na ? both / na : 1 };
}
