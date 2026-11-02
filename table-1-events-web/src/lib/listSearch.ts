// Collection Search finds decks, cubes and binders (contract/library-search-2026-10-18.md § Collection search).
// Your own are matched on the device (listMatches); everyone else's you can see come from library_search.
import { supabase } from "./supabaseClient";
import { isLibraryDemo } from "./libraryDemo";
import { listMatches } from "./librarySearch";
import { loadFollows } from "./follows";
import type { FollowKind } from "./follows";

/** One of library_search's items: someone else's binder, deck or cube. */
export interface ListHit {
  kind: FollowKind;
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
}

/** How many of each kind show before "Show all N". */
export const LISTS_SHOWN = 3;

export async function searchLists(query: string): Promise<ListHit[]> {
  if (isLibraryDemo()) {
    // The demo's followed items stand in for other people's.
    const items = (await loadFollows()) ?? [];
    return items.filter((f) => f.available && listMatches(query, `${f.name ?? ""} ${f.owner?.display_name ?? ""}`, f.format ?? ""))
      .map((f) => ({ kind: f.kind, id: f.id, name: f.name ?? "", format: f.format, for_trade: f.for_trade, cards: f.cards,
                     owner: f.owner, user_id: f.user_id, token: f.token, following: true }));
  }
  const { data, error } = await supabase.rpc("library_search", { p_query: query.trim() });
  if (error) throw error;
  return (data as { items: ListHit[] }).items ?? [];
}

/** Where someone else's item opens: its profile section, or the link it was followed through. */
export function listHitHref(h: ListHit): string | null {
  if (h.token) return `/l/${h.token}`;
  return h.user_id ? `/u/${h.user_id}/${h.kind}/${h.id}` : null;
}
