// Collection Search finds decks, cubes and binders, Insights archetypes and rankings (contract/library-search-2026-10-18.md
// § Collection search). Your own lists are matched on the device by name (listMatches); everything else comes from
// library_search with p_all: other people's lists you can see, lists (yours too) holding a card the query names,
// archetypes and rankings.
import { supabase } from "./supabaseClient";
import { isLibraryDemo } from "./libraryDemo";
import { listMatches } from "./librarySearch";
import { loadFollows } from "./follows";

export type HitKind = "deck" | "cube" | "binder" | "archetype" | "ranking";

/** One of library_search's items. */
export interface ListHit {
  kind: HitKind;
  id: string;
  name: string;
  format?: string;
  for_trade?: boolean;
  cards?: number;
  owner?: { display_name: string; avatar_url?: string };
  /** Seen on their profile: open /u/<user_id>/<kind>/<id>. */
  user_id?: string;
  /** Seen through the link you followed with: open /l/<token>. */
  token?: string;
  following?: boolean;
  /** Your own, found by a card it holds. */
  mine?: boolean;
  /** Found by a card it holds, not its name. */
  has?: { name: string; qty: number };
  /** Archetypes: lists in the last 90 days. */
  decks?: number;
  /** Rankings: the cube's id or "set:<KEY>", and the name its maker gave it. */
  subject?: string;
  label?: string;
}

/** How many of each kind show before "Show all N". */
export const LISTS_SHOWN = 3;

/** The demo's stand-ins: followed items for other people's lists, and one archetype. */
const DEMO_ARCHETYPE: ListHit = { kind: "archetype", id: "19", name: "Izzet Murktide", format: "modern", decks: 37 };

export async function searchLists(query: string): Promise<ListHit[]> {
  if (isLibraryDemo()) {
    const items = (await loadFollows()) ?? [];
    const lists: ListHit[] = items
      .filter((f) => f.available && listMatches(query, `${f.name ?? ""} ${f.owner?.display_name ?? ""}`, f.format ?? ""))
      .map((f) => ({ kind: f.kind, id: f.id, name: f.name ?? "", format: f.format, for_trade: f.for_trade, cards: f.cards,
                     owner: f.owner, user_id: f.user_id, token: f.token, following: true }));
    return listMatches(query, DEMO_ARCHETYPE.name, "modern") ? [...lists, DEMO_ARCHETYPE] : lists;
  }
  const { data, error } = await supabase.rpc("library_search", { p_query: query.trim(), p_all: true });
  if (error) throw error;
  return (data as { items: ListHit[] }).items ?? [];
}

/** Where an item opens: your own screen, their profile section, the link it was followed through, an Insights
 *  archetype or a ranking. */
export function listHitHref(h: ListHit): string | null {
  switch (h.kind) {
    case "archetype": return h.format ? `/insights/${h.format}/archetype/${h.id}` : null;
    case "ranking": return `/library/ranking/${h.id}`;
    default:
      if (h.mine) return h.kind === "binder" ? `/library/binder/${h.id}` : `/library/list/${h.id}`;
      if (h.token) return `/l/${h.token}`;
      return h.user_id ? `/u/${h.user_id}/${h.kind}/${h.id}` : null;
  }
}
