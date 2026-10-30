// meta-image: Insights charts as pictures, for the Discord bot's /meta commands (contract/discord-2026-10-29.md
// § Insights images) and anything else that embeds an image by URL.
//   GET /functions/v1/meta-image/<format>/<kind>.png?tier=big|all&days=7|14|30|90[&a=<archetype id>][&v=<anything>]
//   kind: matchups (the grid), winrates (every archetype's match win rate with its 95% range), deck (one archetype's
//   matchups; needs a)
// The data is the format's public Insights pack (the catalog bucket's insights/constructed/<format>.json, rebuilt every
// six hours), so nothing here is private and nothing needs a JWT (deployed with verify_jwt off: Discord's image proxy
// sends none). The SVG is drawn by charts.ts and rasterized by resvg (WASM); fonts and the WASM load once per instance.
// Packs are kept 5 minutes and pictures by pack build, so a picture posted to a busy channel draws once.
import { initWasm, Resvg } from "npm:@resvg/resvg-wasm@2.6.2";
import { type Pack, WIDTH } from "./charts.ts";
import { draw, parseRequest } from "./request.ts";

const PACKS = Deno.env.get("META_PACK_BASE") || `${Deno.env.get("SUPABASE_URL")}/storage/v1/object/public/catalog/insights/constructed`;
const RESVG_WASM = "https://cdn.jsdelivr.net/npm/@resvg/resvg-wasm@2.6.2/index_bg.wasm";
const FONTS = [
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-Regular.ttf",
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-Medium.ttf",
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-SemiBold.ttf",
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

const packs = new Map<string, { pack: Pack; at: number }>();
async function packFor(format: string): Promise<Pack | null> {
  const hit = packs.get(format);
  if (hit && Date.now() - hit.at < 5 * 60_000) return hit.pack;
  const r = await fetch(`${PACKS}/${format}.json`, { signal: AbortSignal.timeout(8000) });
  if (r.status === 404 || r.status === 400) return null;
  if (!r.ok) throw new Error(`pack ${format}: ${r.status}`);
  const pack = await r.json() as Pack;
  packs.set(format, { pack, at: Date.now() });
  return pack;
}

/** Finished pictures: the newest 16, by request and pack build. */
const cache = new Map<string, { png: Uint8Array<ArrayBuffer>; at: number }>();
function remember(key: string, png: Uint8Array<ArrayBuffer>) {
  cache.set(key, { png, at: Date.now() });
  if (cache.size > 16) {
    const oldest = [...cache.entries()].sort((a, b) => a[1].at - b[1].at)[0];
    if (oldest) cache.delete(oldest[0]);
  }
}

const text = (body: string, status: number) =>
  new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } });

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") return text("GET only", 405);
  const q = parseRequest(new URL(req.url));
  if (!q) return text("Not found", 404);
  const headers = { "Content-Type": "image/png", "Cache-Control": "public, max-age=1800, s-maxage=3600", "X-Content-Type-Options": "nosniff" };
  try {
    const pack = await packFor(q.format);
    if (!pack) return text("No Insights for that format", 404);
    const key = `${q.format}/${q.kind}/${q.tier}/${q.days}/${q.a ?? ""}@${pack.built_at}`;
    let png = cache.get(key)?.png;
    if (!png) {
      const [fonts, pic] = await Promise.all([renderer(), Promise.resolve(draw(pack, q))]);
      const r = new Resvg(pic.svg, {
        fitTo: { mode: "width", value: WIDTH },
        font: { fontBuffers: fonts, loadSystemFonts: false, defaultFontFamily: "JetBrains Mono" },
      });
      const out = r.render().asPng();
      png = new Uint8Array(new ArrayBuffer(out.byteLength));
      png.set(out);
      remember(key, png);
    }
    return new Response(req.method === "HEAD" ? null : png, { status: 200, headers });
  } catch (e) {
    console.error("meta-image:", e instanceof Error ? e.message : e);
    return text("Couldn't draw that right now", 500);
  }
});
