// sets-sync: copies Scryfall's set list into public.mtg_sets so event create can offer draftable sets.
// Called daily by pg_cron (t1_private.sync_sets) with the shared x-t1-secret header.
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

interface ScryfallSet {
  code: string;
  name: string;
  set_type: string;
  released_at?: string;
  icon_svg_uri?: string;
  card_count?: number;
  digital?: boolean;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const secret = req.headers.get("x-t1-secret") ?? "";
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: secret });
  if (!ok) return json({ error: "Forbidden" }, 403);

  // Scryfall asks for a descriptive User-Agent and an Accept header on every request.
  const res = await fetch("https://api.scryfall.com/sets", {
    headers: { "User-Agent": "Table1Events/1.0 (table-1.site)", Accept: "application/json" },
  });
  if (!res.ok) return json({ error: `Scryfall ${res.status}` }, 502);
  const body = await res.json() as { data?: ScryfallSet[] };
  const rows = (body.data ?? [])
    .filter((s) => /^[a-z0-9]{2,6}$/.test(s.code))
    .map((s) => ({
      code: s.code,
      name: s.name.slice(0, 120),
      set_type: s.set_type,
      released_at: s.released_at ?? null,
      icon_svg_uri: s.icon_svg_uri ?? null,
      card_count: s.card_count ?? null,
      digital: !!s.digital,
      updated_at: new Date().toISOString(),
    }));
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await admin.from("mtg_sets").upsert(rows.slice(i, i + 500), { onConflict: "code" });
    if (error) return json({ error: error.message }, 500);
  }
  return json({ synced: rows.length });
});
