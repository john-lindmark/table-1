// Builds constructed packs from the demo database (demo_db.sh) the way meta-sync does, minus briefs, which come
// from <briefs.json> ({ view: text }) when given; writes testdata/insights/constructed-<format>.json, the archetype and
// card pages the demos open (testdata/insights/pages.json), and each view's facts sheet to <facts.json> when given.
//   deno run --allow-run --allow-read --allow-write tools/insights/demo_packs.ts <through yyyy-mm-dd> [briefs.json] [facts.json]
import { limitedFacts, type LimitedPack } from "../../supabase/functions/limited-sync/pack.ts";
import { archetypeFacts, assemble, banFacts, windowFacts } from "../../supabase/functions/meta-sync/pack.ts";
import { type Base, type BanStudy, type Matchups, type NewSet, type Series, type Tier, type View, type Window, WINDOWS } from "../../supabase/functions/meta-sync/types.ts";

const [through, briefsPath, factsPath] = Deno.args;
const briefs: Record<string, string> = briefsPath ? JSON.parse(await Deno.readTextFile(briefsPath)) : {};
const PSQL = "/opt/homebrew/opt/postgresql@17/bin/psql";
async function sql<T>(q: string): Promise<T> {
  // the read RPCs answer the service role (meta-sync's briefs) as well as signed-in viewers
  const out = await new Deno.Command(PSQL, { args: ["-h", "/var/tmp/t1pg", "-p", "54329", "-U", "postgres", "-X", "-At", "-d", "t1_insights_demo",
    "-c", "select set_config('request.jwt.claim.role', 'service_role', false)", "-c", q] }).output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  return JSON.parse(new TextDecoder().decode(out.stdout).trim().split("\n").slice(1).join("\n"));
}
const lit = (s: string) => `'${s.replace(/'/g, "''")}'`;
const facts: Record<string, string[]> = {};
const pages: Record<string, unknown> = {};
for (const format of ["standard", "pioneer", "modern", "pauper"]) {
  const base = await sql<Base>(`select public.meta_pack_base(${lit(format)}, ${lit(through)})`);
  const tiers = {} as Record<Tier, View>;
  for (const tier of ["big", "all"] as Tier[]) {
    const windows: Record<string, Window> = {};
    for (const d of WINDOWS) {
      windows[d] = {
        ...await sql<Window>(`select public.meta_pack_window(${lit(format)}, ${lit(tier)}, ${d}, ${lit(through)})`),
        matchups: await sql<Matchups>(`select public.meta_pack_matchups(${lit(format)}, ${lit(through)}, ${lit(tier)}, ${d})`),
      };
    }
    tiers[tier] = {
      windows,
      series: await sql<Series>(`select public.meta_pack_series(${lit(format)}, ${lit(tier)}, 180, ${lit(through)})`),
      new_set: await sql<NewSet | null>(`select coalesce(public.meta_pack_new_set(${lit(format)}, ${lit(tier)}, ${lit(through)}), 'null'::jsonb)`),
    };
  }
  const bans = await sql<BanStudy[]>(`select public.meta_pack_bans(${lit(format)}, ${lit(through)})`);
  const matchups = await sql<Matchups>(`select public.meta_pack_matchups(${lit(format)}, ${lit(through)})`);
  const pack = assemble(base, tiers, bans, matchups, `${through}T06:00:00.000Z`);
  for (const tier of ["big", "all"] as Tier[]) {
    for (const d of WINDOWS) {
      const w = pack.tiers[tier].windows[d];
      const f = windowFacts(pack, tier, d, w);
      facts[f.view] = f.lines;
      w.brief = briefs[f.view] ?? null;
    }
  }
  for (const b of pack.bans) { const f = banFacts(pack, b); if (f) { facts[f.view] = f.lines; b.brief = briefs[f.view] ?? null; } }
  const w30 = pack.tiers.all.windows["30"];
  for (const s of w30.share.filter((s) => s.a !== 0).slice(0, 8)) {
    const page = await sql<Parameters<typeof archetypeFacts>[1] & { brief: string | null }>(`select public.meta_archetype(${lit(format)}, ${s.a}, 'all', 30)`);
    const f = archetypeFacts(pack, page, s);
    facts[f.view] = f.lines;
    page.brief = briefs[f.view] ?? null;
    pages[`arch:${format}:${s.a}`] = page;
    pages["arch:any"] ??= page;
  }
  for (const c of [...w30.cards.main.up.slice(0, 6), ...w30.cards.main.down.slice(0, 3), ...(pack.tiers.all.new_set?.cards.slice(0, 4) ?? [])]) {
    pages[`card:${format}:${c.c}`] = await sql(`select public.meta_card(${lit(format)}, ${lit(c.c)}::uuid, 'all')`);
    pages["card:any"] ??= pages[`card:${format}:${c.c}`];
  }
  await Deno.writeTextFile(`testdata/insights/constructed-${format}.json`, JSON.stringify(pack));
  console.log(format, JSON.stringify(pack).length, "bytes");
}
for (const set of await sql<string[]>("select coalesce(jsonb_agg(distinct set_code), '[]') from t1_private.limited_runs where status = 'done'")) {
  const pack = await sql<LimitedPack | null>(`select public.limited_pack_facts(${lit(set)})`);
  if (!pack) continue;
  for (const [event, ev] of Object.entries(pack.events)) {
    for (const [grp, view] of Object.entries(ev.groups)) {
      if (!view) continue;
      const f = limitedFacts(pack, event, grp as "all" | "top", view);
      facts[f.view] = f.lines;
      view.brief = briefs[f.view] ?? null;
    }
  }
  await Deno.writeTextFile(`testdata/insights/limited-${set}.json`, JSON.stringify(pack));
  console.log(set, JSON.stringify(pack).length, "bytes");
}
await Deno.writeTextFile("testdata/insights/pages.json", JSON.stringify(pages));
if (factsPath) await Deno.writeTextFile(factsPath, JSON.stringify(facts, null, 1));
