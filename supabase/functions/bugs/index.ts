// bugs: the bug pipeline's front door (contract/bug-pipeline-2026-10-18.md). Deployed with verify_jwt off: every
// caller proves itself another way.
//   Sentry webhooks          Sentry-Hook-Signature (the integration's client secret)   event_alert / issue → file + triage
//   POST {action: "triage"}  x-t1-secret: <db secret>   kicked by t1-bugs-tick when bugs wait for a severity
//   POST {action, …}         x-t1-runner: <runner secret>   the fix runner on John's Mac (tools/bugs/bugs.sh):
//        status | list {status?, limit?} | get {id} | next {max, runner} | done {id, outcome, …} | set {id, …}
//        | shipped {platform, version?, ids?} | file {report} | setup-sentry {secret}
// Severity: rules first (triage.ts), then Claude for the rest in one request per batch; a failed request falls back
// to rules, so nothing waits. The database applies the floors and pushes the watchers for each new S1.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { parse as parseSentry, verify } from "./sentry.ts";
import { type Bug, fallback, MODEL, parse, prompt, rule, SCHEMA, SYSTEM, type Verdict } from "./triage.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

async function judge(bugs: Bug[]): Promise<Verdict[]> {
  const out: Verdict[] = [];
  const ask: Bug[] = [];
  for (const b of bugs) {
    const r = rule(b);
    if (r) out.push(r); else ask.push(b);
  }
  if (!ask.length) return out;
  if (!Deno.env.get("ANTHROPIC_API_KEY")) return [...out, ...ask.map(fallback)];
  try {
    // The same request shape as `moderate` (live): structured output at low effort.
    const msg = await new Anthropic().beta.messages.create({
      model: MODEL,
      max_tokens: 4000,
      system: SYSTEM,
      output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
      messages: [{ role: "user", content: prompt(ask) }],
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
    if (msg.stop_reason === "refusal") return [...out, ...ask.map(fallback)];
    const text = msg.content.filter((b) => b.type === "text").map((b) => (b as Anthropic.Beta.BetaTextBlock).text).join("");
    let raw: unknown = null;
    try { raw = JSON.parse(text); } catch { /* falls back per bug */ }
    return [...out, ...parse(raw, ask)];
  } catch (e) {
    console.error("bugs: triage failed", e instanceof Anthropic.APIError ? `${e.status} ${e.message}` : e);
    return [...out, ...ask.map(fallback)];
  }
}

/** Rates every bug waiting for a severity, 20 at a time, for up to ~40 s. */
async function triage() {
  const t0 = Date.now();
  let rated = 0;
  while (Date.now() - t0 < 40_000) {
    const bugs = await rpc<Bug[]>("bug_triage_claim", { p_n: 20 });
    if (!bugs.length) break;
    const verdicts = await judge(bugs);
    rated += await rpc<number>("bug_triage_record", { p: verdicts });
    if (bugs.length < 20) break;
  }
  return { rated };
}

let sentrySecret: string | null = null;
async function sentry(req: Request) {
  const body = await req.text();
  sentrySecret ??= await rpc<string | null>("bug_setting", { p_name: "sentry_client_secret" });
  if (!sentrySecret || !(await verify(body, req.headers.get("sentry-hook-signature"), sentrySecret))) {
    sentrySecret = null;   // re-read next time, in case it was just set
    return json({ error: "Bad signature" }, 401);
  }
  const report = parseSentry(req.headers.get("sentry-hook-resource"), JSON.parse(body));
  if (!report) return json({ ok: true, filed: false });
  const r = await rpc<{ id: number; status: string } | null>("bug_report", { p: report });
  // Rate it now so an S1 reaches John in seconds, not at the next tick.
  if (r?.status === "new") await triage();
  return json({ ok: true, filed: !!r, id: r?.id ?? null });
}

const okCache = new Map<string, boolean>();
async function allowed(fn: "live_push_secret_ok" | "bug_runner_ok", secret: string | null) {
  if (!secret) return false;
  const key = `${fn}:${secret}`;
  if (okCache.get(key)) return true;
  const ok = (await rpc<boolean>(fn, { p_secret: secret })) === true;
  if (ok) okCache.set(key, true);
  return ok;
}

type Body = Record<string, unknown> & { action?: string };

async function runner(b: Body) {
  switch (b.action) {
    case "status": return rpc("bug_status");
    case "list": return rpc("bug_list", { p_status: b.status ?? null, p_limit: b.limit ?? 50 });
    case "get": return rpc("bug_get", { p_id: b.id });
    case "next": return rpc("bug_next", { p_max: b.max ?? "S4", p_runner: b.runner ?? "runner" });
    case "done": {
      const { id, action: _a, ...outcome } = b;
      return rpc("bug_done", { p_id: id, p: outcome });
    }
    case "set": {
      const { id, action: _a, ...changes } = b;
      return rpc("bug_set", { p_id: id, p: changes });
    }
    case "shipped": return rpc("bug_shipped", { p_platform: b.platform, p_version: b.version ?? null, p_ids: b.ids ?? null });
    case "file": {
      const r = await rpc<{ id: number; status: string } | null>("bug_report", { p: { source: "manual", ...(b.report as object) } });
      if (r?.status === "new") await triage();
      return r ? rpc("bug_get", { p_id: r.id }) : null;
    }
    case "setup-sentry": {
      if (typeof b.secret !== "string" || b.secret.length < 16) throw new Error("That doesn't look like a client secret");
      await rpc("bug_setting_set", { p_name: "sentry_client_secret", p_value: b.secret });
      sentrySecret = null;
      return { ok: true };
    }
    default: throw new Error(`Unknown action ${b.action}`);
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    if (req.headers.has("sentry-hook-resource")) return await sentry(req);
    const b = await req.json().catch(() => ({})) as Body;
    if (await allowed("bug_runner_ok", req.headers.get("x-t1-runner"))) return json(await runner(b));
    if (b.action === "triage" && await allowed("live_push_secret_ok", req.headers.get("x-t1-secret"))) return json(await triage());
    return json({ error: "Forbidden" }, 403);
  } catch (e) {
    console.error("bugs:", e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
