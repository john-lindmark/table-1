// cards-sync: keeps the card catalog (card_oracles / cards / card_prices) in step with Scryfall's
// default_cards bulk file and publishes the catalog pack clients download.
// Edge functions get 2s of CPU per request and 256MB of memory, and the bulk file is ~650MB of JSON, so the
// work runs in steps (driven by t1_private.catalog_dispatch through pg_net, shared x-t1-secret header):
//   {step:"stage"}           daily: stream + gunzip the file into ~32MB line-aligned pieces in catalog-staging
//   {step:"chunk", run, n}   parse one piece and upsert it in batches through catalog_ingest
//   {step:"pack", run}       build the catalog pack; publish it only if its content changed
//   {step:"cleanup", run}    remove the run's staging pieces
import { createClient } from "npm:@supabase/supabase-js@2";
import { INGEST_BATCH, PieceSplitter, STAGE_PIECE_BYTES, packHeader, pieceLines, slimCard, type SlimCard } from "./catalog.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const SCRYFALL_HEADERS = { "User-Agent": "Table1Events/1.0 (table-1.site)", Accept: "application/json" };
const STAGING = "catalog-staging";
const piecePath = (run: number, n: number) => `${run}/${String(n).padStart(3, "0")}.jsonl`;

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

async function stage() {
  const meta = await fetch("https://api.scryfall.com/bulk-data/default-cards", { headers: SCRYFALL_HEADERS });
  if (!meta.ok) throw new Error(`Scryfall bulk-data ${meta.status}`);
  const bulk = await meta.json() as { updated_at: string; jsonl_download_uri?: string; download_uri?: string };
  const uri = bulk.jsonl_download_uri ?? bulk.download_uri;
  if (!uri) throw new Error("Scryfall bulk-data has no download uri");

  const run = await rpc<number | null>("catalog_run_begin", { p_bulk_updated_at: bulk.updated_at, p_source_uri: uri });
  if (run == null) return { skipped: true, updated_at: bulk.updated_at };

  try {
    const res = await fetch(uri, { headers: { "User-Agent": SCRYFALL_HEADERS["User-Agent"] } });
    if (!res.ok || !res.body) throw new Error(`Scryfall bulk file ${res.status}`);
    // The file is served as a .gz object (not Content-Encoding), so inflate it here.
    const stream = uri.endsWith(".gz") ? res.body.pipeThrough(new DecompressionStream("gzip")) : res.body;
    const splitter = new PieceSplitter(STAGE_PIECE_BYTES, async (piece, n) => {
      const { error } = await admin.storage.from(STAGING)
        .upload(piecePath(run, n), piece, { contentType: "application/x-ndjson", upsert: true });
      if (error) throw new Error(`staging upload ${n}: ${error.message}`);
    });
    for await (const chunk of stream) await splitter.push(chunk);
    await splitter.end();
    await rpc("catalog_run_staged", { p_run: run, p_chunks: splitter.count });
    return { run, pieces: splitter.count };
  } catch (e) {
    await rpc("catalog_run_fail", { p_run: run, p_error: String(e) }).catch(() => {});
    throw e;
  }
}

async function chunk(run: number, n: number) {
  try {
    const { data, error } = await admin.storage.from(STAGING).download(piecePath(run, n));
    if (error || !data) throw new Error(`staging download ${n}: ${error?.message ?? "missing"}`);
    const piece = new Uint8Array(await data.arrayBuffer());
    let batch: SlimCard[] = [];
    let rows = 0;
    const totals = { oracles: 0, cards: 0, prices: 0 };
    const send = async () => {
      if (!batch.length) return;
      const r = await rpc<typeof totals>("catalog_ingest", { p_run: run, p_rows: batch });
      totals.oracles += r.oracles; totals.cards += r.cards; totals.prices += r.prices;
      rows += batch.length;
      batch = [];
    };
    for (const line of pieceLines(piece)) {
      const slim = slimCard(JSON.parse(line));
      if (slim) batch.push(slim);
      if (batch.length >= INGEST_BATCH) await send();
    }
    await send();
    await rpc("catalog_chunk_finish", { p_run: run, p_n: n, p_error: null });
    return { run, n, rows, ...totals };
  } catch (e) {
    await rpc("catalog_chunk_finish", { p_run: run, p_n: n, p_error: String(e) }).catch(() => {});
    throw e;
  }
}

