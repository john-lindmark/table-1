// ranking-image: a ranking's list as a picture (picture.ts), for the Discord bot's /ranking post. The bot works the list
// out from the ranking it read as its owner and POSTs it here with the service key; the PNG comes back and the bot
// attaches it to its message, so no ranking is ever served at a public address.
//   POST { title, byline, cards: [{ oracle_id, name, card_id? }] }   Authorization: Bearer <service role key>
//   -> image/png (a top 100 is 1870 px wide, a top 50 1440; layoutFor)
// Deployed with verify_jwt off; the service key is compared exactly, so only the bot (or whatever holds that key) can ask.
// A card without the cube's printing is drawn in its usual one (card_oracles.source_card_id).
import { createClient } from "npm:@supabase/supabase-js@2";
import { initWasm, Resvg } from "npm:@resvg/resvg-wasm@2.6.2";
import { imageUrl } from "../deck-image/layout.ts";
import type { Art } from "../deck-image/svg.ts";
import { MAX_CARDS, rankingPicture } from "./picture.ts";
import { type Ask, layoutFor, parseAsk } from "./request.ts";

const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(Deno.env.get("SUPABASE_URL")!, SERVICE_KEY, { auth: { persistSession: false } });

const RESVG_WASM = "https://cdn.jsdelivr.net/npm/@resvg/resvg-wasm@2.6.2/index_bg.wasm";
const FONTS = [
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-Regular.ttf",
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-Bold.ttf",
];

let ready: Promise<Uint8Array[]> | null = null;
/** The renderer and its fonts, loaded once per instance. */
function renderer(): Promise<Uint8Array[]> {
  if (!ready) {
    ready = (async () => {
      const [wasm, ...fonts] = await Promise.all([
        fetch(RESVG_WASM).then((r) => r.arrayBuffer()),
        ...FONTS.map((f) => fetch(f).then((r) => (r.ok ? r.arrayBuffer() : new ArrayBuffer(0)))),
      ]);
      await initWasm(wasm);
      return fonts.filter((f) => f.byteLength > 0).map((f) => new Uint8Array(f));
    })();
    ready.catch(() => (ready = null));
  }
  return ready;
}

async function dataUrl(href: string): Promise<string | null> {
  try {
    const r = await fetch(href, { signal: AbortSignal.timeout(8000) });
    if (!r.ok) return null;
    const bytes = new Uint8Array(await r.arrayBuffer());
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return `data:image/jpeg;base64,${btoa(s)}`;
  } catch {
    return null;
  }
}

/** Every card's art, a few at a time; a card that can't be fetched shows its name instead. */
async function fetchArt(cards: { id: string; ts: number | null }[], size: "small" | "normal"): Promise<Map<string, Art>> {
  const out = new Map<string, Art>();
  const queue = [...cards];
  const worker = async () => {
    for (let c = queue.shift(); c; c = queue.shift()) out.set(c.id, { href: await dataUrl(imageUrl(c.id, c.ts, size)) });
  };
  await Promise.all(Array.from({ length: Math.min(12, queue.length) }, worker));
  return out;
}

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });

export async function render(ask: Ask): Promise<Uint8Array<ArrayBuffer>> {
  const cards = ask.cards.slice(0, MAX_CARDS);
  // The usual printing for cards the cube's printings don't name (Arena cube versions name none).
  const missing = cards.filter((c) => !c.card_id).map((c) => c.oracle_id);
  const usual = new Map<string, string>();
  if (missing.length) {
    const { data, error } = await admin.from("card_oracles").select("oracle_id, source_card_id").in("oracle_id", missing);
    if (error) throw new Error(`card_oracles: ${error.message}`);
    for (const r of data as { oracle_id: string; source_card_id: string | null }[]) if (r.source_card_id) usual.set(r.oracle_id, r.source_card_id);
  }
  const ids = cards.map((c) => c.card_id ?? usual.get(c.oracle_id) ?? null);
  const printings = new Map<string, { set: string; ts: number | null }>();
  const wanted = [...new Set(ids.filter((x): x is string => !!x))];
  if (wanted.length) {
    const { data, error } = await admin.from("cards").select("id, set_code, image_ts").in("id", wanted);
    if (error) throw new Error(`cards: ${error.message}`);
    for (const r of data as { id: string; set_code: string; image_ts: number | null }[]) printings.set(r.id, { set: r.set_code, ts: r.image_ts });
  }
  const layout = layoutFor(cards.length);
  const [fonts, art] = await Promise.all([renderer(), fetchArt(wanted.map((id) => ({ id, ts: printings.get(id)?.ts ?? null })), layout.art)]);
  const pic = rankingPicture({
    title: ask.title, byline: ask.byline, art,
    cards: cards.map((c, i) => ({ name: c.name, cardId: ids[i], set: ids[i] ? printings.get(ids[i]!)?.set ?? null : null })),
  });
  const r = new Resvg(pic.svg, {
    fitTo: { mode: "width", value: Math.round(pic.width * layout.scale) },
    font: { fontBuffers: fonts, loadSystemFonts: false, defaultFontFamily: "JetBrains Mono" },
  });
  const rendered = r.render().asPng();
  const png = new Uint8Array(new ArrayBuffer(rendered.byteLength));
  png.set(rendered);
  return png;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return text("POST only", 405);
  if (req.headers.get("Authorization") !== `Bearer ${SERVICE_KEY}`) return text("Not allowed", 403);
  const ask = parseAsk(await req.json().catch(() => null));
  if (!ask) return text("Send a title, a byline and 1 to 100 cards", 400);
  try {
    const png = await render(ask);
    return new Response(png, { status: 200, headers: { "Content-Type": "image/png", "Cache-Control": "no-store" } });
  } catch (e) {
    console.error("ranking-image:", e instanceof Error ? e.message : e);
    return text("Couldn't draw the ranking right now", 500);
  }
});
