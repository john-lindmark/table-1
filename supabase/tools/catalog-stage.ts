// Fallback for the cards-sync "stage" step, for when inflating the bulk file does not fit the edge CPU budget.
// Runs the same staging (same PieceSplitter, same bucket layout) from any machine with Node 23+, then hands the
// run to Supabase: chunks, pack and cleanup still run in cards-sync.
//   SUPABASE_URL=https://aaozhfcbvqrgkkrihkrd.supabase.co SUPABASE_SERVICE_ROLE_KEY=... node supabase/tools/catalog-stage.ts
import { PieceSplitter, STAGE_PIECE_BYTES } from "../functions/cards-sync/catalog.ts";

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) throw new Error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
const auth = { Authorization: `Bearer ${key}`, apikey: key };
const UA = "Table1Events/1.0 (table-1.site)";

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: { ...auth, "Content-Type": "application/json" }, body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`${fn} ${r.status}: ${await r.text()}`);
  const text = await r.text();
  return (text ? JSON.parse(text) : null) as T;
}

const meta = await fetch("https://api.scryfall.com/bulk-data/default-cards", { headers: { "User-Agent": UA, Accept: "application/json" } });
const bulk = await meta.json() as { updated_at: string; jsonl_download_uri: string };
const run = await rpc<number | null>("catalog_run_begin", { p_bulk_updated_at: bulk.updated_at, p_source_uri: bulk.jsonl_download_uri });
if (run == null) {
  console.log("Nothing to do: this bulk file is done or a run is in flight.", bulk.updated_at);
  process.exit(0);
}
try {
  const res = await fetch(bulk.jsonl_download_uri, { headers: { "User-Agent": UA } });
  if (!res.ok || !res.body) throw new Error(`Scryfall bulk file ${res.status}`);
  const splitter = new PieceSplitter(STAGE_PIECE_BYTES, async (piece, n) => {
    const path = `${run}/${String(n).padStart(3, "0")}.jsonl`;
    const r = await fetch(`${url}/storage/v1/object/catalog-staging/${path}`, {
      method: "POST", headers: { ...auth, "Content-Type": "application/x-ndjson", "x-upsert": "true" }, body: piece,
    });
    if (!r.ok) throw new Error(`upload ${path} ${r.status}: ${await r.text()}`);
    console.log("staged", path, piece.length);
  });
  for await (const chunk of res.body.pipeThrough(new DecompressionStream("gzip"))) await splitter.push(chunk);
  await splitter.end();
  await rpc("catalog_run_staged", { p_run: run, p_chunks: splitter.count });
  console.log(`run ${run}: ${splitter.count} pieces staged; Supabase takes it from here`);
} catch (e) {
  await rpc("catalog_run_fail", { p_run: run, p_error: String(e) }).catch(() => {});
  throw e;
}
