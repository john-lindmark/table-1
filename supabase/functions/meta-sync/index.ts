// meta-sync: Insights' constructed side (contract/insights-2026-10-24.md). Driven by pg_cron through pg_net with the
// shared x-t1-secret header:
//   {step:"tick"}             every 5 min: read this month's MTGO index hourly (and one older month per tick while
//                             the 12-month backfill runs, then months whose index came back empty), then read queued event pages, ~1 a second, for ~100 s
//                             and, while TopDeck's year of history isn't read yet, up to 40 s of it in 30-day
//                             windows (Canadian Highlander, which has no MTGO results, first); hourly, list the
//                             Melee files of fbettega/MTG_decklistcache (cache.ts) and queue the new and changed ones,
//                             read in the same queue as MTGO's pages
//   {step:"build", format}    every 6 h per format: TopDeck's last 3 days (when a TopDeck key is set), then the
//                             pack: facts from the database, briefs, uploaded to catalog/insights/constructed/
//   {step:"cluster"}          nightly: group the decks no rule names, ask Claude to name new groups, store them as
//                             proposals for Review ({format, days} to run one format over a longer span)
// The formats, their names, TopDeck names and minimum sizes come from t1_private.meta_formats (meta_formats_enabled).
// Secrets: ANTHROPIC_API_KEY (briefs, names); the TopDeck.gg key from the TOPDECK.GG_KEY function secret (or
// TOPDECK_API_KEY, or t1_private.settings topdeck_api_key via meta_topdeck_key); without one, TopDeck is skipped.
// GITHUB_TOKEN (optional, any token: public reads only) lifts GitHub's 60 calls an hour per address for the cache list.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { briefFor } from "../insight-brief/brief.ts";
import { clusters, known, NAME_SCHEMA, NAME_SYSTEM, namePrompt, proposal, type ClusterDeck } from "./cluster.ts";
import { backfillAfter, backfillMonth, bounced, indexSlugs, monthBefore, MTGO_FORMATS, pageData, parseEvent, slugInfo } from "./mtgo.ts";
import { archetypeFacts, assemble, banFacts, windowFacts } from "./pack.ts";
import { callTimeout, fetchRetrying } from "./deadline.ts";
import { CACHE_YEARS_URL, cacheItems, cacheTreeUrl, cacheYears, parseCacheEvent, type CacheFile } from "./cache.ts";
import { nextTopdeckWindow, parseTournament, tournamentsQuery, type TdTournament } from "./topdeck.ts";
import { type Base, type BanStudy, type Matchups, type NewSet, type Series, type Tier, type View, type Window, WINDOWS } from "./types.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const UA = "Table1Insights/1.0 (table-1.site; metagame stats)";
const BACKFILL_MONTHS = 12;
const TICK_MS = 100_000;
// No call in a tick runs past this, so the edge's 150 s wall clock never cuts one off and the closing write runs (bug #16).
const TICK_HARD_MS = 130_000;
const BUCKET = "catalog";

async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function get(url: string, timeoutMs = 60_000, deadline = Infinity): Promise<string> {
  const res = await fetch(url, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(callTimeout(deadline, timeoutMs)) });
  if (!res.ok) throw new Error(`${url} ${res.status}`);
  if (bounced(url, res)) { await res.body?.cancel(); throw new Error(`${url} sent to ${res.url}`); }   // failed: read again
  return await res.text();
}

interface Format { format: string; name: string; ord: number; topdeck: string; topdeck_min: number }
let formatsCache: Format[] | null = null;
const formats = async () => formatsCache ??= await rpc<Format[]>("meta_formats_enabled");

const month = (d: Date) => `${d.getUTCFullYear()}/${String(d.getUTCMonth() + 1).padStart(2, "0")}`;

/** Queues a month index's event pages (formats the server reads; Leagues included). `slugs` counts every event page
 *  on the index, read or not: 0 means MTGO sent the page without its list. */
