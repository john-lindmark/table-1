// insight-brief: tries the Insights brief prompt on a facts sheet without writing anything (prompt work without
// a local API key, like ranking-brief's eval). The briefs themselves are written by meta-sync and limited-sync
// through brief.ts.
//   POST { eval: { title, lines: [string], thin? } }   x-t1-secret: <db secret>
//   → { brief, rewritten, model, problems }
import { createClient } from "npm:@supabase/supabase-js@2";
import { problems, write, type Facts } from "./brief.ts";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: req.headers.get("x-t1-secret") ?? "" });
  if (!ok) return json({ error: "Forbidden" }, 403);
  const body = await req.json().catch(() => ({}));
  const e = body.eval as Partial<Facts> | undefined;
  if (!e?.lines?.length) return json({ error: "eval needs lines" }, 400);
  const f: Facts = { view: "eval", title: String(e.title ?? "Eval"), lines: e.lines.map(String), thin: !!e.thin };
  try {
    const w = await write(f);
    return json({ ...w, problems: w.brief ? problems(w.brief, f) : null });
  } catch (err) {
    return json({ error: String((err as Error)?.message ?? err) }, 500);
  }
});
