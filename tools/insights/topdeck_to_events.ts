// Saved TopDeck.gg answers (POST /v2/tournaments, one file per format named <Format>.json) → meta_ingest events, one
// per line, through meta-sync's own parser. Used by demo_packs.sh.
//   deno run --allow-read --allow-write tools/insights/topdeck_to_events.ts <dir> <out.jsonl>
import { parseTournament, type TdTournament } from "../../supabase/functions/meta-sync/topdeck.ts";

const [dir, out] = Deno.args;
const lines: string[] = [];
for await (const e of Deno.readDir(dir)) {
  const m = /^(Standard|Pioneer|Modern|Pauper)\.json$/.exec(e.name);
  if (!m) continue;
  for (const t of JSON.parse(await Deno.readTextFile(`${dir}/${e.name}`)) as TdTournament[]) {
    const ev = parseTournament(t, m[1].toLowerCase());
    if (ev) lines.push(JSON.stringify(ev));
  }
}
await Deno.writeTextFile(out, lines.join("\n") + (lines.length ? "\n" : ""));
console.log(lines.length, "TopDeck events");