async function readIndex(m: string, deadline = Infinity): Promise<{ slugs: number; queued: number }> {
  const html = await get(`https://www.mtgo.com/decklists/${m}`, 90_000, deadline);
  const slugs = indexSlugs(html);
  const items = slugs.filter((s) => slugInfo(s)).map((s) => ({
    source: "mtgo", format: slugInfo(s)!.format, slug: s, url: `https://www.mtgo.com/decklist/${s}`,
  }));
  return { slugs: slugs.length, queued: items.length ? await rpc<number>("meta_queue_add", { p_items: items }) : 0 };
}

/** A GitHub API answer (the cache's file lists). */
async function ghGet<T>(url: string, deadline = Infinity): Promise<T> {
  const token = Deno.env.get("GITHUB_TOKEN");
  const res = await fetch(url, {
    headers: { "User-Agent": UA, Accept: "application/vnd.github+json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    signal: AbortSignal.timeout(callTimeout(deadline, 30_000)),
  });
  if (!res.ok) throw new Error(`GitHub ${res.status} for ${url}: ${(await res.text()).slice(0, 200)}`);
  return await res.json() as T;
}

/** Queues the cache's Melee files of the past year from the year folders that changed since the last listing
 *  (a contents call, then one tree per changed year). A failed listing is tried again next tick. */
async function cacheDiscover(state: Record<string, string>, deadline = Infinity) {
  const years = cacheYears(await ghGet<{ path: string; name: string; type: string; sha: string }[]>(CACHE_YEARS_URL, deadline), state, Date.now(),
                           BACKFILL_MONTHS * 365 / 12);
  let queued = 0;
  for (const y of years) {
    const tree = await ghGet<{ tree: { path: string; type: string; sha: string }[]; truncated: boolean }>(cacheTreeUrl(y.sha), deadline);
    if (tree.truncated) throw new Error(`cache tree ${y.year} truncated`);
    const items = cacheItems(y.year, tree.tree, Date.now(), BACKFILL_MONTHS * 365 / 12);
    for (let i = 0; i < items.length; i += 500) queued += await rpc<number>("meta_queue_add", { p_items: items.slice(i, i + 500) });
    await rpc("meta_state_put", { p_patch: { [`cache_melee_${y.year}`]: y.sha } });
  }
  await rpc("meta_state_put", { p_patch: { cache_at: new Date().toISOString() } });
  return { years: years.map((y) => y.year), queued };
}

/** One queued page or file, read and ingested; null when it holds nothing to keep (the reason). */
async function readQueued(q: { source: string; slug: string; url: string }, deadline: number): Promise<{ decks: number } | string> {
  if (q.source === "melee") {
    const id = q.slug.replace(/@[0-9a-f]+$/, "").split("/").pop()!.replace(/\.json$/, "");
    const ev = parseCacheEvent(id, JSON.parse(await get(q.url, 60_000, deadline)) as CacheFile, await formats());
    return ev ? await rpc<{ decks: number }>("meta_ingest", { p_event: ev }) : "not a format read, under the paper minimum, or no public lists";
  }
  const data = pageData(await get(q.url, 60_000, deadline));
  const ev = data && parseEvent(q.slug, data);
  return ev ? await rpc<{ decks: number }>("meta_ingest", { p_event: ev }) : "no decklists on the page";
}

async function tick() {
  const t0 = Date.now();
  const hard = t0 + TICK_HARD_MS;
  const state = await rpc<Record<string, string>>("meta_state");
  if (state.tick_until && Date.parse(state.tick_until) > t0) return { skipped: "another tick is running" };
  await rpc("meta_state_put", { p_patch: { tick_until: new Date(t0 + TICK_MS + 30_000).toISOString() } });
  const out = { queued: 0, read: 0, decks: 0, failed: 0, backfill: null as string | null, topdeck: null as unknown, cache: null as unknown };
  try {
    const now = new Date();
    const hourly = !state.index_at || t0 - Date.parse(state.index_at) > 3_600_000;
    if (hourly) {
      const cur = await readIndex(month(now), hard);
      out.queued += cur.queued;
      if (now.getUTCDate() <= 3) out.queued += (await readIndex(monthBefore(month(now)), hard)).queued;
      // An empty list is read again next tick (the first days of a month may truly have none: then hourly as before).
      if (cur.slugs > 0 || now.getUTCDate() <= 2) await rpc("meta_state_put", { p_patch: { index_at: now.toISOString() } });
    }
    // Backfill: one older month per tick, back BACKFILL_MONTHS from the first tick, then months that came back empty.
    const until = state.backfill_until ?? (() => {
      let m = month(now);
      for (let i = 0; i < BACKFILL_MONTHS; i++) m = monthBefore(m);
      return m;
    })();
    const b = { next: state.backfill_next ?? monthBefore(month(now)), until, retry: state.backfill_retry ?? "" };
    const m = backfillMonth(b, hourly);
    if (m) {
      const r = await readIndex(m, hard);
      out.queued += r.queued;
      out.backfill = `${m}: ${r.slugs} pages`;
      const after = backfillAfter(b, m, r.slugs);
      await rpc("meta_state_put", { p_patch: { backfill_until: after.until, backfill_next: after.next, backfill_retry: after.retry } });
    }
    out.topdeck = await topdeckBackfill(t0 + 40_000, state, hard);
    if (!state.cache_at || t0 - Date.parse(state.cache_at) > 3_600_000) {
      out.cache = await cacheDiscover(state, hard).catch((e) => { console.error("meta-sync cache", String(e)); return { error: String(e) }; });
    }
    while (Date.now() - t0 < TICK_MS) {
      const batch = await rpc<{ id: number; source: string; slug: string; url: string }[]>("meta_queue_claim", { p_n: 5 });
      if (!batch.length) break;
      for (const q of batch) {
        try {
          const r = await readQueued(q, hard);
          if (typeof r === "string") { await rpc("meta_queue_done", { p_id: q.id, p_status: "skipped", p_error: r }); continue; }
          out.read++; out.decks += r.decks;
          await rpc("meta_queue_done", { p_id: q.id, p_status: "done" });
        } catch (e) {
          out.failed++;
          await rpc("meta_queue_done", { p_id: q.id, p_status: "failed", p_error: String(e) }).catch(() => {});
        }
        await sleep(1000);
        if (Date.now() - t0 >= TICK_MS) break;
      }
    }
  } finally {
    await rpc("meta_state_put", { p_patch: { tick_until: new Date(0).toISOString() } }).catch(() => {});
  }
  return out;
}

const topdeckKey = async () => Deno.env.get("TOPDECK.GG_KEY") ?? Deno.env.get("TOPDECK_API_KEY") ?? await rpc<string | null>("meta_topdeck_key");

/** One tournaments query. TopDeck rate-limits bursts (429; the four builds start at once): back off and try again,
 *  as long as the wait and the call still end before `deadline`. */
async function topdeckFetch(key: string, body: unknown, deadline = Infinity): Promise<TdTournament[]> {
  const res = await fetchRetrying("https://topdeck.gg/api/v2/tournaments", {
    method: "POST", headers: { Authorization: key, "Content-Type": "application/json", "User-Agent": UA },
    body: JSON.stringify(body),
  }, { deadline, cap: 60_000, waits: [0, 5_000, 15_000, 30_000] });
  if (!res.ok) throw new Error(`TopDeck ${res.status}`);
  return await res.json() as TdTournament[];
}

async function ingestTopdeck(list: TdTournament[], format: string) {
  let events = 0, decks = 0;
  for (const t of list) {
    const ev = parseTournament(t, format);
    if (!ev) continue;
    const r = await rpc<{ decks: number }>("meta_ingest", { p_event: ev });
    events++; decks += r.decks;
  }
  return { events, decks };
}

/** The builds' TopDeck read: the last 3 days of a format's events. */
async function topdeck(f: Format) {
  const key = await topdeckKey();
  if (!key) return { skipped: "no TopDeck key" };
  return await ingestTopdeck(await topdeckFetch(key, tournamentsQuery(f.topdeck, 3, f.topdeck_min)), f.format);
}

/** Reads TopDeck's history a window at a time until `until` (or it's all read), moving each format's cursor. */
async function topdeckBackfill(until: number, state: Record<string, string>, deadline = Infinity) {
  const key = await topdeckKey();
  if (!key) return null;
  const fs = await formats();
  const cursors = { ...state };
  const done: { format: string; from: string; events: number; decks: number }[] = [];
  while (Date.now() < until) {
    const w = nextTopdeckWindow(fs.map((f) => ({ format: f.format, topdeckOnly: !MTGO_FORMATS.includes(f.format) })), cursors, Date.now(),
                                BACKFILL_MONTHS * 365 / 12);
    if (!w) break;
    const f = fs.find((x) => x.format === w.format)!;
    try {
      const r = await ingestTopdeck(await topdeckFetch(key, tournamentsQuery(f.topdeck, { start: w.start, end: w.end }, f.topdeck_min), deadline), f.format);
      const from = new Date(w.start * 1000).toISOString();
      cursors[`td_back_${f.format}`] = from;
      await rpc("meta_state_put", { p_patch: { [`td_back_${f.format}`]: from } });
      done.push({ format: f.format, from: from.slice(0, 10), ...r });
    } catch (e) {
      console.error("meta-sync topdeck backfill", f.format, String(e));
      return { done, error: String(e) };
    }
  }
  return { done };
}

/** Runs fns with at most n in flight. */
async function pool<T>(fns: (() => Promise<T>)[], n = 6): Promise<T[]> {
  const out: T[] = new Array(fns.length);
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, fns.length) }, async () => {
    while (i < fns.length) { const k = i++; out[k] = await fns[k](); }
  }));
  return out;
}

