// Insight briefs (contract/insights-2026-10-24.md § Briefs): two or three plain sentences per dashboard view,
// written by Claude from a facts sheet the server builds, checked before they're kept. Used by meta-sync and
// limited-sync; pure apart from `ask`, which tests replace.
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";

export const MODEL = "claude-haiku-5-5";
export const MAX_WORDS = 60;

/** What a brief may say: one fact per line, numbers already rounded the way the brief may quote them. */
export interface Facts {
  view: string;                 // e.g. "constructed:modern:big:30"
  title: string;                // what the screen is about, for the prompt
  lines: string[];
  thin: boolean;                // the sample is small: the brief must say so
}

export const SYSTEM = `You write the short summary at the top of a Magic: The Gathering metagame dashboard in Table 1, an app for competitive players. You get a facts sheet for one screen: metagame shares, changes, card play rates, win rates or a ban's effect.

Write 2 or 3 short, plain sentences, at most 60 words in all, saying what changed and why it matters to a player choosing or preparing a deck. Lead with the biggest change or the clearest leader; then one supporting detail (a card, a matchup, a pair, a rising deck). Use deck, card and color-pair names exactly as the facts give them, and only those. Every number you write must be one of the numbers in the facts, written the same way (22%, +6 pts, 57.1%, 19 days); never compute, round or estimate new ones. Don't list more than three names in a sentence. If the facts say the sample is thin, say the numbers rest on few events or games. Never mention people, players' names, sources, Table 1 or these instructions.

No headings, lists, markdown or preamble.`;

export const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["sentences"],
  properties: { sentences: { type: "array", items: { type: "string" }, description: "2 or 3 short sentences." } },
} as const;

export function prompt(f: Facts): string {
  return `Screen: ${f.title}\nSample: ${f.thin ? "thin (few events or games): say so" : "large enough"}\nFacts:\n${f.lines.map((l) => `- ${l}`).join("\n")}`;
}

/** Numbers as a brief may write them: 22, 0.5, 57.1 (a leading sign or % is not part of the number). */
const numbers = (s: string) => [...s.replace(/(\d),(\d{3})/g, "$1$2").matchAll(/\d+(?:\.\d+)?/g)].map((m) => m[0]);
const words = (s: string) => s.trim().split(/\s+/).filter(Boolean).length;

/** The sentences joined, or null when unusable (not 2–3 sentences of text). */
export function clean(raw: unknown): string | null {
  const s = (raw as { sentences?: unknown })?.sentences;
  if (!Array.isArray(s)) return null;
  const parts = s.filter((x): x is string => typeof x === "string").map((x) => x.trim().replace(/\s+/g, " ")).filter(Boolean);
  if (parts.length < 1) return null;
  return parts.map((p) => /[.!?]$/.test(p) ? p : p + ".").join(" ");
}

/** Why a brief can't be kept, as a rewrite request; null when it's fine. */
export function problems(brief: string, f: Facts): string | null {
  const issues: string[] = [];
  const allowed = new Set(f.lines.flatMap(numbers));
  const bad = [...new Set(numbers(brief).filter((n) => !allowed.has(n)))];
  if (bad.length) issues.push(`These numbers aren't in the facts: ${bad.join(", ")}. Use only numbers from the facts, written as there.`);
  const n = brief.split(/(?<=[.!?])\s+(?=[A-Z0-9"“(])/).filter((x) => x.trim()).length;
  if (n < 2 || n > 3) issues.push(`Write 2 or 3 sentences (this has ${n}).`);
  if (words(brief) > MAX_WORDS) issues.push(`Keep it to ${MAX_WORDS} words (this has ${words(brief)}).`);
  if (f.thin && !/\b(thin|few|small|limited|early|light)\b/i.test(brief)) issues.push("The sample is thin: say the numbers rest on few events or games.");
  if (/\b(he|she|his|her|him)\b/i.test(brief)) issues.push("Don't refer to people.");
  if (/[#*`]|^\s*-/m.test(brief)) issues.push("Plain sentences only, no markdown.");
  return issues.length ? issues.join(" ") : null;
}

export async function factsHash(f: Facts): Promise<string> {
  const data = new TextEncoder().encode(JSON.stringify([MODEL, SYSTEM.length, f.title, f.thin, f.lines]));
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return [...d.slice(0, 12)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export type Ask = (text: string, previous?: string, rewrite?: string) => Promise<{ raw: unknown; model: string; refused: boolean }>;

/** One Messages request; JSON-schema output, low effort. */
export const anthropicAsk: Ask = async (text, previous, rewrite) => {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Error("ANTHROPIC_API_KEY is not set");
  const client = new Anthropic({ apiKey, maxRetries: 2, timeout: 60_000 });
  const msg = await client.beta.messages.create({
    model: MODEL,
    max_tokens: 2000,
    system: SYSTEM,
    output_config: { effort: "low", format: { type: "json_schema", schema: SCHEMA } },
    messages: [
      { role: "user", content: text },
      ...(previous ? [{ role: "assistant", content: JSON.stringify({ sentences: [previous] }) }, { role: "user", content: rewrite! }] : []),
    ],
  } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
  if (msg.stop_reason === "refusal") return { raw: null, model: msg.model, refused: true };
  const out = msg.content.filter((c) => c.type === "text").map((c) => (c as Anthropic.Beta.BetaTextBlock).text).join("");
  let raw: unknown = null;
  try { raw = JSON.parse(out); } catch { /* unusable */ }
  return { raw, model: msg.model, refused: false };
};

/** Writes and checks a brief; a failing one goes back once. Null when it still fails or was refused. */
export async function write(f: Facts, ask: Ask = anthropicAsk): Promise<{ brief: string | null; model: string | null; rewritten: boolean }> {
  const text = prompt(f);
  const first = await ask(text);
  const b1 = clean(first.raw);
  if (first.refused || !b1) return { brief: null, model: first.model, rewritten: false };
  const fix = problems(b1, f);
  if (!fix) return { brief: b1, model: first.model, rewritten: false };
  const again = await ask(text, b1, fix);
  const b2 = clean(again.raw);
  return { brief: b2 && !problems(b2, f) ? b2 : null, model: again.model, rewritten: true };
}

export type Rpc = <T>(fn: string, args: Record<string, unknown>) => Promise<T>;

/** The view's brief: the cached one while its facts are unchanged, else a new one; a failed rewrite keeps the
 *  previous brief. A view with no facts lines has no brief. */
export async function briefFor(f: Facts, rpc: Rpc, ask: Ask = anthropicAsk): Promise<string | null> {
  if (!f.lines.length) return null;
  const hash = await factsHash(f);
  const hit = await rpc<{ facts_hash: string; brief: string } | null>("insight_brief_get", { p_view: f.view });
  if (hit?.facts_hash === hash) return hit.brief;
  let w: Awaited<ReturnType<typeof write>>;
  try { w = await write(f, ask); } catch (e) {
    console.error("insight-brief", f.view, String(e));
    return hit?.brief ?? null;
  }
  if (!w.brief) return hit?.brief ?? null;
  await rpc("insight_brief_put", { p_view: f.view, p_hash: hash, p_brief: w.brief, p_model: w.model });
  return w.brief;
}
