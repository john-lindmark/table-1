// moderate: judges the content queued in public.moderation_checks (contract/moderation-2026-10-18.md).
//   POST {}                x-t1-secret: <db secret>   kicked right after a check is queued, and every minute by
//                          t1-moderation-tick. Claims up to 20 checks at a time until none are left (~40 s at most).
//   POST {purge: "<path>"} Authorization: Bearer <moderator JWT>   deletes a removed profile photo whose removal
//                          was upheld (moderation_appeal_resolve returns its path).
//   POST {sign: [{bucket, path}]}   moderator JWT   10-minute links to photos under review.
//   POST {eval: [{kind, text}]}     x-t1-secret     verdicts for test cases (eval without a local key); writes nothing.
// Text goes to Claude as one anonymous numbered list per batch; each photo goes alone. A refusal or an API error
// sends the items to a person (review), never allow. A child-safety block on a photo moves the file out of the
// public bucket into the private moderation-quarantine bucket at once.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  allReview, imagePrompt, MODEL, mediaType, parseResults, type Result, SCHEMA, SYSTEM, textPrompt, type TextItem,
} from "./policy.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const BUDGET_MS = 40_000;

interface Claimed { id: number; kind: string; text: string | null; bucket: string | null; path: string | null }

/** One Messages request with structured output; `fallbacks: "default"` re-runs a safety decline on Anthropic's
 *  recommended model. Returns the parsed JSON, or null for a refusal. */
async function ask(client: Anthropic, content: Anthropic.Beta.BetaContentBlockParam[]): Promise<{ raw: unknown; model: string } | null> {
  const msg = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 4000,
    system: SYSTEM,
    output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
    messages: [{ role: "user", content }],
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
  } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
  if (msg.stop_reason === "refusal") return null;
  const text = msg.content.filter((b) => b.type === "text").map((b) => (b as Anthropic.Beta.BetaTextBlock).text).join("");
  try {
    return { raw: JSON.parse(text), model: msg.model };
  } catch {
    return { raw: null, model: msg.model };
  }
}

async function judgeText(client: Anthropic, items: TextItem[]): Promise<Result[]> {
  try {
    const r = await ask(client, [{ type: "text", text: textPrompt(items) }]);
    if (!r) return allReview(items, "The check declined to judge this", MODEL);
    return parseResults(r.raw, items, r.model);
  } catch (e) {
    console.error("moderate: text batch failed", e instanceof Anthropic.APIError ? `${e.status} ${e.message}` : e);
    return allReview(items, "The check failed; a person will look", MODEL);
  }
}

async function judgeImage(client: Anthropic, c: Claimed): Promise<Result> {
  const { data, error } = await admin.storage.from(c.bucket!).download(c.path!);
  if (error || !data) {
    // Gone already (replaced or deleted): nothing left to show anyone.
    return { id: c.id, verdict: "allow", category: "none", reason: "The photo is no longer there", model: "none" };
  }
  const bytes = new Uint8Array(await data.arrayBuffer());
  const type = mediaType(bytes);
  if (!type) return allReview([c], "Not an image the check can read", MODEL)[0];
  try {
    const r = await ask(client, [
      { type: "image", source: { type: "base64", media_type: type, data: base64(bytes) } },
      { type: "text", text: imagePrompt(c.kind) },
    ]);
    if (!r) return allReview([c], "The check declined to judge this", MODEL)[0];
    return parseResults(r.raw, [c], r.model)[0];
  } catch (e) {
    console.error("moderate: image failed", e instanceof Anthropic.APIError ? `${e.status} ${e.message}` : e);
    return allReview([c], "The check failed; a person will look", MODEL)[0];
  }
}

function base64(b: Uint8Array): string {
  let s = "";
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}

/** Child safety: copy into the private quarantine bucket (kept for the legal report) and remove the public file. */
async function quarantine(c: Claimed) {
  const { data } = await admin.storage.from(c.bucket!).download(c.path!);
  if (data) {
    await admin.storage.from("moderation-quarantine").upload(`${c.bucket}/${c.path}`, data, { contentType: "image/jpeg", upsert: true });
  }
  await admin.storage.from(c.bucket!).remove([c.path!]);
}