async function sha256(bytes: Uint8Array<ArrayBuffer>) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...d].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function build(format: string) {
  const f = (await formats()).find((x) => x.format === format);
  if (!f) throw new Error(`unknown format ${format}`);
  const td = await topdeck(f).catch((e) => ({ error: String(e) }));
  await rpc("meta_relabel", { p_format: format, p_other_only: true });
  const through = new Date().toISOString().slice(0, 10);
  const base = await rpc<Base>("meta_pack_base", { p_format: format, p_through: through });
  if (!base) throw new Error(`unknown format ${format}`);
  const tiers = {} as Record<Tier, View>;
  for (const tier of ["big", "all"] as Tier[]) {
    const windows: Record<string, Window> = {};
    for (const days of WINDOWS) {
      windows[days] = await rpc<Window>("meta_pack_window", { p_format: format, p_tier: tier, p_days: days, p_through: through });
    }
    tiers[tier] = {
      windows,
      series: await rpc<Series>("meta_pack_series", { p_format: format, p_tier: tier, p_days: 180, p_through: through }),
      new_set: await rpc<NewSet | null>("meta_pack_new_set", { p_format: format, p_tier: tier, p_through: through }),
    };
  }
  const bans = await rpc<BanStudy[]>("meta_pack_bans", { p_format: format, p_through: through });
  const matchups = await rpc<Matchups>("meta_pack_matchups", { p_format: format, p_through: through });
  const pack = assemble(base, tiers, bans, matchups, new Date().toISOString());

  // Briefs: every tier × window, every ban study, the top 8 archetypes (All events, 30 days).
  const jobs: (() => Promise<void>)[] = [];
  for (const tier of ["big", "all"] as Tier[]) {
    for (const days of WINDOWS) {
      const w = pack.tiers[tier].windows[days];
      jobs.push(async () => { w.brief = w.decks ? await briefFor(windowFacts(pack, tier, days, w), rpc) : null; });
    }
  }
  for (const b of pack.bans) {
    jobs.push(async () => { const f = banFacts(pack, b); b.brief = f ? await briefFor(f, rpc) : null; });
  }
  const shares = pack.tiers.all.windows["30"].share;
  for (const s of shares.filter((s) => s.a !== 0).slice(0, 8)) {
    jobs.push(async () => {
      const a = await rpc<Parameters<typeof archetypeFacts>[1]>("meta_archetype", { p_format: format, p_archetype: s.a, p_tier: "all", p_days: 30 });
      await briefFor(archetypeFacts(pack, a, s), rpc);
    });
  }
  await pool(jobs, 6);

  const { built_at: _b, ...stable } = pack;
  const version = "c-" + (await sha256(new TextEncoder().encode(JSON.stringify(stable)))).slice(0, 12);
  const current = await rpc<string | null>("insight_pack_current", { p_kind: "constructed", p_key: format });
  if (current === version) return { format, version, unchanged: true, topdeck: td };
  const body = new TextEncoder().encode(JSON.stringify(pack));
  const path = `insights/constructed/${format}.json`;
  const { error } = await admin.storage.from(BUCKET).upload(path, body, { contentType: "application/json", upsert: true, cacheControl: "300" });
  if (error) throw new Error(`upload ${path}: ${error.message}`);
  await rpc("insight_pack_publish", {
    p_kind: "constructed", p_key: format, p_name: base.name, p_ord: f.ord, p_version: version, p_path: path,
    p_bytes: body.length, p_sha256: await sha256(body), p_through: through,
  });
  return { format, version, bytes: body.length, topdeck: td };
}

