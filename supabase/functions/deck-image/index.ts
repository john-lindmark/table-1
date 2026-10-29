// deck-image: a deck's picture (contract/deck-image-2026-10-20.md) drawn on the server, for places that can't draw it
// themselves: the Discord bot's deck post, and anything else that embeds an image by URL.
//   GET /functions/v1/deck-image/<share token>.png?v=<deck version>   -> image/png (1600 px wide, 16:9 or taller)
// The share token is the deck's "Anyone with the link" token (contract/share-links-2026-10-23.md): whoever has it may
// see the deck, so they may see its picture; a closed link is a 404. Deployed with verify_jwt off (Discord's image proxy
// sends no JWT). The SVG is drawn by svg.ts and rasterized by resvg (WASM); fonts and the WASM load once per instance.
// Pictures are cached in memory by token and version, so a card shared to a busy channel renders once.
import { createClient } from "npm:@supabase/supabase-js@2";
import { initWasm, Resvg } from "npm:@resvg/resvg-wasm@2.6.2";
import { ASPECT, fit, imageUrl, type Line, ordered, plan } from "./layout.ts";
import { type Art, artSize, picture } from "./svg.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const OUT_WIDTH = 1600;
const RESVG_WASM = "https://cdn.jsdelivr.net/npm/@resvg/resvg-wasm@2.6.2/index_bg.wasm";
const FONTS = [
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-Regular.ttf",
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-Medium.ttf",
  "https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@v2.304/fonts/ttf/JetBrainsMono-SemiBold.ttf",
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

/** A small in-memory cache of finished pictures: the newest 8, by token and version. */
const cache = new Map<string, { png: Uint8Array<ArrayBuffer>; at: number }>();
const CACHE_MAX = 8;
function remember(key: string, png: Uint8Array<ArrayBuffer>) {
  cache.set(key, { png, at: Date.now() });
  if (cache.size > CACHE_MAX) {
    const oldest = [...cache.entries()].sort((a, b) => a[1].at - b[1].at)[0];
    if (oldest) cache.delete(oldest[0]);
  }
}

export function parseRequest(u: URL): { token: string; version: string } | null {
  const m = /\/deck-image\/([A-Za-z0-9_-]{16,40})(?:\.png)?\/?$/.exec(u.pathname);
  if (!m) return null;
  const v = u.searchParams.get("v") ?? "";
  return { token: m[1], version: /^[0-9]{1,9}$/.test(v) ? v : "" };
}

async function dataUrl(href: string): Promise<string | null> {
  try {
    const r = await fetch(href, { signal: AbortSignal.timeout(6000) });
    if (!r.ok) return null;
    const bytes = new Uint8Array(await r.arrayBuffer());
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return `data:image/jpeg;base64,${btoa(s)}`;
  } catch {
    return null;
  }
}

/** Fetches every card's art, a few at a time. */
async function fetchArt(cardIds: { id: string; ts: number | null }[], size: "small" | "normal"): Promise<Map<string, Art>> {
  const out = new Map<string, Art>();
  const queue = [...cardIds];
  const worker = async () => {
    for (let c = queue.shift(); c; c = queue.shift()) out.set(c.id, { href: await dataUrl(imageUrl(c.id, c.ts, size)) });
  };
  await Promise.all(Array.from({ length: Math.min(12, queue.length) }, worker));
  return out;
}

const text = (body: string, status: number, extra: Record<string, string> = {}) =>
  new Response(body, { status, headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", ...extra } });

export async function render(token: string): Promise<{ png: Uint8Array<ArrayBuffer>; version: number } | { error: string; status: number }> {
  const { data, error } = await admin.rpc("deck_image_data", { p_token: token });
  if (error) {
    if (error.code === "42501" || error.code === "22023") return { error: "This isn't available", status: 404 };
    throw new Error(`deck_image_data: ${error.code} ${error.message}`);
  }
  const d = data as { name: string; format: string; version: number; owner: string | null; lines: Line[] };
  const p = plan(d.lines);
  const f = fit(ordered(p).length, p.side.length);
  const scale = OUT_WIDTH / 1200;
  const size = artSize(f.cw * scale);
  const want = new Map<string, number | null>();
  for (const c of [...ordered(p), ...p.side]) want.set(c.cardId, c.imageTs);
  const [fonts, art] = await Promise.all([renderer(), fetchArt([...want].map(([id, ts]) => ({ id, ts })), size)]);
  const pic = picture({ name: d.name, format: d.format, player: d.owner, plan: p, art });
  const r = new Resvg(pic.svg, {
    fitTo: { mode: "width", value: OUT_WIDTH },
    font: { fontBuffers: fonts, loadSystemFonts: false, defaultFontFamily: "JetBrains Mono" },
    imageRendering: f.cw * scale * ASPECT > 300 ? 0 : 1,
  });
  const rendered = r.render().asPng();
  const png = new Uint8Array(new ArrayBuffer(rendered.byteLength));
  png.set(rendered);
  return { png, version: d.version };
}

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") return text("GET only", 405);
  const u = new URL(req.url);
  const q = parseRequest(u);
  if (!q) return text("Not found", 404);
  const key = `${q.token}@${q.version}`;
  const hit = cache.get(key);
  const headers = {
    "Content-Type": "image/png",
    "Cache-Control": "public, max-age=3600, s-maxage=86400",
    "X-Content-Type-Options": "nosniff",
  };
  if (hit) return new Response(req.method === "HEAD" ? null : hit.png, { status: 200, headers });
  try {
    const out = await render(q.token);
    if ("error" in out) return text(out.error, out.status);
    remember(`${q.token}@${out.version}`, out.png);
    if (q.version) remember(key, out.png);
    return new Response(req.method === "HEAD" ? null : out.png, { status: 200, headers });
  } catch (e) {
    console.error("deck-image:", e instanceof Error ? e.message : e);
    return text("Couldn't draw the deck right now", 500);
  }
});