async function sha256Hex(bytes: Uint8Array) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(d, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Canadian Highlander points (canadianhighlander.ca/points-list) into format_points, before every pack build. A
 * failed fetch or an unreadable page keeps the points already stored.
 */
async function refreshPoints() {
  try {
    const res = await fetch("https://canadianhighlander.ca/points-list/", { headers: { "User-Agent": SCRYFALL_HEADERS["User-Agent"], Accept: "text/html" }, signal: AbortSignal.timeout(15_000) });
    if (!res.ok) return;
    const html = await res.text();
    const rows = [...html.matchAll(/<td class="column-1">(.*?)<\/td><td class="column-2">(\d+)<\/td>/g)]
      .map((m) => ({ name: m[1].replace(/<[^>]+>/g, "").replace(/&#8217;|&rsquo;/g, "'").replace(/&amp;/g, "&").trim(), points: Number(m[2]) }))
      .filter((r) => r.name && r.points > 0);
    if (rows.length < 10) return; // the page changed shape: keep what we have
    const missing = await rpc<string[]>("format_points_replace", { p_format: "canlander", p_rows: rows });
    if (missing?.length) console.warn("canlander points: no card for", missing.join(", "));
  } catch (e) {
    console.warn("canlander points:", String(e));
  }
}

async function pack(run: number) {
  try {
    await refreshPoints();
    const body = await rpc<string>("catalog_pack_body", {});
    let oracles = 0, printings = 0;
    for (let i = 0; i < body.length;) {
      const c = body.charCodeAt(i);
      if (c === 79 /* O */) oracles++;
      else if (c === 80 /* P */) printings++;
      const nl = body.indexOf("\n", i);
      if (nl < 0) break;
      i = nl + 1;
    }
    // Version is the content hash of the body, so an unchanged catalog is never re-published.
    const enc = new TextEncoder();
    const version = "v1-" + (await sha256Hex(enc.encode(body))).slice(0, 12);
    const current = await rpc<{ version?: string } | null>("catalog_info", {});
    if (current?.version === version) {
      await rpc("catalog_pack_publish", {
        p_run: run, p_version: version, p_path: "", p_bytes: 0, p_sha256: "", p_oracles: oracles, p_printings: printings,
      });
      await cleanup(run);
      return { run, version, unchanged: true };
    }
    const text = packHeader(version, oracles, printings) + "\n" + body + "\n";
    const gz = new Uint8Array(
      await new Response(new Blob([text]).stream().pipeThrough(new CompressionStream("gzip"))).arrayBuffer(),
    );
    const path = `packs/${version}.tsv.gz`;
    const { error } = await admin.storage.from("catalog")
      .upload(path, gz, { contentType: "application/gzip", cacheControl: "31536000", upsert: true });
    if (error) throw new Error(`pack upload: ${error.message}`);
    const stale = await rpc<string[] | null>("catalog_pack_publish", {
      p_run: run, p_version: version, p_path: path, p_bytes: gz.length, p_sha256: await sha256Hex(gz),
      p_oracles: oracles, p_printings: printings,
    });
    if (stale?.length) await admin.storage.from("catalog").remove(stale);
    await cleanup(run);
    return { run, version, bytes: gz.length, oracles, printings, removed: stale?.length ?? 0 };
  } catch (e) {
    await rpc("catalog_run_fail", { p_run: run, p_error: String(e) }).catch(() => {});
    throw e;
  }
}

async function cleanup(run: number) {
  const { data } = await admin.storage.from(STAGING).list(String(run), { limit: 1000 });
  const paths = (data ?? []).map((o) => `${run}/${o.name}`);
  if (paths.length) await admin.storage.from(STAGING).remove(paths);
  return { run, removed: paths.length };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: req.headers.get("x-t1-secret") ?? "" });
  if (!ok) return json({ error: "Forbidden" }, 403);

  const body = await req.json().catch(() => ({})) as { step?: string; run?: number; n?: number };
  try {
    switch (body.step) {
      case "stage": return json(await stage());
      case "chunk": return json(await chunk(Number(body.run), Number(body.n)));
      case "pack": return json(await pack(Number(body.run)));
      case "cleanup": return json(await cleanup(Number(body.run)));
      default: return json({ error: "Unknown step" }, 400);
    }
  } catch (e) {
    console.error("cards-sync", body.step, String(e));
    return json({ error: String(e) }, 500);
  }
});
