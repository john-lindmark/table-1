/** How a card list is drawn: rows, a grid of whole cards, or stacks that show each card's title bar with the
 *  last card in full (like cards fanned down a playmat). Same three as iOS `CardLayout`. */
export type CardLayout = "list" | "grid" | "stacks";
export const LAYOUTS: CardLayout[] = ["list", "grid", "stacks"];

/** The saved layout, falling back to the old List/Grid flag ("1" meant grid) and then to list. */
export function parseLayout(saved: string | null, legacyGrid: string | null): CardLayout {
  if (saved && (LAYOUTS as string[]).includes(saved)) return saved as CardLayout;
  return legacyGrid === "1" ? "grid" : "list";
}

/** All cards in stacks follows the sort: one stack per run of a set (titled by set code) when sorted by set,
 *  otherwise runs of ten in sort order. `setOf` returns "" when the set is unknown. A set can come back as a
 *  second run (Secret Lair drops have their own release dates), so keys carry the run's position. */
export function runStacks<T>(items: T[], bySet: boolean, setOf: (t: T) => string, keyPrefix = ""): { key: string; title?: string; items: T[] }[] {
  const out: { key: string; title?: string; items: T[] }[] = [];
  if (bySet) {
    let prev: string | null = null;
    for (const it of items) {
      const set = setOf(it);
      if (set === prev) out[out.length - 1].items.push(it);
      else out.push({ key: `set|${set}|${out.length}`, title: set ? set.toUpperCase() : "Unknown set", items: [it] });
      prev = set;
    }
    return out;
  }
  for (let i = 0; i < items.length; i += 10) out.push({ key: `${keyPrefix}${i}`, items: items.slice(i, i + 10) });
  return out;
}