async function nameCluster(text: string): Promise<unknown> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set");
  const client = new Anthropic({ apiKey, maxRetries: 2, timeout: 60_000 });
  const msg = await client.beta.messages.create({
    model: "claude-haiku-5-5", max_tokens: 1000, system: NAME_SYSTEM,
    output_config: { effort: "low", format: { type: "json_schema", schema: NAME_SCHEMA } },
    messages: [{ role: "user", content: text }],
  } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
  const out = msg.content.filter((c) => c.type === "text").map((c) => (c as Anthropic.Beta.BetaTextBlock).text).join("");
  try { return JSON.parse(out); } catch { return null; }
}

async function cluster(only?: string, days = 45) {
  const out: Record<string, number> = {};
  for (const { format, name } of (await formats()).filter((f) => !only || f.format === only)) {
    const input = await rpc<{ total: number; decks: { id: number; colors: string; cards: string[] }[]; names: Record<string, string>;
                              known: { name: string; status: string; signature: string[] }[] }>("meta_cluster_input", { p_format: format, p_days: days });
    const decks: ClusterDeck[] = input.decks.map((d) => ({ id: d.id, colors: d.colors, cards: d.cards.map((c) => input.names[c] ?? c) }));
    const fresh = clusters(decks, input.total).filter((c) => c.share >= 0.01 && !known(c, input.known.map((k) => k.signature)));
    let added = 0;
    for (const c of fresh.slice(0, 5)) {
      const p = proposal(c, await nameCluster(namePrompt(name, c)).catch(() => null));
      if (!p) continue;
      const id = await rpc<number | null>("meta_archetype_propose", {
        p_format: format, p_name: p.name, p_family: p.family, p_colors: c.colors, p_rule: p.rule, p_signature: c.signature, p_decks: c.size,
      });
      if (id) added++;
    }
    out[format] = added;
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: req.headers.get("x-t1-secret") ?? "" });
  if (!ok) return json({ error: "Forbidden" }, 403);
  const body = await req.json().catch(() => ({})) as { step?: string; format?: string; days?: number };
  try {
    switch (body.step) {
      case "tick": return json(await tick());
      case "build": return json(await build(String(body.format ?? "")));
      case "cluster": return json(await cluster(body.format, Math.min(Math.max(Number(body.days) || 45, 7), 365)));
      default: return json({ error: "Unknown step" }, 400);
    }
  } catch (e) {
    console.error("meta-sync", body.step, String(e));
    return json({ error: String(e) }, 500);
  }
});
