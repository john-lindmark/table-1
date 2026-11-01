// The deck-finder agent's fixed parts (contract/deck-finder-2026-10-15.md): the prompt, the tools, the loop that
// runs Claude until it reports, and the shaping of its report into the wire answer. Nothing here touches the
// network except through the client and the `table1` tool runner it's handed, so the pure parts are unit-tested.
import type Anthropic from "npm:@anthropic-ai/sdk@0.110.0";

export const FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "commander", "premodern", "canlander"];
/** Formats Table 1's own results cover (contract/insights-2026-10-24.md § Formats). */
export const TABLE1_FORMATS = ["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "canlander"];

export const SYSTEM = `You find Magic: The Gathering decklists for Table 1, an app for competitive players. A player describes the deck they want; you find one real, published decklist and report it with the report_result tool.

Where to look, in this order:
1. Table 1's own results (the table1_events and table1_decklist tools): every Magic Online Challenge, Showcase, Qualifier and League decklist, Melee.gg events (Regional Championships, Pro Tours, opens) and TopDeck.gg events, read within the hour of being published. Standard, Pioneer, Modern, Legacy, Vintage, Pauper and Canadian Highlander. These lists are exact and up to date, so start here for any of those formats: call table1_events for the format (an archetype name narrows it; try a shorter name or none if nothing matches), pick the deck, then call table1_decklist for its cards and report its deck_id as table1_deck_id.
2. The web (web_search and web_fetch): mtgdecks.net, melee.gg, mtggoldfish.com and magic.gg, or other reputable tournament sites. Use it when Table 1 has nothing that fits (Commander, Premodern, a paper event that isn't in, a specific player or event you can't find), or when the player asks for something the results don't say (a particular player's list).

How to choose:
- Recency matters most. Prefer lists from the last 7 days, then 30, then 90. Formats change fast; a list from before the latest set release or ban update is usually wrong, especially for new archetypes. Never pick an old list when a recent one of the same archetype exists.
- Among recent lists, prefer strong finishes at large events: Pro Tour, Regional Championships, MagicCon and other large opens, MTGO Challenges and Showcases. A Top 8 at a big event beats a 5-0 league.
- The list must be legal in the requested format today.
- Copy the list exactly as published: every main deck and sideboard card with its count. Main decks are usually 60 cards (40 in Limited, 100 in Commander) and sideboards up to 15; if your counts don't add up, fetch the page again rather than guess. A list from table1_decklist is already exact: report it as given.

When to ask instead: if the request could mean clearly different decks (no archetype named, "a good aggro deck", a name two archetypes share, or the format is unknown), call report_result with status "question": one short question and 2-5 concrete options, each an archetype name a player would recognise, ordered by how well it is doing now (table1_events shows what's winning). Ask only when it changes which list you'd pick; if the player named an archetype and format, just find it. If earlier questions were answered, use the answers and don't ask the same thing again.

If nothing suitable exists, report status "not_found" with a one-sentence reason.

Finish by calling report_result exactly once. Keep searching to a handful of calls.`;

const LINE = {
  type: "object",
  additionalProperties: false,
  required: ["qty", "name"],
  properties: { qty: { type: "integer" }, name: { type: "string", description: "Card name as printed in English" } },
};

export const REPORT_TOOL = {
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
        required: ["name", "archetype", "format", "event", "date", "placement", "player", "source_url", "notes", "table1_deck_id", "main", "side"],
        properties: {
          name: { type: "string", description: "Short deck name for the player's list, e.g. \"Boros Energy\"" },
          archetype: { type: "string" },
          format: { type: "string", description: `One of ${FORMATS.join(", ")}, or other` },
          event: { type: "string", description: "Event name, e.g. \"Modern Challenge 64\"" },
          date: { type: "string", description: "Event date, YYYY-MM-DD" },
          placement: { type: "string", description: "e.g. \"1st\", \"Top 8\", \"5-0\"" },
          player: { type: "string", description: "The player's name or handle when the source gives one, else empty" },
          source_url: { type: "string", description: "The page the list was copied from" },
          notes: { type: "string", description: "One sentence: why this list (recency, finish), or caveats" },
          table1_deck_id: { type: "integer", description: "The deck_id from table1_decklist when the list came from Table 1's results, else 0" },
          main: { type: "array", items: LINE },
          side: { type: "array", items: LINE },
        },
      },
    },
  },
};

