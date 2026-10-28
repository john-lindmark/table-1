// cards-sync: keeps the card catalog (card_oracles / cards / card_prices) in step with Scryfall's
// default_cards bulk file, adds printed names in other languages from all_cards (weekly), and publishes the
// catalog pack clients download.
// Edge functions get 2s of CPU per request and 256MB of memory, and the bulk file is ~650MB of JSON, so the
// work runs in steps (driven by t1_private.catalog_dispatch through pg_net, shared x-t1-secret header):
//   {step:"stage"}           daily: stream + gunzip the file into ~32MB line-aligned pieces in catalog-staging
//   {step:"chunk", run, n}   parse one piece and upsert it in batches through catalog_ingest
//   {step:"names", run}      weekly, after the chunks: one ~10MB slice of all_cards (resumable inflate, inflate.ts)
//                            → printed names; each step asks for the next (t1_private.catalog_names_cursor)
//   {step:"pack", run}       build the catalog pack; publish it only if its content changed
//   {step:"cleanup", run}    remove the run's staging pieces
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  INGEST_BATCH, NAMES_BATCH, PieceSplitter, STAGE_PIECE_BYTES, namesFromSlice, packHeader, pieceLines, slimCard,
  type SlimCard,
} from "./catalog.ts";
import { type InflateCheckpoint, gzipHeaderBytes } from "./inflate.ts";
import { type ArtRow, artRow } from "./art.ts";

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
    let art: ArtRow[] = [];
    let rows = 0;
    const totals = { oracles: 0, cards: 0, prices: 0, art: 0 };
    const send = async () => {
      if (!batch.length) return;
      const r = await rpc<typeof totals>("catalog_ingest", { p_run: run, p_rows: batch });
      totals.oracles += r.oracles; totals.cards += r.cards; totals.prices += r.prices;
      // The same printings' illustrator and frame, once the cards are in (the pack's P lines carry them).
      totals.art += await rpc<number>("catalog_art_ingest", { p_run: run, p_rows: art });
      rows += batch.length;
      batch = [];
      art = [];
    };
    for (const line of pieceLines(piece)) {
      const card = JSON.parse(line);
      const slim = slimCard(card);
      if (slim) { batch.push(slim); art.push(artRow(card)); }
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

/** Cards per catalog_pack_part window: each part runs well inside the 8s statement timeout (~0.5s on 2026-10-16). */
const PACK_WINDOW = 10_000;

/**
 * The pack body, built in parts (O, P and N lines per window of cards) so it keeps fitting as the catalog grows;
 * the same text catalog_pack_body() returns.
 */
async function packBody() {
  const parts: string[] = [];
  let windows = 0;
  for (let kind = 0; kind < 3; kind++) {
    for (let w = 0; kind === 0 || w < windows; w++) {
      const part = await rpc<string | null>("catalog_pack_part", { p_kind: kind, p_from: w * PACK_WINDOW, p_to: (w + 1) * PACK_WINDOW });
      if (kind === 0 && part == null) { windows = w; break; }
      if (part) parts.push(part);
    }
  }
  return parts.join("\n");
}

async function pack(run: number) {
  try {
    await refreshPoints();
    const body = await packBody();
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

/**
 * Compressed bytes per names step: ~75MB of JSON inflated, inside 2s of CPU with the parsing (12MB until the CJK
 * languages joined NAME_LANGS and about half the lines got parsed).
 */
const NAMES_SLICE_BYTES = 10 * 1024 * 1024;
/** A step stops before a block when this much of its slice is left (deflate blocks are a few dozen KB). */
const NAMES_RESERVE_BYTES = 1024 * 1024;
const b64 = (b: Uint8Array) => {
  let s = "";
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
};
const unb64 = (s: string | null) => Uint8Array.from(atob(s ?? ""), (c) => c.charCodeAt(0));

/**
 * One step of the names pass: inflate the next slice of all_cards from the cursor, upsert the printed names of
 * NAME_LANGS printings, move the cursor. catalog_names_advance asks for the next step (or the pack after the last).
 */
async function names(run: number) {
  const st = await rpc<{ uri: string | null; bit: number | null; step: number; window: string; carry: string } | null>(
    "catalog_names_state", { p_run: run });
  if (!st) return { run, skipped: true };
  try {
    let uri = st.uri;
    if (!uri) {
      const meta = await fetch("https://api.scryfall.com/bulk-data/all-cards", { headers: SCRYFALL_HEADERS });
      if (!meta.ok) throw new Error(`Scryfall bulk-data ${meta.status}`);
      const bulk = await meta.json() as { jsonl_download_uri?: string; download_uri?: string };
      uri = bulk.jsonl_download_uri ?? bulk.download_uri ?? null;
      if (!uri?.endsWith(".gz")) throw new Error(`all_cards uri: ${uri}`);
    }
    const base = st.bit == null ? 0 : Math.floor(st.bit / 8);
    const res = await fetch(uri, {
      headers: { "User-Agent": SCRYFALL_HEADERS["User-Agent"], Range: `bytes=${base}-${base + NAMES_SLICE_BYTES - 1}` },
    });
    const total = Number(res.headers.get("content-range")?.split("/")[1]);
    if (res.status !== 206 || !total) {
      await res.body?.cancel();
      throw new Error(`all_cards range ${res.status}`);
    }
    const data = new Uint8Array(await res.arrayBuffer());
    const from: InflateCheckpoint = st.bit == null
      ? { bit: gzipHeaderBytes(data) * 8, window: new Uint8Array(0), final: false }
      : { bit: st.bit, window: unb64(st.window), final: false };
    const last = base + data.length >= total;

    const { checkpoint: cp, carry, names: rows } = namesFromSlice(data, base, from, unb64(st.carry), last ? 0 : NAMES_RESERVE_BYTES);
    if (!cp.final && last) throw new Error("all_cards ended before its last block");

    let added = 0;
    for (let i = 0; i < rows.length; i += NAMES_BATCH) {
      added += await rpc<number>("catalog_names_ingest", { p_run: run, p_rows: rows.slice(i, i + NAMES_BATCH) });
    }
    await rpc("catalog_names_advance", {
      p_run: run, p_step: st.step, p_uri: uri, p_bit: cp.bit, p_window: b64(cp.window), p_carry: b64(carry),
      p_final: cp.final,
    });
    return { run, step: st.step, names: rows.length, added, done: cp.final, at: Math.round(cp.bit / 8 / total * 100) + "%" };
  } catch (e) {
    await rpc("catalog_names_fail", { p_run: run, p_step: st.step, p_error: String(e) }).catch(() => {});
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
      case "names": return json(await names(Number(body.run)));
      default: return json({ error: "Unknown step" }, 400);
    }
  } catch (e) {
    console.error("cards-sync", body.step, String(e));
    return json({ error: String(e) }, 500);
  }
});
