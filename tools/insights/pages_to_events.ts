// Saved MTGO event data (one <slug>.json per page, the page's window.MTGO.decklists.data) → one meta_ingest event
// per line, through meta-sync's own parser. Used by demo_packs.sh.
//   deno run --allow-read --allow-write tools/insights/pages_to_events.ts <pages dir> <out.jsonl>
import { parseEvent } from "../../supabase/functions/meta-sync/mtgo.ts";

const [dir, out] = Deno.args;
const lines: string[] = [];
for await (const e of Deno.readDir(dir)) {
  if (!e.name.endsWith(".json")) continue;
  const slug = e.name.slice(0, -5);
  const ev = parseEvent(slug, JSON.parse(await Deno.readTextFile(`${dir}/${e.name}`)));
  if (ev) lines.push(JSON.stringify(ev));
}
lines.sort();
await Deno.writeTextFile(out, lines.join("\n") + "\n");
console.log(lines.length, "events");