async function run(): Promise<{ checked: number }> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set");
  const client = new Anthropic({ apiKey, maxRetries: 2, timeout: 30_000 });
  const started = Date.now();
  let checked = 0;
  while (Date.now() - started < BUDGET_MS) {
    const { data, error } = await admin.rpc("moderation_claim", { p_limit: 20 });
    if (error) throw error;
    const claimed = (data ?? []) as Claimed[];
    if (!claimed.length) break;
    const texts = claimed.filter((c) => c.path == null && c.text).map((c) => ({ id: c.id, kind: c.kind, text: c.text! }));
    const images = claimed.filter((c) => c.path != null && c.bucket);
    const results: Result[] = [];
    if (texts.length) results.push(...await judgeText(client, texts));
    for (const c of images) {
      const r = await judgeImage(client, c);
      if (r.verdict === "block" && r.category === "child_safety") await quarantine(c);
      results.push(r);
    }
    const { error: recErr } = await admin.rpc("moderation_record", { p_results: results });
    if (recErr) throw recErr;
    checked += results.length;
  }
  return { checked };
}

/** Classifier check against testdata/moderation/cases.json without a local API key: the database posts the cases
 *  (with its secret) and reads the verdicts back from pg_net's response. Writes nothing. */
async function evaluate(cases: TextItem[]): Promise<{ results: Result[] }> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set");
  const client = new Anthropic({ apiKey, maxRetries: 2, timeout: 60_000 });
  const items = cases.slice(0, 200).map((c, id) => ({ id, kind: String(c.kind), text: String(c.text) }));
  const results: Result[] = [];
  for (let i = 0; i < items.length; i += 20) results.push(...await judgeText(client, items.slice(i, i + 20)));
  return { results };
}

/** A moderator deletes a removed profile photo after upholding it. */
async function purge(req: Request, path: string) {
  if (!await isModerator(req)) return json({ error: "Moderators only" }, 403);
  if (!/^[0-9a-f-]{36}\/[A-Za-z0-9-]{1,64}\.jpg$/.test(path)) return json({ error: "Not a profile photo path" }, 400);
  const { data: inUse } = await admin.from("profiles").select("id").eq("avatar_url", path).maybeSingle();
  if (inUse) return json({ error: "That photo is in use" }, 409);
  const { error } = await admin.storage.from("avatars").remove([path]);
  if (error) return json({ error: error.message }, 500);
  return json({ purged: path });
}

/** Short-lived links to photos under review, for moderators (deck photos are private; a child-safety photo is only in
 *  quarantine). Keyed by path. */
async function sign(req: Request, items: { bucket?: string; path?: string }[]) {
  if (!await isModerator(req)) return json({ error: "Moderators only" }, 403);
  const urls: Record<string, string> = {};
  for (const it of items.slice(0, 100)) {
    if (!it.path || !["avatars", "deck-photos"].includes(it.bucket ?? "")) continue;
    let r = await admin.storage.from(it.bucket!).createSignedUrl(it.path, 600);
    if (r.error) r = await admin.storage.from("moderation-quarantine").createSignedUrl(`${it.bucket}/${it.path}`, 600);
    if (r.data?.signedUrl) urls[it.path] = r.data.signedUrl;
  }
  return json({ urls });
}

async function isModerator(req: Request): Promise<boolean> {
  const auth = req.headers.get("Authorization") ?? "";
  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data } = await asCaller.rpc("moderation_me");
  return (data as { moderator?: boolean } | null)?.moderator === true;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const body = await req.json().catch(() => ({})) as { purge?: string; sign?: { bucket?: string; path?: string }[] };
  if (typeof body.purge === "string") return purge(req, body.purge);
  if (Array.isArray(body.sign)) return sign(req, body.sign);
  const s = req.headers.get("x-t1-secret") ?? "";
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: s });
  if (ok !== true) return json({ error: "forbidden" }, 403);
  try {
    if (Array.isArray((body as { eval?: unknown }).eval)) return json(await evaluate((body as { eval: TextItem[] }).eval));
    return json(await run());
  } catch (e) {
    console.error("moderate:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