export const SERVER_TOOLS = [
  { type: "web_search_20260209", name: "web_search", max_uses: 6 },
  { type: "web_fetch_20260209", name: "web_fetch", max_uses: 6, max_content_tokens: 40_000 },
];

/** Table 1's own results, run by the function against the database (deck_finder_events / deck_finder_deck). */
export const TABLE1_TOOLS = [
  {
    name: "table1_events",
    description: "Recent tournament events in Table 1's results for a format, newest first, each with its best-placed decks (archetype, colors, rank, record, deck_id). An archetype name narrows events and decks to those playing it (a substring match on Table 1's archetype names, e.g. \"Energy\"). Empty when the format isn't covered or nothing matches.",
    input_schema: {
      type: "object",
      additionalProperties: false,
      required: ["format"],
      properties: {
        format: { type: "string", enum: TABLE1_FORMATS },
        days: { type: "integer", description: "How far back: 7, 30 (default) or 90 days; up to 365", minimum: 1, maximum: 365 },
        archetype: { type: "string", description: "Part of an archetype name, or omit for every deck" },
        limit: { type: "integer", description: "Events to list, default 12, up to 30", minimum: 1, maximum: 30 },
      },
    },
  },
  {
    name: "table1_decklist",
    description: "One deck from table1_events, exactly as published: main and side with counts, the event, its date and page.",
    input_schema: {
      type: "object",
      additionalProperties: false,
      required: ["deck_id"],
      properties: { deck_id: { type: "integer" } },
    },
  },
];

export interface Answer { question: string; answer: string }

export function prompt(query: string, format: string | null, answers: Answer[], today = new Date()): string {
  const lines = [`Today is ${today.toISOString().slice(0, 10)}.`, `Request: ${query}`];
  if (format) lines.push(`Deck format chosen in the app: ${format}.`);
  for (const a of answers) lines.push(`You asked: ${a.question}\nPlayer answered: ${a.answer}`);
  return lines.join("\n\n");
}

