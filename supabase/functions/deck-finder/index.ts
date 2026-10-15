// deck-finder: finds a recent tournament decklist from a plain-language request (contract/deck-finder-2026-10-15.md).
//   POST { query: string, format?: string, answers?: [{ question, answer }] }   Authorization: Bearer <user JWT>
// A Claude agent searches mtgdecks.net, melee.gg, mtggoldfish.com and magic.gg (MTGO decklists), preferring the
// most recent strong finishes at large events. It answers with one of:
//   { status: "deck", deck: { name, archetype, format, event, date, placement, player, source_url, notes, main, side } }
//   { status: "question", question, options }   the request was ambiguous; the client asks and sends `answers`
//   { status: "not_found", message }
// Card names come back as printed in the list; the client resolves them against its offline catalog.
// The stateless follow-up: the client resends the query plus every question and answer so far.
// While the agent works, the response streams spaces (valid leading JSON whitespace) so proxies don't time out.
// Secrets: ANTHROPIC_API_KEY. Each account gets DAILY_LIMIT searches per UTC day (deck_finder_take).
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

const DAILY_LIMIT = 20;
const DEADLINE_MS = 140_000; // under the edge function wall clock
const FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern"];

const SYSTEM = `You find Magic: The Gathering decklists for Table 1, an app for competitive players. A player describes the deck they want; you find one real, published decklist and report it with the report_result tool.

Where to look: mtgdecks.net, melee.gg, mtggoldfish.com, and magic.gg (official MTGO decklists: Challenges, Showcases, Qualifiers). Other reputable tournament sites are fine when those don't have it.

How to choose:
- Recency matters most. Prefer lists from the last 30 days, then the last 90. Formats change fast; a list from before the latest set release or ban update is usually wrong, especially for new archetypes. Never pick an old list when a recent one of the same archetype exists.
- Among recent lists, prefer strong finishes at large events: Pro Tour, Regional Championships, MagicCon and other large opens, MTGO Challenges and Showcases. A Top 8 at a big event beats a 5-0 league.
- The list must be legal in the requested format today.
- Copy the list exactly as published: every main deck and sideboard card with its count. Main decks are usually 60 cards (40 in Limited, 100 in Commander) and sideboards up to 15; if your counts don't add up, fetch the page again rather than guess.

When to ask instead: if the request could mean clearly different decks (no archetype named, "a good aggro deck", a name two archetypes share, or the format is unknown), call report_result with status "question": one short question and 2-5 concrete options, each an archetype name a player would recognise, ordered by how well it is doing now. Ask only when it changes which list you'd pick; if the player named an archetype and format, just find it. If earlier questions were answered, use the answers and don't ask the same thing again.

If nothing suitable exists, report status "not_found" with a one-sentence reason.

Finish by calling report_result exactly once. Keep searching to a handful of queries; fetch the decklist page itself before reporting.`;

const LINE = {
  type: "object",
  additionalProperties: false,
  required: ["qty", "name"],
  properties: { qty: { type: "integer" }, name: { type: "string", description: "Card name as printed in English" } },
};

const REPORT_TOOL = {
  name: "report_result",
  description: "Report the decklist you found, a clarifying question, or that nothing suitable exists. Call exactly once, at the end.",
  strict: true,
  input_schema: {
    type: "object",
    additionalProperties: false,
    required: ["status", "question", "options", "message", "deck"],
    properties: {
      status: { type: "string", enum: ["deck", "question", "not_found"] },
      question: { type: "string", description: "status question: the question to ask. Otherwise empty." },
      options: { type: "array", items: { type: "string" }, description: "status question: 2-5 answers. Otherwise empty." },
      message: { type: "string", description: "status not_found: why. Otherwise empty." },
      deck: {
        type: "object",
        additionalProperties: false,
        description: "status deck: the list. Otherwise fill with empty values.",
        required: ["name", "archetype", "format", "event", "date", "placement", "player", "source_url", "notes", "main", "side"],
        properties: {
          name: { type: "string", description: "Short deck name for the player's list, e.g. \"Boros Energy\"" },
          archetype: { type: "string" },
          format: { type: "string", description: `One of ${FORMATS.join(", ")}, or other` },
          event: { type: "string", description: "Event name, e.g. \"Modern Challenge 64\"" },
          date: { type: "string", description: "Event date, YYYY-MM-DD" },
          placement: { type: "string", description: "e.g. \"1st\", \"Top 8\", \"5-0\"" },
          player: { type: "string" },
          source_url: { type: "string", description: "The page the list was copied from" },
          notes: { type: "string", description: "One sentence: why this list (recency, finish), or caveats" },
          main: { type: "array", items: LINE },
          side: { type: "array", items: LINE },
        },
      },
    },
  },
};

const SERVER_TOOLS = [
  { type: "web_search_20260209", name: "web_search", max_uses: 6 },
  { type: "web_fetch_20260209", name: "web_fetch", max_uses: 6, max_content_tokens: 40_000 },
];

interface Answer { question: string; answer: string }

function prompt(query: string, format: string | null, answers: Answer[]): string {
  const today = new Date().toISOString().slice(0, 10);
  const lines = [`Today is ${today}.`, `Request: ${query}`];
  if (format) lines.push(`Deck format chosen in the app: ${format}.`);
  for (const a of answers) lines.push(`You asked: ${a.question}\nPlayer answered: ${a.answer}`);
  return lines.join("\n\n");
}

