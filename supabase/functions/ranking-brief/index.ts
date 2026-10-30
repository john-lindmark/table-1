// ranking-brief: a 2-4 sentence comparison of two cube rankings for one list (contract/cube-rankings-2026-10-21.md
// § Brief), written by Claude and cached per pair, list and inputs.
//   POST { a: ranking id, b: ranking id, list: "W" | "U" | "B" | "R" | "G" | "M" | "C" | "L" | "F" }
//   Authorization: Bearer <user JWT>
//   → { brief: string, cached: boolean, model }   or   { brief: null, reason }   (not enough placed in common yet)
//   POST { eval: { cube: [card names], list, depth?, top?, a: { by, order: [names] }, b: { by, order }, model? } }
//   x-t1-secret: <db secret>   plays both rankings from those orders and returns the brief with the prompt's size
//   and token use; reads card data only, writes nothing (trying the prompt without a local API key).
// Both rankings are read with the caller's own token (cube_ranking_get), so a brief only ever covers rankings the
// caller can see; the cache is looked up after that. A new brief counts against DAILY_LIMIT per account per day.
// Secrets: ANTHROPIC_API_KEY.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { cleanBrief, GENDERED, inputHash, MIN_COMPARED, MODEL, named, problems, prompt, SCHEMA, simulateLog, SYSTEM, type CardFact, type RankingIn } from "./brief.ts";
import { COLOR_JOBS, type RankDepth, type RankJob } from "./cubeRanking.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const DAILY_LIMIT = 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

interface Detail {
  id: string; list_id: string | null; set_key?: string | null; name: string; depth: RankDepth; top: number; rev: number; mine: boolean;
  by: { display_name?: string } | null; log: RankingIn["log"]; cube: { name: string; cards?: string[] } | null; baseline?: string[];
}

/** A ranking as the brief reads it: the cube's cards it hasn't caught up with yet wait outside its lists. */
const toIn = (d: Detail): RankingIn => {
  const seen = new Set((d.baseline ?? []).map((c) => c.toLowerCase()));
  const fresh = d.baseline ? (d.cube?.cards ?? []).filter((c) => !seen.has(c.toLowerCase())) : [];
  return { id: d.id, rev: d.rev, depth: d.depth, top: d.top, name: d.name, by: d.by?.display_name?.trim() || "Someone", log: d.log ?? [], fresh };
};

/** The paragraph; one that genders a player, runs long or calls a utility land fixing is sent back once to be rewritten
 *  (problems()). Null for a refusal, an unusable answer, or a rewrite that still genders. */
async function write(text: string, utility: string[], model = MODEL): Promise<{ brief: string | null; model: string; usage: unknown; refused: boolean; rewritten: boolean }> {
  const first = await ask(text, model);
  const fix = first.brief ? problems(first.brief, utility) : null;
  if (first.refused || !first.brief || !fix) return { ...first, rewritten: false };
  const again = await ask(text, model, first.brief, fix);
  return { ...again, brief: again.brief && !GENDERED.test(again.brief) ? again.brief : null, rewritten: true };
}

/** One Messages request for the paragraph, or for `previous` rewritten as `rewrite` asks. */
async function ask(text: string, model: string, previous?: string, rewrite?: string): Promise<{ brief: string | null; model: string; usage: unknown; refused: boolean }> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set");
  const client = new Anthropic({ apiKey, maxRetries: 2, timeout: 60_000 });
  // Haiku has no server-side refusal fallback; a refusal reads as "couldn't be written" to the caller.
  const msg = await client.beta.messages.create({
    model,
    max_tokens: 4000,
    system: SYSTEM,
    output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
    messages: [
      { role: "user", content: text },
      ...(previous ? [{ role: "assistant", content: JSON.stringify({ brief: previous }) }, { role: "user", content: rewrite! }] : []),
    ],
  } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
  if (msg.stop_reason === "refusal") return { brief: null, model: msg.model, usage: msg.usage, refused: true };
  const out = msg.content.filter((c) => c.type === "text").map((c) => (c as Anthropic.Beta.BetaTextBlock).text).join("");
  let parsed: unknown = null;
  try { parsed = JSON.parse(out); } catch { /* unusable */ }
  return { brief: cleanBrief(parsed), model: msg.model, usage: msg.usage, refused: false };
}

interface EvalSide { by: string; order: string[] }

/** Eval only: another model to compare against MODEL. */
const EVAL_MODELS = ["claude-haiku-5-5", "claude-sonnet-5-5"];

