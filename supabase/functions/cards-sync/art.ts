// The illustrator and frame of a Scryfall card, for the catalog pack's P lines (catalog_art_ingest; contract/catalog-2026-10-14.md).
// No Deno or Supabase imports, so this file also runs under Node for local tests.

// deno-lint-ignore no-explicit-any
type Json = any;

/** What catalog_art_ingest takes per printing. */
export interface ArtRow {
  id: string;
  artist: string;
  frame: string;
}

/** A double-faced card's artist is the front face's when Scryfall gives none for the card as a whole. */
export function artRow(c: Json): ArtRow {
  const faces: Json[] = Array.isArray(c.card_faces) ? c.card_faces : [];
  const artist = typeof c.artist === "string" && c.artist ? c.artist : (typeof faces[0]?.artist === "string" ? faces[0].artist : "");
  const frame = typeof c.frame === "string" ? c.frame : "";
  return { id: String(c.id), artist, frame };
}
