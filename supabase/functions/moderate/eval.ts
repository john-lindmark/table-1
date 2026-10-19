// Runs testdata/moderation/cases.json against the live classifier and prints misses (costs a few cents).
//   cd supabase/functions && ANTHROPIC_API_KEY=... deno run --allow-env --allow-net --allow-read=../../testdata moderate/eval.ts
// A miss on an `allow` case is a false positive (the worst kind here: it would reset a player's name or unshare a deck).
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { MODEL, parseResults, SCHEMA, SYSTEM, textPrompt } from "./policy.ts";

const file = JSON.parse(await Deno.readTextFile(new URL("../../../testdata/moderation/cases.json", import.meta.url)));
const cases = (file.cases as { kind: string; text: string; expect: "allow" | "flag" | "block" }[])
  .map((c, id) => ({ ...c, id }));
const client = new Anthropic();

let misses = 0;
for (let i = 0; i < cases.length; i += 20) {
  const batch = cases.slice(i, i + 20);
  const msg = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 4000,
    system: SYSTEM,
    output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
    messages: [{ role: "user", content: textPrompt(batch) }],
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
  } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
  if (msg.stop_reason === "refusal") {
    console.log(`batch ${i / 20}: refused`);
    misses += batch.length;
    continue;
  }
  const text = msg.content.filter((b) => b.type === "text").map((b) => (b as Anthropic.Beta.BetaTextBlock).text).join("");
  const results = parseResults(JSON.parse(text), batch, msg.model);
  results.forEach((r, j) => {
    const c = batch[j];
    const ok = c.expect === "allow" ? r.verdict === "allow" : c.expect === "block" ? r.verdict === "block" : r.verdict !== "allow";
    if (!ok) misses++;
    console.log(`${ok ? "ok  " : "MISS"} ${c.expect.padEnd(5)} -> ${r.verdict.padEnd(6)} ${r.category.padEnd(13)} ${c.kind.padEnd(15)} ${c.text}${r.reason ? `  (${r.reason})` : ""}`);
  });
  console.log(`usage: ${msg.usage.input_tokens} in / ${msg.usage.output_tokens} out`);
}
console.log(`\n${cases.length - misses}/${cases.length} as expected`);
if (misses) Deno.exit(1);
