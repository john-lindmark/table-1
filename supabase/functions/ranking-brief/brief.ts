// The brief's data and prompt (contract/cube-rankings-2026-10-21.md § Brief), kept pure so brief.test.ts can check it
// without the network. index.ts reads both rankings as the caller, works their lists out with the shared engine
// (cubeRanking.ts, the web copy, kept identical by tools/test/engine-parity.sh) and asks Claude for 2-5 sentences.
import { COLOR_JOBS, JOB_TITLE, RankingState, compare, type RankJob, type RankScreen } from "./cubeRanking.ts";

/** A short summary of numbers worked out here, cached per change: the fast, inexpensive model. The prompt carries each
 *  card's type, cost and mana so it needn't know every card by name; switch to claude-sonnet-5-5 if briefs read thin. */
export const MODEL = "claude-haiku-5-5";
/** In the top 100, cards past this place in both lists are left out of the card rows (unless among the biggest
 *  differences): they cost tokens and rarely change the story. */
export const ROW_PLACES = 50;
/** Fewer cards placed by both than this, and there's nothing worth describing yet. */
export const MIN_COMPARED = 5;

/** What the server knows about a card (public.card_oracles). */
export interface CardFact {
  oracle_id: string;
  name: string;
  type_line: string | null;
  mana_cost: string | null;
  cmc: number | null;
  colors: string[] | null;
  produced_mana: string | null;
}

/** One ranking as cube_ranking_get returns it, plus who made it. */
export interface RankingIn {
  id: string;
  rev: number;
  depth: "half" | "full";
  top: number;
  name: string;
  by: string;
  log: RankScreen[];
  /** The cube's cards added since this ranking caught up: they wait outside its lists until placed. */
  fresh?: string[];
}

/** The cube's Group by color, the same rule as every client (CardGrouping / cardGrouping.ts). */
export function colorJob(f: CardFact): RankJob {
  const front = (f.type_line ?? "").split(" // ")[0];
  if (front.includes("Land") && !front.includes("Creature")) return "L";
  const letters = f.colors?.length ? f.colors.join("") : f.mana_cost ?? "";
  const cs = (["W", "U", "B", "R", "G"] as const).filter((c) => letters.includes(c));
  return cs.length > 1 ? "M" : cs.length === 1 ? cs[0] : "C";
}

const isLand = (f: CardFact) => colorJob(f) === "L";
/** Makes two or more colors, or fetches a basic: what players call fixing. */
const fixes = (f: CardFact) => !!f.produced_mana && (f.produced_mana.includes("F") || f.produced_mana.replace(/[CF]/g, "").length >= 2);

export interface Side { label: string; places: Map<string, number>; done: boolean; size: number; cut: number }

/** Both rankings' places in one list, worked out from their logs on the same cube. */
export function sides(cards: CardFact[], a: RankingIn, b: RankingIn, list: RankJob) {
  const jobs = new Map(cards.map((c) => [c.oracle_id.toLowerCase(), colorJob(c)]));
  const sa = new RankingState(a.id, jobs, a.log, a.depth, a.top, undefined, a.fresh ?? []),
        sb = new RankingState(b.id, jobs, b.log, b.depth, b.top, undefined, b.fresh ?? []);
  const pa = sa.session(list), pb = sb.session(list);
  const translated = { top: pb.top.map((x) => sa.knowledge.index.get(sb.id(x))!).filter((x) => x != null), done: pb.done, size: pb.size };
  const cmp = compare(sa.knowledge, pa, translated, sa.scope(list));
  const side = (st: RankingState, s: typeof pa, label: string): Side =>
    ({ label, places: new Map(s.top.map((x, i) => [st.id(x), i + 1])), done: s.done, size: s.size, cut: s.target });
  return { a: side(sa, pa, a.by), b: side(sb, pb, b.by), cmp };
}

const listName = (list: RankJob, top: number) => (list === "F" ? `the top ${top} across the whole cube` : `${JOB_TITLE[list]} (the cube's ${JOB_TITLE[list].toLowerCase()} cards)`);

function placeText(s: Side, id: string): string {
  const p = s.places.get(id);
  if (p != null) return `#${p}`;
  return s.done && s.places.size < s.size ? `below their top ${s.places.size}` : "not placed yet";
}

