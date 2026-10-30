// A new set's cards from Scryfall's search API, as soon as the set appears (contract/catalog-2026-10-14.md § New sets).
// The daily bulk file brings the same cards later; ingesting them twice changes nothing (catalog_ingest's content hashes).
// No Deno or Supabase imports, so this file also runs under Node for local tests.

/** Every printing in the set, extras and variations included, so the count matches the set's card_count. */
export function setSearchUrl(code: string): string {
  const q = new URLSearchParams({ q: `e:${code}`, unique: "prints", include_extras: "true", include_variations: "true", order: "set" });
  return `https://api.scryfall.com/cards/search?${q}`;
}

/** Scryfall asks for 50–100 ms between requests. */
export const SCRYFALL_GAP_MS = 100;
/** Pages read per set at most (175 cards a page; the largest sets are ~1,000 printings). */
export const MAX_PAGES = 12;

// deno-lint-ignore no-explicit-any
export interface SearchPage { data?: any[]; has_more?: boolean; next_page?: string }

/** The next page to read, only on Scryfall's own host (a page's next_page is followed, never anything else). */
export function nextPage(p: SearchPage): string | null {
  if (!p.has_more || typeof p.next_page !== "string") return null;
  return p.next_page.startsWith("https://api.scryfall.com/") ? p.next_page : null;
}
