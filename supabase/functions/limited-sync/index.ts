// limited-sync: Insights' Limited side (contract/insights-2026-10-24.md § Limited pack), from 17Lands' public
// datasets (CC BY 4.0; credited on every Limited screen). Driven by pg_cron through pg_net (x-t1-secret):
//   {step:"check"}        daily: HEAD each recent set's game and draft files; a new Last-Modified opens a run
//   {step:"slice", run}   one slice of a run: range-fetch the next compressed bytes, inflate from the checkpoint
//                         (cards-sync's resumable inflate), add the rows' sums; the last slice builds the set's pack
// t1_private.limited_dispatch posts the next slice (every 2 min, and right after each commit).
import { createClient } from "npm:@supabase/supabase-js@2";
import { briefFor, type Facts } from "../insight-brief/brief.ts";
import { inflateMembers, startAt } from "./members.ts";
import { accJson, headerColumns, Lines, Rows } from "./parse.ts";
import { limitedFacts, type LimitedPack } from "./pack.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const BASE = "https://17lands-public.s3.amazonaws.com/analysis_data";
const EVENTS = ["PremierDraft", "TradDraft", "PickTwoDraft", "Sealed", "TradSealed"];
/** Compressed bytes per slice (game rows are mostly zeros, ~37× on inflate; draft rows ~10× with more text) and
 *  inflated bytes per slice: ~0.4 s of CPU on a laptop, inside the edge's 2 s. */
const SLICE_BYTES = { game: 5_000_000, draft: 2_500_000 };
const OUT_BYTES = 240 * 1024 * 1024;
const RESERVE = 256 * 1024;
const EMBARGO_DAYS = 12;

async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}
const b64 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const fileUri = (set: string, event: string, kind: "game" | "draft") => `${BASE}/${kind}_data/${kind}_data_public.${set}.${event}.csv.gz`;

async function check() {
  const sets = await rpc<{ set_code: string; released: string }[]>("limited_candidates");
  const opened: string[] = [];
  for (const s of sets) {
    if (Date.now() - Date.parse(s.released) < EMBARGO_DAYS * 86400000) continue;
    for (const event of EVENTS) {
      for (const kind of ["game", "draft"] as const) {
        if (kind === "draft" && event.includes("Sealed")) continue;
        const uri = fileUri(s.set_code, event, kind);
        const res = await fetch(uri, { method: "HEAD" });
        if (!res.ok) continue;
        const lm = res.headers.get("last-modified"), len = Number(res.headers.get("content-length"));
        if (!lm || !len) continue;
        const id = await rpc<number | null>("limited_run_open", {
          p_set: s.set_code, p_event: event, p_kind: kind, p_uri: uri, p_last_modified: new Date(lm).toISOString(), p_total: len,
        });
        if (id) opened.push(`${s.set_code} ${event} ${kind}`);
      }
    }
  }
  if (opened.length) await rpc("limited_kick");
  return { opened };
}

interface RunState {
  id: number; set_code: string; event_type: string; kind: "game" | "draft"; uri: string; total_bytes: number;
  step: number; bit: number | null; win: string; carry: string; header: { cols: string[] } | null; released: string | null;
}