/** Per-ranking shape of its list: colors, curve, creatures, fixing. Over the first `n` places. */
function shape(s: Side, facts: Map<string, CardFact>, n: number) {
  const ids = [...s.places.entries()].sort((x, y) => x[1] - y[1]).slice(0, n).map(([id]) => id);
  const fs = ids.map((id) => facts.get(id)).filter((f): f is CardFact => !!f);
  const byColor = Object.fromEntries(COLOR_JOBS.map((j) => [JOB_TITLE[j], fs.filter((f) => colorJob(f) === j).length]));
  const spells = fs.filter((f) => !isLand(f));
  const mv = spells.length ? spells.reduce((t, f) => t + Number(f.cmc ?? 0), 0) / spells.length : 0;
  return {
    cards: fs.length,
    by_color: byColor,
    average_mana_value_of_spells: Math.round(mv * 100) / 100,
    creatures: fs.filter((f) => (f.type_line ?? "").split(" // ")[0].includes("Creature")).length,
    lands: fs.filter(isLand).length,
    fixing: fs.filter(fixes).length,
    cheap_spells_mv_0_to_2: spells.filter((f) => Number(f.cmc ?? 0) <= 2).length,
  };
}

/** What the model calls the two players: a name says nothing about how someone is referred to, and these keep it from
 *  guessing. named() puts the names back. */
export const LABELS = ["Player A", "Player B"] as const;

/** The brief with each label replaced by that player's name. */
export function named(brief: string, a: string, b: string): string {
  return brief.replace(/\bPlayer A\b/gi, () => a).replace(/\bPlayer B\b/gi, () => b);
}

/** The user message: which list, the numbers, and every card either ranking placed (best place first), with the
 *  players as LABELS. Ranking names stay out: they're the players' own words. */
export function prompt(cards: CardFact[], a: RankingIn, b: RankingIn, list: RankJob, cubeName: string): { text: string; compared: number } {
  const facts = new Map(cards.map((c) => [c.oracle_id.toLowerCase(), c]));
  const { a: sa, b: sb, cmp } = sides(cards, { ...a, by: LABELS[0] }, { ...b, by: LABELS[1] }, list);
  const ids = [...new Set([...sa.places.keys(), ...sb.places.keys()])].sort((x, y) => {
    const bx = Math.min(sa.places.get(x) ?? 1e9, sb.places.get(x) ?? 1e9), by = Math.min(sa.places.get(y) ?? 1e9, sb.places.get(y) ?? 1e9);
    return bx - by || (x < y ? -1 : 1);
  });
  const n = Math.min(Math.max(sa.places.size, sb.places.size), list === "F" ? 100 : 60);
  const both = ids.filter((id) => sa.places.has(id) && sb.places.has(id)).length;
  const top10 = (s: Side) => new Set([...s.places].filter(([, p]) => p <= 10).map(([id]) => id));
  const t10a = top10(sa), t10b = top10(sb);
  // Near the top for both: each list's first quarter (at least its first 5).
  const near = (s: Side) => Math.max(5, Math.ceil(s.places.size / 4));
  const bothHigh = ids.filter((id) => (sa.places.get(id) ?? 1e9) <= near(sa) && (sb.places.get(id) ?? 1e9) <= near(sb));
  const notable = new Set(cmp.biggest.map((g) => g.card));
  const shown = list === "F"
    ? ids.filter((id) => Math.min(sa.places.get(id) ?? 1e9, sb.places.get(id) ?? 1e9) <= ROW_PLACES || notable.has(id))
    : ids;
  const rows = shown.map((id) => {
    const f = facts.get(id);
    const colors = f?.colors?.length ? f.colors.join("") : "colorless";
    return [f?.name ?? id, colors, f?.type_line ?? "", f?.mana_cost ?? "", f?.produced_mana ? `makes ${f.produced_mana}` : "",
            `${sa.label} ${placeText(sa, id)}`, `${sb.label} ${placeText(sb, id)}`].filter(Boolean).join(" | ");
  });
  const data = {
    cube: cubeName,
    list: listName(list, Math.max(a.top, b.top)),
    rankings: [
      { who: sa.label, placed: sa.places.size, sorts: a.depth === "half" && list !== "F" ? "only the top half" : "every place", shape: shape(sa, facts, n) },
      { who: sb.label, placed: sb.places.size, sorts: b.depth === "half" && list !== "F" ? "only the top half" : "every place", shape: shape(sb, facts, n) },
    ],
    overlap: {
      cards_both_placed: both,
      compared: cmp.compared,
      average_places_apart: cmp.avgTenths / 10,
      average_is_a_lower_bound: cmp.atLeast,
      shared_top_10: [...t10a].filter((id) => t10b.has(id)).map((id) => facts.get(id)?.name ?? id),
      both_rank_near_the_top: bothHigh.map((id) => facts.get(id)?.name ?? id),
    },
    biggest_differences: cmp.biggest.map((g) => ({
      card: facts.get(g.card)?.name ?? g.card,
      [sa.label]: g.aOut ? `below the top ${g.a - 1}` : `#${g.a}`,
      [sb.label]: g.bOut ? `below the top ${g.b - 1}` : `#${g.b}`,
    })),
  };
  const text = `Two people ranked the same cube. Compare how they ranked ${data.list}.

Summary numbers (JSON):
${JSON.stringify(data)}

${list === "F" ? `Cards either of them placed in their top ${ROW_PLACES}, and the biggest differences` : "Every card either of them placed"}, best place first (name | colors | type | cost | mana it makes | places):
${rows.join("\n")}

Call them ${sa.label} and ${sb.label} (or they/them), never he or she.`;
  return { text, compared: cmp.compared };
}