/** Runs the agent until it calls report_result; resumes server-tool pauses. */
async function find(client: Anthropic, userText: string, signal: AbortSignal): Promise<Record<string, unknown>> {
  const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: "user", content: userText }];
  for (let turn = 0; turn < 6; turn++) {
    // Opus 5.5 with web search/fetch; `fallbacks: "default"` re-runs a safety decline on Anthropic's recommended model.
    const stream = client.beta.messages.stream({
      model: "claude-opus-5-5",
      max_tokens: 32_000,
      system: SYSTEM,
      output_config: { effort: "medium" },
      tools: [...SERVER_TOOLS, REPORT_TOOL],
      tool_choice: { type: "auto" },
      messages,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    } as unknown as Anthropic.Beta.MessageCreateParamsStreaming, { signal });
    const msg = await stream.finalMessage();
    if (msg.stop_reason === "refusal") return { status: "not_found", message: "That request couldn't be searched." };
    const report = msg.content.find((b) => b.type === "tool_use" && b.name === "report_result") as
      | Anthropic.Beta.BetaToolUseBlock
      | undefined;
    if (report) return report.input as Record<string, unknown>;
    messages.push({ role: "assistant", content: msg.content });
    if (msg.stop_reason === "pause_turn") continue; // the server-side tool loop paused; resend to resume
    // Ended without reporting: remind once, the way the prompt asks.
    messages.push({ role: "user", content: "Call report_result now with what you found." });
  }
  return { status: "not_found", message: "The search didn't settle on a list. Try naming the archetype and format." };
}

/** Normalizes the tool input into the wire shape, dropping fields that don't belong to the status. */
function shape(r: Record<string, unknown>) {
  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  if (r.status === "question" && str(r.question)) {
    const options = Array.isArray(r.options) ? r.options.map(str).filter(Boolean).slice(0, 5) : [];
    return { status: "question", question: str(r.question), options };
  }
  const d = (r.deck ?? {}) as Record<string, unknown>;
  const lines = (v: unknown) =>
    (Array.isArray(v) ? v : [])
      .map((l) => ({ qty: Math.max(0, Math.min(999, Math.round(Number((l as { qty?: unknown }).qty) || 0))), name: str((l as { name?: unknown }).name) }))
      .filter((l) => l.qty > 0 && l.name);
  const main = lines(d.main);
  if (r.status === "deck" && main.length) {
    const format = str(d.format).toLowerCase();
    return {
      status: "deck",
      deck: {
        name: str(d.name) || str(d.archetype) || "Found deck",
        archetype: str(d.archetype),
        format: FORMATS.includes(format) ? format : "other",
        event: str(d.event), date: str(d.date), placement: str(d.placement), player: str(d.player),
        source_url: /^https?:\/\//.test(str(d.source_url)) ? str(d.source_url) : "",
        notes: str(d.notes),
        main,
        side: lines(d.side),
      },
    };
  }
  return { status: "not_found", message: str(r.message) || "No suitable list turned up." };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Sign in to find decks" }, 401);
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "The deck finder isn't set up yet" }, 503);

  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: userData, error: userError } = await asCaller.auth.getUser(auth.slice(7));
  if (userError || !userData.user) return json({ error: "Sign in to find decks" }, 401);

  const body = await req.json().catch(() => ({}));
  const query = typeof body.query === "string" ? body.query.trim().slice(0, 500) : "";
  if (query.length < 3) return json({ error: "Describe the deck you're looking for" }, 400);
  const format = typeof body.format === "string" && FORMATS.includes(body.format.toLowerCase()) ? body.format.toLowerCase() : null;
  const answers: Answer[] = (Array.isArray(body.answers) ? body.answers : [])
    .slice(0, 5)
    .map((a: { question?: unknown; answer?: unknown }) => ({ question: String(a?.question ?? "").slice(0, 300), answer: String(a?.answer ?? "").slice(0, 300) }))
    .filter((a: Answer) => a.question && a.answer);

  const { data: allowed, error: limitError } = await admin.rpc("deck_finder_take", { p_user: userData.user.id, p_limit: DAILY_LIMIT });
  if (limitError) return json({ error: limitError.message }, 500);
  if (!allowed) return json({ error: `That's today's ${DAILY_LIMIT} searches. Try again tomorrow.` }, 429);

  const client = new Anthropic({ apiKey });
  const enc = new TextEncoder();
  const body$ = new ReadableStream<Uint8Array>({
    async start(ctl) {
      const beat = setInterval(() => ctl.enqueue(enc.encode(" ")), 10_000);
      const abort = new AbortController();
      const deadline = setTimeout(() => abort.abort(), DEADLINE_MS);
      let out: unknown;
      try {
        out = shape(await find(client, prompt(query, format, answers), abort.signal));
      } catch (e) {
        console.error("deck-finder", e);
        out = abort.signal.aborted
          ? { status: "not_found", message: "That took too long. Try naming the archetype and format." }
          : { status: "error", message: "The deck finder couldn't search just now. Try again." };
      } finally {
        clearInterval(beat);
        clearTimeout(deadline);
      }
      ctl.enqueue(enc.encode(JSON.stringify(out)));
      ctl.close();
    },
  });
  return new Response(body$, { headers: { ...cors, "Content-Type": "application/json" } });
});