/** Eval: names → cards, both rankings played from the given orders, the brief written; nothing stored. */
async function evaluate(e: { cube: string[]; list?: string; depth?: RankDepth; top?: number; a: EvalSide; b: EvalSide; model?: string }) {
  const { data, error } = await admin.from("card_oracles")
    .select("oracle_id, name, type_line, mana_cost, cmc, colors, produced_mana").in("name", e.cube);
  if (error) throw error;
  const byName = new Map<string, CardFact>();
  for (const f of data as CardFact[]) if (!byName.has(f.name)) byName.set(f.name, f);
  const missing = e.cube.filter((n) => !byName.has(n));
  const facts = [...byName.values()];
  const ids = (names: string[]) => names.map((n) => byName.get(n)?.oracle_id).filter((x): x is string => !!x);
  const depth = e.depth ?? "half", top = e.top ?? 50, list = (e.list ?? "F") as RankJob;
  const side = (s: EvalSide, id: string): RankingIn =>
    ({ id, rev: 1, depth, top, name: `${s.by}'s ranking`, by: s.by, log: simulateLog(facts, id, depth, top, ids(s.order)) });
  const a = side(e.a, crypto.randomUUID()), b = side(e.b, crypto.randomUUID());
  const { text, compared, utility } = prompt(facts, a, b, list, "Eval cube");
  const w = compared >= MIN_COMPARED ? await write(text, utility, EVAL_MODELS.includes(e.model ?? "") ? e.model : MODEL) : null;
  return { list, cards: facts.length, missing, compared, screens: [a.log.length, b.log.length], prompt_chars: text.length + SYSTEM.length,
           brief: w?.brief ? named(w.brief, a.by, b.by) : null, words: w?.brief?.split(/\s+/).length ?? 0, rewritten: w?.rewritten ?? false,
           model: w?.model ?? null, usage: w?.usage ?? null, refused: w?.refused ?? false };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const secret = req.headers.get("x-t1-secret");
  if (secret) {
    const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: secret });
    if (!ok) return json({ error: "Not allowed" }, 403);
    const body = await req.json().catch(() => ({}));
    if (!body.eval) return json({ error: "eval only" }, 400);
    try { return json(await evaluate(body.eval)); } catch (e) { return json({ error: String((e as Error)?.message ?? e) }, 500); }
  }
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Sign in to compare rankings" }, 401);
  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: userData, error: userError } = await asCaller.auth.getUser(auth.slice(7));
  if (userError || !userData.user) return json({ error: "Sign in to compare rankings" }, 401);

  const body = await req.json().catch(() => ({}));
  const a = String(body.a ?? "").toLowerCase(), b = String(body.b ?? "").toLowerCase();
  const list = String(body.list ?? "F") as RankJob;
  if (!UUID.test(a) || !UUID.test(b) || a === b) return json({ error: "Pick two different rankings" }, 400);
  if (list !== "F" && !COLOR_JOBS.includes(list)) return json({ error: "Unknown list" }, 400);

  // As the caller: a ranking they can't see reads "That's private".
  const [ra, rb] = await Promise.all([a, b].map((id) => asCaller.rpc("cube_ranking_get", { p_id: id })));
  if (ra.error || rb.error) return json({ error: (ra.error ?? rb.error)!.message }, (ra.error ?? rb.error)!.code === "42501" ? 403 : 400);
  const da = ra.data as Detail, db = rb.data as Detail;
  // A cube's by its list, a Limited set's by its key (contract/cube-rankings-2026-10-21.md § Sets).
  if ((da.list_id ?? `set:${da.set_key}`) !== (db.list_id ?? `set:${db.set_key}`)) return json({ error: "Those rankings are of different cubes" }, 400);

  const cardIds = [...new Set((da.cube?.cards ?? db.cube?.cards ?? [...da.log, ...db.log].flatMap((s) => s.o)).map((c) => c.toLowerCase()))];
  const ia = toIn(da), ib = toIn(db);
  const hash = await inputHash(ia, ib, list, cardIds);
  const hit = await admin.from("ranking_briefs").select("brief, model").eq("a", a).eq("b", b).eq("list", list).eq("input_hash", hash).maybeSingle();
  if (hit.data) return json({ brief: hit.data.brief, cached: true, model: hit.data.model });

  const facts: CardFact[] = [];
  for (let i = 0; i < cardIds.length; i += 300) {
    const { data, error } = await admin.from("card_oracles")
      .select("oracle_id, name, type_line, mana_cost, cmc, colors, produced_mana").in("oracle_id", cardIds.slice(i, i + 300));
    if (error) return json({ error: error.message }, 500);
    facts.push(...(data as CardFact[]));
  }
  const { text, compared, utility } = prompt(facts, ia, ib, list, da.cube?.name ?? db.cube?.name ?? "this cube");
  if (compared < MIN_COMPARED) return json({ brief: null, reason: "Not enough cards placed by both yet to describe the difference." });

  if (!Deno.env.get("ANTHROPIC_API_KEY")) return json({ error: "Briefs aren't set up yet" }, 503);
  const since = new Date(Date.now() - 86_400_000).toISOString();
  const { count } = await admin.from("ranking_briefs").select("a", { count: "exact", head: true })
    .eq("created_by", userData.user.id).gte("created_at", since);
  if ((count ?? 0) >= DAILY_LIMIT) return json({ error: `That's today's ${DAILY_LIMIT} new briefs. The ones already written still show.` }, 429);

  let brief: string | null = null, model = MODEL;
  try {
    const w = await write(text, utility);
    if (w.refused) return json({ brief: null, reason: "A brief couldn't be written for these rankings." });
    brief = w.brief && named(w.brief, ia.by, ib.by);
    model = w.model;
  } catch (e) {
    console.error("ranking-brief", e instanceof Anthropic.APIError ? `${e.status} ${e.message}` : e);
    return json({ error: "The brief couldn't be written just now. Try again." }, 502);
  }
  if (!brief) return json({ error: "The brief came back empty. Try again." }, 502);
  await admin.from("ranking_briefs").upsert({ a, b, list, input_hash: hash, brief, model, created_by: userData.user.id });
  return json({ brief, cached: false, model });
});