export const SYSTEM = `You write short comparisons of two Magic: The Gathering players' cube rankings for Table 1, an app for competitive players. Each player stack-ranked the same cube's cards, best first. You get one list (a color, or the top cards across the whole cube) as both of them placed it.

Write 2 to 5 plain sentences, as one paragraph, calling the two players Player A and Player B (the app puts their names in) or they/them; never he, she, his or her. Start with where they agree: the cards in overlap.both_rank_near_the_top, the only cards both of them rank highly. If that list is empty or short, say they agree on little; never say both rank something highly that isn't in it. Then where they differ and what that says about how each likes to draft this cube. Look for:
- color preferences (one ranks a color's cards higher or puts more of them in the list),
- mana fixing: lands and permanents that make two or more colors (the "makes" letters; F means it fetches a basic). Colorless mana (Sol Ring, Mana Crypt, Ancient Tomb) is fast mana, not fixing. Name a land's colors from what it makes (a land that makes RW is red-white),
- archetypes and strategies: aggro, tempo, control, midrange, ramp, combo, reanimator, storm, artifacts, tokens, spells or graveyard decks,
- power level versus flexibility, cheap interaction versus big threats, creatures versus spells, the mana curve.
Use what you know about the cards from their names, and the type, cost and mana information given. Use the numbers to find the story, but never put a count, average or number of places apart in the brief (a card's place, like #1, is fine). Mention a few specific cards as examples, by name. Only say what the places support; when the lists are short or mostly agree, say that rather than inventing a contrast. If a player sorts only the top half, a card "below their top N" may still be good to them; don't overstate it.

No headings, lists, markdown or preamble: only the paragraph.`;

/** Structured output: just the paragraph. */
export const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["brief"],
  properties: { brief: { type: "string", description: "2 to 5 sentences, one paragraph." } },
} as const;

/** The paragraph, trimmed, at most five sentences and 1200 characters; null when it isn't usable. */
export function cleanBrief(raw: unknown): string | null {
  const s = typeof raw === "object" && raw && typeof (raw as { brief?: unknown }).brief === "string" ? (raw as { brief: string }).brief : null;
  if (!s) return null;
  const one = s.replace(/\s+/g, " ").trim();
  // Sentence ends are . ! ? followed by a space, so a decimal (1.5) never splits one and no text is dropped.
  const kept = one.split(/(?<=[.!?])\s+/).slice(0, 5).join(" ");
  return kept.length >= 20 ? kept.slice(0, 1200) : null;
}

/** He, she and the like: players are never gendered from their names. A brief that does it isn't kept. */
export const GENDERED = /\b(he|she|him|his|her|hers|himself|herself)\b/i;

/** The follow-up that asks for a gendered brief again, with the labels or they/them. */
export const REWRITE = "Rewrite that brief without he, she, him, his, her or hers: use Player A, Player B or they/them. Keep everything else.";

/** Cache key: the inputs that change the brief. */
export async function inputHash(a: RankingIn, b: RankingIn, list: RankJob, cards: string[]): Promise<string> {
  const text = JSON.stringify([a.id, a.rev, a.depth, a.top, a.by, b.id, b.rev, b.depth, b.top, b.by, list, [...cards].map((c) => c.toLowerCase()).sort(), MODEL,
                               [...(a.fresh ?? [])].sort(), [...(b.fresh ?? [])].sort()]);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Plays a whole ranking (every color, then the final) by a person's order of the cards, best first: what a ranker
 *  with that taste would lock in. For the function's eval mode and tests. */
export function simulateLog(cards: CardFact[], id: string, depth: "half" | "full", top: number, order: string[]): RankScreen[] {
  const jobs = new Map(cards.map((c) => [c.oracle_id.toLowerCase(), colorJob(c)]));
  const rank = new Map(order.map((o, i) => [o.toLowerCase(), i]));
  const at = (c: string) => rank.get(c) ?? 1e6;
  let st = new RankingState(id, jobs, [], depth, top);
  const log: RankScreen[] = [];
  for (const job of [...st.jobs, "F" as RankJob]) {
    for (let q = st.session(job).question; q; q = st.session(job).question) {
      const screen: RankScreen = { s: job, o: q.map((x) => st.id(x)).sort((x, y) => at(x) - at(y) || (x < y ? -1 : 1)) };
      log.push(screen);
      st = st.appending(screen);
    }
  }
  return log;
}
