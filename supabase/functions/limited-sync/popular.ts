// Popular cubes to rank (contract/cube-rankings-2026-10-21.md § Popular cubes): read each cube's list from where it
// lives and hand it to popular_cube_put as [{name, card_id?, oracle_id?}].
//  - Cube Cobra (PowerLSV, LSVCube): the cube's JSON, as list-import reads it; main board only, each card in the
//    printing the cube shows.
//  - mtgo.com (Vintage Cube): the first table under a "Full Card List" heading (the page also keeps the previous
//    list and a change list); two cells a row, color then card, after a header row.
//  - Scryfall's cube lists (Arena Powered Cube): a search for cube:<code>, one row per card.

export interface PopularCard { name: string; card_id?: string; oracle_id?: string }
export interface PopularSource { key: string; source: "cubecobra" | "mtgo" | "scryfall"; ref: string }

const UA = "Table1/1.0 (table-1.site; cube rankings)";

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", rsquo: "’", lsquo: "‘" };
export function unescapeHtml(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (m, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(n) ? String.fromCodePoint(n) : m;
    }
    return ENTITIES[e.toLowerCase()] ?? m;
  });
}

/** Cube Cobra's cube JSON → the main board (basics, maybeboard left out). */
export function cubeCobraCards(cube: { cards?: { mainboard?: Array<Record<string, any>> } }): PopularCard[] {
  return (cube.cards?.mainboard ?? []).map((c) => ({
    name: String(c.details?.name ?? c.name ?? "").trim(),
    card_id: typeof c.cardID === "string" ? c.cardID : typeof c.details?.scryfall_id === "string" ? c.details.scryfall_id : undefined,
  })).filter((c) => c.name || c.card_id);
}

/** mtgo.com's card list page → the names in the current list (the first table after a "Full Card List" heading). */
export function mtgoCards(html: string): PopularCard[] {
  const heading = html.search(/Full Card List\s*<\/h[1-6]>/i);
  if (heading < 0) return [];
  const start = html.indexOf("<table", heading);
  const end = start < 0 ? -1 : html.indexOf("</table>", start);
  if (end < 0) return [];
  const names: PopularCard[] = [];
  for (const row of html.slice(start, end).split(/<tr\b/i).slice(1)) {
    const cells = [...row.matchAll(/<td\b[^>]*>([\s\S]*?)<\/td>/gi)].map((m) => unescapeHtml(m[1].replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim());
    if (cells.length < 2 || !cells[1] || /^card$/i.test(cells[1])) continue;
    names.push({ name: cells[1].replace(/’/g, "'") });
  }
  return names;
}

/** One page of a Scryfall search → its cards. */
export function scryfallCards(page: { data?: Array<Record<string, any>> }): PopularCard[] {
  return (page.data ?? []).map((c) => ({ name: String(c.name ?? ""), card_id: c.id, oracle_id: c.oracle_id ?? c.card_faces?.[0]?.oracle_id }))
    .filter((c) => c.name);
}

async function get(url: string, accept: string): Promise<Response> {
  const res = await fetch(url, { headers: { Accept: accept, "User-Agent": UA }, signal: AbortSignal.timeout(20_000) });
  if (!res.ok) throw new Error(`${new URL(url).host} answered ${res.status}`);
  return res;
}

/** Reads one cube's list from its source. */
export async function readPopular(s: PopularSource): Promise<PopularCard[]> {
  switch (s.source) {
    case "cubecobra":
      return cubeCobraCards(await (await get(`https://cubecobra.com/cube/api/cubejson/${encodeURIComponent(s.ref)}`, "application/json")).json());
    case "mtgo":
      return mtgoCards(await (await get(s.ref, "text/html")).text());
    case "scryfall": {
      const out: PopularCard[] = [];
      let url: string | undefined = `https://api.scryfall.com/cards/search?unique=cards&order=name&q=${encodeURIComponent(`cube:${s.ref}`)}`;
      for (let i = 0; url && i < 20; i++) {
        const page: { data?: Array<Record<string, any>>; has_more?: boolean; next_page?: string } = await (await get(url, "application/json")).json();
        out.push(...scryfallCards(page));
        url = page.has_more ? page.next_page : undefined;
        if (url) await new Promise((r) => setTimeout(r, 120));
      }
      return out;
    }
  }
}