async function slice(runId: number) {
  const st = await rpc<RunState | null>("limited_run_state", { p_run: runId });
  if (!st) return { run: runId, skipped: true };
  try {
    const base = st.bit == null ? 0 : Math.floor(st.bit / 8);
    const res = await fetch(st.uri, { headers: { Range: `bytes=${base}-${base + SLICE_BYTES[st.kind] - 1}` } });
    const total = Number(res.headers.get("content-range")?.split("/")[1]);
    if (res.status !== 206 || !total) { await res.body?.cancel(); throw new Error(`17Lands range ${res.status}`); }
    if (total !== st.total_bytes) throw new Error("the file changed during the run");
    const data = new Uint8Array(await res.arrayBuffer());
    const from = startAt(data, base, st.bit, unb64(st.win));

    let header = st.header?.cols ?? null;
    let rows: Rows | null = header ? new Rows({ kind: st.kind, cols: header }, st.released ? Date.parse(st.released) : null) : null;
    const lines = new Lines(unb64(st.carry), (b) => {
      if (!rows) {
        header = headerColumns(new TextDecoder().decode(b));
        rows = new Rows({ kind: st.kind, cols: header }, st.released ? Date.parse(st.released) : null);
      } else rows.line(b);
    });
    const { checkpoint: cp, done } = inflateMembers(data, base, total, from, RESERVE, OUT_BYTES, (out) => lines.push(out));
    if (done) lines.end();
    else if (cp.bit === from.bit) throw new Error("the slice holds no whole deflate block");
    else if (base + data.length >= total && cp.bit / 8 >= total) throw new Error("the file ended before its last block");
    const r = rows as Rows | null;
    const status = await rpc<string>("limited_step_commit", {
      p_run: runId, p_step: st.step, p_bit: cp.bit, p_window: b64(cp.window), p_carry: b64(lines.carry),
      p_header: st.header ? null : { cols: header }, p_rows: r?.rows ?? 0, p_acc: r ? accJson(r.acc) : {}, p_final: done,
    });
    let pack: unknown = null;
    if (status === "done") pack = await buildPack(st.set_code);
    if (status !== "stale") await rpc("limited_kick");
    return { run: runId, step: st.step, status, rows: r?.rows ?? 0, at: Math.round(cp.bit / 8 / total * 100) + "%", pack };
  } catch (e) {
    await rpc("limited_run_fail", { p_run: runId, p_error: String(e) }).catch(() => {});
    throw e;
  }
}

async function sha256(bytes: Uint8Array<ArrayBuffer>) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function buildPack(set: string) {
  const pack = await rpc<LimitedPack | null>("limited_pack_facts", { p_set: set });
  if (!pack) return null;
  const jobs: Promise<void>[] = [];
  for (const [event, ev] of Object.entries(pack.events)) {
    for (const [grp, view] of Object.entries(ev.groups)) {
      if (!view) continue;
      const f: Facts = limitedFacts(pack, event, grp as "all" | "top", view);
      jobs.push(briefFor(f, rpc).then((b) => { view.brief = b; }));
    }
  }
  await Promise.all(jobs);
  const stable = JSON.stringify(pack);
  const version = "l-" + (await sha256(new TextEncoder().encode(stable))).slice(0, 12);
  const body = new TextEncoder().encode(JSON.stringify({ ...pack, built_at: new Date().toISOString() }));
  const path = `insights/limited/${set}.json`;
  const { error } = await admin.storage.from("catalog").upload(path, body, { contentType: "application/json", upsert: true, cacheControl: "300" });
  if (error) throw new Error(`upload ${path}: ${error.message}`);
  const released = pack.released ? Date.parse(pack.released) : 0;
  await rpc("insight_pack_publish", {
    p_kind: "limited", p_key: set, p_name: pack.name ?? set, p_ord: -Math.round(released / 86400000), p_version: version, p_path: path,
    p_bytes: body.length, p_sha256: await sha256(body), p_through: null,
  });
  return { set, version, bytes: body.length };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: req.headers.get("x-t1-secret") ?? "" });
  if (!ok) return json({ error: "Forbidden" }, 403);
  const body = await req.json().catch(() => ({})) as { step?: string; run?: number; set?: string };
  try {
    switch (body.step) {
      case "check": return json(await check());
      case "slice": return json(await slice(Number(body.run)));
      case "pack": return json(await buildPack(String(body.set ?? "").toUpperCase()));
      default: return json({ error: "Unknown step" }, 400);
    }
  } catch (e) {
    console.error("limited-sync", body.step, String(e));
    return json({ error: String(e) }, 500);
  }
});