/** A deck's finish in words, from Table 1's rank and record. */
export function placementOf(d: { rank?: unknown; top8?: unknown; wins?: unknown; losses?: unknown; draws?: unknown }): string {
  const rank = Math.round(Number(d.rank) || 0);
  if (rank >= 1) {
    const suffix = rank % 100 >= 11 && rank % 100 <= 13 ? "th" : ({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[rank % 10] ?? "th";
    return `${rank}${suffix}`;
  }
  if (d.top8 === true) return "Top 8";
  if (d.wins != null && d.losses != null) return `${d.wins}-${d.losses}${Number(d.draws) > 0 ? `-${d.draws}` : ""}`;
  return "";
}

type Rec = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
const lines = (v: unknown) =>
  (Array.isArray(v) ? v : [])
    .map((l) => ({ qty: Math.max(0, Math.min(999, Math.round(Number((l as { qty?: unknown }).qty) || 0))), name: str((l as { name?: unknown }).name) }))
    .filter((l) => l.qty > 0 && l.name);

/** A report that names a Table 1 deck takes that deck's exact list and event, whatever the model transcribed. */
export function withTable1Deck(report: Rec, db: Rec | null): Rec {
  if (!db) return report;
  const deck = { ...((report.deck ?? {}) as Rec) };
  const main = lines(db.main);
  if (!main.length) return report;
  deck.main = main;
  deck.side = lines(db.side);
  if (str(db.event)) deck.event = str(db.event);
  if (str(db.date)) deck.date = str(db.date);
  if (str(db.url)) deck.source_url = str(db.url);
  if (str(db.format)) deck.format = str(db.format);
  const placement = placementOf(db);
  if (placement) deck.placement = placement;
  if (!str(deck.archetype) && str(db.archetype)) deck.archetype = str(db.archetype);
  if (!str(deck.name)) deck.name = str(db.archetype);
  deck.table1_deck_id = Number(db.deck_id) || deck.table1_deck_id;
  return { ...report, status: "deck", deck };
}

/** Normalizes the tool input into the wire shape, dropping fields that don't belong to the status. */
export function shape(r: Rec) {
  if (r.status === "question" && str(r.question)) {
    const options = Array.isArray(r.options) ? r.options.map(str).filter(Boolean).slice(0, 5) : [];
    return { status: "question", question: str(r.question), options };
  }
  const d = (r.deck ?? {}) as Rec;
  const main = lines(d.main);
  if (r.status === "deck" && main.length) {
    const format = str(d.format).toLowerCase();
    const table1 = Math.max(0, Math.round(Number(d.table1_deck_id) || 0));
    return {
      status: "deck",
      deck: {
        name: str(d.name) || str(d.archetype) || "Found deck",
        archetype: str(d.archetype),
        format: FORMATS.includes(format) ? format : "other",
        event: str(d.event), date: str(d.date), placement: str(d.placement), player: str(d.player),
        source_url: /^https?:\/\//.test(str(d.source_url)) ? str(d.source_url) : "",
        notes: str(d.notes),
        from: table1 > 0 ? "table1" : "web",
        main,
        side: lines(d.side),
      },
    };
  }
  return { status: "not_found", message: str(r.message) || "No suitable list turned up." };
}

/** Runs one of the table1_* tools; the function binds this to the database. Returns the JSON text for the model. */
export type Table1Runner = (name: string, input: Rec) => Promise<unknown>;

/** Told the steps so far, each time there's a new one; the function writes them to the job for the screen. */
export type OnSteps = (steps: string[]) => Promise<void> | void;

const FORMAT_NAMES: Record<string, string> = {
  standard: "Standard", pioneer: "Pioneer", modern: "Modern", legacy: "Legacy", vintage: "Vintage", pauper: "Pauper",
  commander: "Commander", premodern: "Premodern", canlander: "Canadian Highlander",
};
const clip = (t: string, n: number) => (t.length > n ? `${t.slice(0, n - 1).trimEnd()}…` : t);

/**
 * What the agent is doing, in words, from one of its turns: its own short remarks, each web search and page it
 * reads, and each Table 1 lookup. Shown on the Find a deck screen while the search runs ("show the work").
 */
export function stepsOf(content: Array<Rec>): string[] {
  const out: string[] = [];
  for (const b of content) {
    const input = (b.input ?? {}) as Rec;
    if (b.type === "text" && typeof b.text === "string") {
      const text = b.text.replace(/\s+/g, " ").trim();
      if (text) out.push(clip(text, 160));
    } else if (b.type === "server_tool_use" && b.name === "web_search") {
      out.push(`Searching the web: ${clip(str(input.query), 100)}`);
    } else if (b.type === "server_tool_use" && b.name === "web_fetch") {
      let page = str(input.url);
      try { const u = new URL(page); page = `${u.host}${clip(u.pathname, 60)}`; } catch { page = clip(page, 80); }
      out.push(`Reading ${page}`);
    } else if (b.type === "tool_use" && b.name === "table1_events") {
      const archetype = str(input.archetype);
      const days = Number(input.days) || 30;
      out.push(`Checking Table 1's results: ${FORMAT_NAMES[str(input.format)] ?? str(input.format)}, last ${days} days${archetype ? `, "${clip(archetype, 40)}"` : ""}`);
    } else if (b.type === "tool_use" && b.name === "table1_decklist") {
      out.push(`Reading deck ${Math.round(Number(input.deck_id) || 0)} from Table 1's results`);
    }
  }
  return out;
}

/** What a Table 1 lookup found, in a line. */
export function stepOfResult(name: string, data: unknown): string | null {
  if (name === "table1_events") {
    const events = Array.isArray(data) ? data as Rec[] : [];
    if (!events.length) return "Nothing in Table 1's results for that";
    const decks = events.reduce((n, e) => n + (Array.isArray(e.decks) ? e.decks.length : 0), 0);
    const first = events[0];
    return `${events.length} event${events.length === 1 ? "" : "s"} with ${decks} deck${decks === 1 ? "" : "s"}, newest ${str(first.name)}${str(first.date) ? ` · ${str(first.date)}` : ""}`;
  }
  if (name === "table1_decklist") {
    const d = (data ?? {}) as Rec;
    if (!Array.isArray(d.main) || !d.main.length) return "No such deck in Table 1's results";
    const what = str(d.archetype) || "A deck";
    const place = placementOf(d);
    return `Read ${what}${place ? ` · ${place}` : ""}${str(d.event) ? ` at ${str(d.event)}` : ""}`;
  }
  return null;
}

/**
 * Runs the agent until it calls report_result: resumes server-tool pauses, answers table1_* calls, and reminds it
 * once if it stops without reporting. The report is the raw tool input (shape it after).
 */
export async function find(client: Anthropic, userText: string, signal: AbortSignal, table1: Table1Runner, onSteps?: OnSteps): Promise<Rec> {
  const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: "user", content: userText }];
  let reminded = false;
  const steps: string[] = [];
  const note = async (more: string[]) => {
    if (!more.length) return;
    steps.push(...more);
    try { await onSteps?.(steps.slice(-40)); } catch (e) { console.error("deck-finder steps", e); }
  };
  for (let turn = 0; turn < 14; turn++) {
    // Opus 5.5 with web search/fetch; `fallbacks: "default"` re-runs a safety decline on Anthropic's recommended model.
    const stream = client.beta.messages.stream({
      model: "claude-opus-5-5",
      max_tokens: 32_000,
      system: SYSTEM,
      output_config: { effort: "medium" },
      tools: [...SERVER_TOOLS, ...TABLE1_TOOLS, REPORT_TOOL],
      tool_choice: { type: "auto" },
      messages,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
    } as unknown as Anthropic.Beta.MessageCreateParamsStreaming, { signal });
    const msg = await stream.finalMessage();
    if (msg.stop_reason === "refusal") return { status: "not_found", message: "That request couldn't be searched." };
    const uses = msg.content.filter((b) => b.type === "tool_use") as Anthropic.Beta.BetaToolUseBlock[];
    const report = uses.find((b) => b.name === "report_result");
    await note(stepsOf(msg.content as unknown as Rec[]));
    if (report) return report.input as Rec;
    messages.push({ role: "assistant", content: msg.content });
    if (msg.stop_reason === "pause_turn") continue; // the server-side tool loop paused; resend to resume
    const ours = uses.filter((b) => b.name.startsWith("table1_"));
    if (ours.length) {
      const found: string[] = [];
      const results = await Promise.all(ours.map(async (u) => {
        let content: string;
        try {
          const data = await table1(u.name, (u.input ?? {}) as Rec);
          const line = stepOfResult(u.name, data);
          if (line) found.push(line);
          content = JSON.stringify(data ?? null);
        } catch (e) {
          found.push("Table 1's results couldn't be read just now");
          content = `Table 1's results couldn't be read just now (${e instanceof Error ? e.message : String(e)}). Use the web.`;
        }
        return { type: "tool_result" as const, tool_use_id: u.id, content };
      }));
      await note(found);
      messages.push({ role: "user", content: results });
      continue;
    }
    // Ended without reporting: remind once, the way the prompt asks.
    if (reminded) break;
    reminded = true;
    messages.push({ role: "user", content: "Call report_result now with what you found." });
  }
  return { status: "not_found", message: "The search didn't settle on a list. Try naming the archetype and format." };
}
