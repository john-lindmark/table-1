// deck-finder: finds a recent tournament decklist from a plain-language request (contract/deck-finder-2026-10-15.md).
// Two ways in:
//   POST { job_id }   x-t1-secret: <db secret>   from the database (deck_finder_start → pg_net, and the sweep): the
//        function claims the job, answers 202 at once and finds the deck in the background (EdgeRuntime.waitUntil),
//        then ends the job with deck_finder_finish, which pushes `deck.found` to the player. This is how the apps
//        search since 2026-11-01: the phone can be locked, the search goes on.
//   POST { query, format?, answers? }   Authorization: Bearer <user JWT>   the old synchronous way (builds before
//        2026-11-01): the response streams spaces while the agent works, then the JSON answer.
// The agent (agent.ts) reads Table 1's own results first (deck_finder_events / deck_finder_deck: MTGO, Melee and
// TopDeck within the hour), then the web. Card names come back as printed; the client resolves them against its
// catalog. Secrets: ANTHROPIC_API_KEY. Each account gets 20 searches per UTC day (deck_finder_take / deck_finder_start).
// Deployed with verify_jwt off: the database's posts carry no JWT, and the Bearer path checks the user itself.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { FORMATS, find, prompt, shape, withTable1Deck, type Answer, type OnSteps, type Table1Runner } from "./agent.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const DAILY_LIMIT = 20;
const DEADLINE_MS = 140_000; // under the edge function wall clock
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Rec = Record<string, unknown>;

/** The table1_* tools against the database. */
const table1: Table1Runner = async (name, input) => {
  if (name === "table1_events") {
    const { data, error } = await admin.rpc("deck_finder_events", {
      p_format: String(input.format ?? ""), p_days: Number(input.days) || 30,
      p_archetype: typeof input.archetype === "string" && input.archetype.trim() ? input.archetype.trim() : null,
      p_limit: Number(input.limit) || 12,
    });
    if (error) throw new Error(error.message);
    return data;
  }
  if (name === "table1_decklist") {
    const { data, error } = await admin.rpc("deck_finder_deck", { p_deck_id: Math.round(Number(input.deck_id) || 0) });
    if (error) throw new Error(error.message);
    return data ?? { error: "No deck with that deck_id" };
  }
  throw new Error(`Unknown tool ${name}`);
};

/** One search: the agent with a deadline, the report checked against Table 1's list when it names one. */
async function search(apiKey: string, query: string, format: string | null, answers: Answer[], onSteps?: OnSteps): Promise<Rec> {
  const client = new Anthropic({ apiKey });
  const abort = new AbortController();
  const deadline = setTimeout(() => abort.abort(), DEADLINE_MS);
  try {
    const report = await find(client, prompt(query, format, answers), abort.signal, table1, onSteps);
    const deckId = Math.round(Number(((report.deck ?? {}) as Rec).table1_deck_id) || 0);
    let db: Rec | null = null;
    if (report.status === "deck" && deckId > 0) {
      const { data } = await admin.rpc("deck_finder_deck", { p_deck_id: deckId });
      db = (data as Rec | null) ?? null;
    }
    return shape(withTable1Deck(report, db));
  } catch (e) {
    console.error("deck-finder", e);
    return abort.signal.aborted
      ? { status: "not_found", message: "That took too long. Try naming the archetype and format." }
      : { status: "error", message: "The deck finder couldn't search just now. Try again." };
  } finally {
    clearTimeout(deadline);
  }
}

function cleanAnswers(v: unknown): Answer[] {
  return (Array.isArray(v) ? v : [])
    .slice(0, 5)
    .map((a: { question?: unknown; answer?: unknown }) => ({ question: String(a?.question ?? "").slice(0, 300), answer: String(a?.answer ?? "").slice(0, 300) }))
    .filter((a: Answer) => a.question && a.answer);
}

let secretOk: string | null = null;
async function internal(req: Request) {
  const s = req.headers.get("x-t1-secret") ?? "";
  if (!s) return false;
  if (secretOk === s) return true;
  const { data } = await admin.rpc("live_push_secret_ok", { p_secret: s });
  if (data === true) secretOk = s;
  return data === true;
}

/** A job from the database: claim it, answer, and work on in the background. */
async function job(req: Request, apiKey: string | undefined) {
  if (!(await internal(req))) return json({ error: "Forbidden" }, 403);
  const body = await req.json().catch(() => ({}));
  const id = String(body.job_id ?? "");
  if (!UUID.test(id)) return json({ error: "job_id" }, 400);
  const { data: claimed, error } = await admin.rpc("deck_finder_claim", { p_id: id });
  if (error) return json({ error: error.message }, 500);
  if (!claimed) return json({ ok: true, claimed: false });
  const j = claimed as { query: string; format: string | null; answers: unknown };
  // The screen shows the work as it happens: each turn's steps go on the job (a failed write is just missed).
  const onSteps: OnSteps = async (steps) => {
    const { error: e } = await admin.rpc("deck_finder_progress", { p_id: id, p_steps: steps });
    if (e) console.error("deck-finder progress", e.message);
  };
  const work = (async () => {
    const out = apiKey
      ? await search(apiKey, String(j.query ?? ""), j.format && FORMATS.includes(j.format) ? j.format : null, cleanAnswers(j.answers), onSteps)
      : { status: "error", message: "The deck finder isn't set up yet" };
    const { error: finishError } = await admin.rpc("deck_finder_finish", { p_id: id, p_result: out });
    if (finishError) console.error("deck-finder finish", finishError.message);
  })().catch((e) => console.error("deck-finder job", e));
  // deno-lint-ignore no-explicit-any
  const runtime = (globalThis as any).EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(work);
  else await work;
  return json({ ok: true, claimed: true }, 202);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (req.headers.get("x-t1-secret")) return job(req, apiKey);

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Sign in to find decks" }, 401);
  if (!apiKey) return json({ error: "The deck finder isn't set up yet" }, 503);

  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: userData, error: userError } = await asCaller.auth.getUser(auth.slice(7));
  if (userError || !userData.user) return json({ error: "Sign in to find decks" }, 401);

  const body = await req.json().catch(() => ({}));
  const query = typeof body.query === "string" ? body.query.trim().slice(0, 500) : "";
  if (query.length < 3) return json({ error: "Describe the deck you're looking for" }, 400);
  const format = typeof body.format === "string" && FORMATS.includes(body.format.toLowerCase()) ? body.format.toLowerCase() : null;
  const answers = cleanAnswers(body.answers);

  const { data: allowed, error: limitError } = await admin.rpc("deck_finder_take", { p_user: userData.user.id, p_limit: DAILY_LIMIT });
  if (limitError) return json({ error: limitError.message }, 500);
  if (!allowed) return json({ error: `That's today's ${DAILY_LIMIT} searches. Try again tomorrow.` }, 429);

  const enc = new TextEncoder();
  const body$ = new ReadableStream<Uint8Array>({
    async start(ctl) {
      const beat = setInterval(() => ctl.enqueue(enc.encode(" ")), 10_000);
      let out: unknown;
      try {
        out = await search(apiKey, query, format, answers);
      } finally {
        clearInterval(beat);
      }
      ctl.enqueue(enc.encode(JSON.stringify(out)));
      ctl.close();
    },
  });
  return new Response(body$, { headers: { ...cors, "Content-Type": "application/json" } });
});
