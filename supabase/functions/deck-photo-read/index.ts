// deck-photo-read: reads a decklist off a deck photo (contract/deck-photo-lists-2026-11-13.md).
//   POST { photo_id }      x-t1-secret: <db secret>   from the database (a new photo's trigger, deck_photo_read_start,
//        the sweep): claims the read, answers 202 at once and reads in the background (EdgeRuntime.waitUntil), then
//        ends it with deck_photo_read_finish, which keeps the list beside the photo and tells the player.
//   POST { eval: [photo_id, ...] }   x-t1-secret      reads up to 6 photos and answers with the lists; writes
//        nothing (measuring the reader on real photos without a local key).
// One Messages request per photo: a signed link to the photo as stored (2048 px on the long side, inside the model's
// 2576 px; a link because encoding the bytes here costs more CPU than an edge function has), the
// event's card pool as text (deck_photo_read_claim), a structured answer. Names the pool doesn't hold exactly are
// settled against the catalog (deck_photo_read_names). Secrets: ANTHROPIC_API_KEY. Deployed with verify_jwt off:
// the database's posts carry no JWT.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { ask, entries, indexPool, seen, stepDone, stepPool, toAsk, SCHEMA, STEP_LOOK, SYSTEM, type Entry, type EventInfo, type Named, type Pool } from "./read.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const MODEL = "claude-opus-5-5";
const DEADLINE_MS = 140_000; // under the edge function wall clock
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface Job { photo_id: string; path: string; event: EventInfo; pool: Pool }
interface Outcome { status: "done" | "failed"; cards?: Entry[]; notes?: string; model?: string; message?: string; pool?: { kind: string; label: string; size: number } }

/** The photo and the pool to the model; its structured answer, or null when it declined.
 *  `fallbacks: "default"` re-runs a safety decline on Anthropic's recommended model. */
async function look(client: Anthropic, photoUrl: string, job: Job, signal: AbortSignal): Promise<{ raw: unknown; model: string } | null> {
  const msg = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 16000,
    system: SYSTEM,
    output_config: { effort: "high", format: { type: "json_schema", schema: SCHEMA } },
    messages: [{
      role: "user",
      content: [
        { type: "image", source: { type: "url", url: photoUrl } },
        { type: "text", text: ask(job.event, job.pool) },
      ],
    }],
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
  } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming, { signal });
  if (msg.stop_reason === "refusal") return null;
  const text = msg.content.filter((b) => b.type === "text").map((b) => (b as Anthropic.Beta.BetaTextBlock).text).join("");
  try {
    return { raw: JSON.parse(text), model: msg.model };
  } catch {
    return { raw: null, model: msg.model };
  }
}

/** One read, start to finish. */
async function read(apiKey: string, job: Job, onSteps?: (steps: string[]) => Promise<void>): Promise<Outcome> {
  const abort = new AbortController();
  const deadline = setTimeout(() => abort.abort(), DEADLINE_MS);
  const pool = { kind: job.pool.kind, label: job.pool.label, size: job.pool.cards.length };
  try {
    const steps = [STEP_LOOK, stepPool(job.pool)];
    await onSteps?.(steps);
    // A signed link, not the bytes: encoding a 1-2 MB photo here runs the function out of CPU (546 on 2026-11-13).
    const { data, error } = await admin.storage.from("deck-photos").createSignedUrl(job.path, 900);
    if (error || !data?.signedUrl) return { status: "failed", message: "The photo is no longer there." };
    const answer = await look(new Anthropic({ apiKey }), data.signedUrl, job, abort.signal);
    if (!answer || !answer.raw) return { status: "failed", message: "The photo couldn't be read. Try a clearer photo, or add the cards by hand." };
    const s = seen(answer.raw);
    const ix = indexPool(job.pool);
    const names = toAsk(s.cards, ix);
    let named: Named[] = [];
    if (names.length) {
      const res = await admin.rpc("deck_photo_read_names", { p_names: names });
      if (res.error) console.error("deck-photo-read names", res.error.message);
      named = (res.data as Named[] | null) ?? [];
    }
    const list = entries(s.cards, ix, named);
    await onSteps?.([...steps, stepDone(list)]);
    return { status: "done", cards: list, notes: s.notes, model: answer.model, pool };
  } catch (e) {
    console.error("deck-photo-read", e instanceof Anthropic.APIError ? `${e.status} ${e.message}` : e);
    return { status: "failed", message: abort.signal.aborted ? "Reading the photo took too long. Try again." : "The photo couldn't be read just now. Try again." };
  } finally {
    clearTimeout(deadline);
  }
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

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!(await internal(req))) return json({ error: "Forbidden" }, 403);
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  const body = await req.json().catch(() => ({}));

  if (Array.isArray(body.eval)) {
    if (!apiKey) return json({ error: "No API key" }, 503);
    const ids = (body.eval as unknown[]).map(String).filter((s) => UUID.test(s)).slice(0, 6);
    const results = await Promise.all(ids.map(async (id) => {
      const t0 = Date.now();
      const { data } = await admin.rpc("deck_photo_read_peek", { p_photo_id: id });
      if (!data) return { photo_id: id, status: "failed", message: "No such photo" };
      return { photo_id: id, ...(await read(apiKey, data as Job)), ms: Date.now() - t0 };
    }));
    return json({ results });
  }

  const id = String(body.photo_id ?? "");
  if (!UUID.test(id)) return json({ error: "photo_id" }, 400);
  const { data: claimed, error } = await admin.rpc("deck_photo_read_claim", { p_photo_id: id });
  if (error) return json({ error: error.message }, 500);
  if (!claimed) return json({ ok: true, claimed: false });
  const work = (async () => {
    const out: Outcome = apiKey
      ? await read(apiKey, claimed as Job, async (steps) => {
        const { error: e } = await admin.rpc("deck_photo_read_progress", { p_photo_id: id, p_steps: steps });
        if (e) console.error("deck-photo-read progress", e.message);
      })
      : { status: "failed", message: "Reading decklists isn't set up yet." };
    const { error: finishError } = await admin.rpc("deck_photo_read_finish", { p_photo_id: id, p_result: out });
    if (finishError) console.error("deck-photo-read finish", finishError.message);
  })().catch((e) => console.error("deck-photo-read job", e));
  // deno-lint-ignore no-explicit-any
  const runtime = (globalThis as any).EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(work);
  else await work;
  return json({ ok: true, claimed: true }, 202);
});
