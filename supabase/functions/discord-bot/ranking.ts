// /ranking: one of your cube or Limited set rankings, posted in the channel (contract/discord-2026-10-29.md § Rankings).
// discord_ranking hands over the ranking as the apps read it (log, depth, final size, baseline) with the subject's cards
// and their facts; the lists are worked out here with the apps' engine (ranking-brief's cubeRanking.ts, the web's copy)
// and each card's color by the same rule as Group by color (brief.ts colorJob), so the post shows the app's places.
// Pure, so discord-bot.test.ts checks it without Discord or a database.
import { colorJob, type CardFact } from "../ranking-brief/brief.ts";
import { COLOR_JOBS, depthPhrase, JOB_TITLE, RankingState, type RankDepth, type RankJob, type RankScreen } from "../ranking-brief/cubeRanking.ts";
import { ACCENT, clean, imageUrl, SITE } from "./embeds.ts";

/** discord_ranking's answer (the parts read here). `facts`: [oracle id, name, type line, mana cost, colors]. */
export interface RankingPost {
  id: string;
  name: string;
  depth: RankDepth;
  top: number;
  sharing: string;
  set_key: string | null;
  by: { display_name?: string } | null;
  log: RankScreen[];
  baseline?: string[];
  cards: string[];
  facts: [string, string, string | null, string | null, string[] | null][];
  cube: { name?: string; set?: string; kind?: string; printings?: Record<string, string> } | null;
}

/** One of your rankings in the picker (discord_my_rankings). */
export interface RankingRow { id: string; subject: string; kind: "cube" | "set"; set: string | null; name: string; top: number; ranked: number }

/** What to show: the final's top N, or one color's list. */
export interface RankShow { job: RankJob; n: number | null }

/** The show option: "50" / "100" (the final's top N) or a color's letter; left out, the ranking's own final. */
export function rankShow(value: string | undefined, top: number): RankShow | null {
  if (!value) return { job: "F", n: top };
  if (value === "50" || value === "100") return { job: "F", n: Number(value) };
  return (COLOR_JOBS as string[]).includes(value) ? { job: value as RankJob, n: null } : null;
}

/** "My ranking" (the stored default) and blank aren't labels (contract/cube-rankings-2026-10-21.md § Names). */
const UNNAMED = "my ranking";
export const rankingLabel = (name: string): string | null => {
  const n = (name ?? "").trim();
  return !n || n.toLowerCase() === UNNAMED ? null : n;
};
/** Who ranked it, then the label: "Mara Quinn · Power only", as the apps title it. */
export const rankingTitle = (by: string | null | undefined, name: string) =>
  [by?.trim() || "Someone", rankingLabel(name)].filter(Boolean).join(" · ");

/** The picker's line: "Lindmark Cube · Summer · 87/100 ranked", a set with its code. */
export function rankingChoice(r: RankingRow): string {
  const subject = r.kind === "set" && r.set && r.subject !== r.set ? `${r.subject} (${r.set})` : r.subject || r.set || "Cube";
  return [subject, rankingLabel(r.name), `${Math.min(r.ranked, r.top)}/${r.top} ranked`].filter(Boolean).join(" · ");
}

export interface RankingView {
  job: RankJob;
  /** Places shown, best first: oracle id and name. */
  rows: { id: string; name: string }[];
  placed: number;
  target: number;
  size: number;
  done: boolean;
  /** New cards in the cube the ranking hasn't placed yet. */
  waiting: number;
  /** The final asked for is bigger than this ranking's (a top 100 of a top-50 ranking). */
  short: boolean;
}

/** The ranking's lists from its log, as the apps work them out. Null: that color has no cards in the cube. */
export function rankingView(p: RankingPost, show: RankShow): RankingView | null {
  const facts: CardFact[] = p.facts.map(([oracle_id, name, type_line, mana_cost, colors]) =>
    ({ oracle_id, name, type_line, mana_cost, colors, cmc: null, produced_mana: null }));
  const names = new Map(facts.map((f) => [f.oracle_id.toLowerCase(), f.name]));
  const jobs = new Map(facts.map((f) => [f.oracle_id.toLowerCase(), colorJob(f)]));
  // Cards the ranking hasn't caught up with wait outside its lists (ranking-brief's toIn, the apps' rule).
  const seen = new Set((p.baseline ?? []).map((c) => c.toLowerCase()));
  const fresh = p.baseline?.length ? [...jobs.keys()].filter((c) => !seen.has(c)) : [];
  const st = new RankingState(p.id, jobs, p.log ?? [], p.depth, p.top, undefined, fresh);
  if (show.job !== "F" && !st.jobs.includes(show.job)) return null;
  const s = st.session(show.job);
  const ids = s.top.map((x) => st.id(x));
  const shown = show.n != null ? ids.slice(0, show.n) : ids;
  return {
    job: show.job,
    rows: shown.map((id) => ({ id, name: names.get(id) ?? "Unknown card" })),
    placed: ids.length,
    target: s.target,
    size: s.size,
    done: s.done,
    waiting: s.waiting.length,
    short: show.n != null && show.n > p.top,
  };
}

/** Why there's nothing to post (said only to the person): a color the subject has no cards of, or nothing placed yet. */
export function emptyText(p: RankingPost, job: RankJob, v: RankingView | null): string | null {
  const subject = p.cube?.name || p.set_key || "This cube";
  if (!v) return job === "L" ? `${subject} has no lands.` : `${subject} has no ${JOB_TITLE[job].toLowerCase()} cards.`;
  if (v.rows.length) return null;
  return job === "F" ? "Nothing's placed in this ranking's final yet. Rank on Table 1, then post it."
    : `No ${JOB_TITLE[job].toLowerCase()} ${job === "L" ? "" : "cards "}placed yet. Rank on Table 1, then post it.`;
}

/** What the list is, then how far along: "Top 50", "White · top quarter of 68 cards", "· 12 of 17 placed so far". */
function statusText(p: RankingPost, v: RankingView): string {
  const bits: string[] = [];
  if (v.job === "F") {
    if (v.short) bits.push(`This ranking's final is a top ${p.top}.`);
    if (!v.done) bits.push(`${v.placed} of ${v.target} placed so far.`);
  } else {
    const n = `${v.size} ${JOB_TITLE[v.job].toLowerCase()} ${v.job === "L" ? "" : "cards"}`.replace(/\s+/g, " ").trim();
    const of = p.depth === "full" ? `All ${n}` : `The ${depthPhrase(p.depth)} of ${n}`;
    bits.push(`${of}${v.done ? "." : `: ${v.placed} of ${v.target} placed so far.`}`);
  }
  if (v.waiting) bits.push(`${v.waiting} new ${v.waiting === 1 ? "card" : "cards"} not placed yet.`);
  return bits.join(" ");
}

const NAME_MAX = 30;
const cut = (s: string) => (s.length > NAME_MAX ? `${s.slice(0, NAME_MAX - 1)}…` : s);

/** Columns of 25 places, numbered in a code span so Discord doesn't make them a list. */
export function rankingFields(rows: { name: string }[], per = 25, max = 100) {
  const shown = rows.slice(0, max);
  const width = String(shown.length).length;
  const out: { name: string; value: string; inline: boolean }[] = [];
  for (let i = 0; i < shown.length; i += per) {
    const chunk = shown.slice(i, i + per);
    out.push({
      name: `${i + 1}–${i + chunk.length}`,
      value: chunk.map((r, k) => `\`${String(i + k + 1).padStart(width)}\` ${clean(cut(r.name))}`).join("\n").slice(0, 1024),
      inline: true,
    });
  }
  return out;
}

export const rankingLink = (p: RankingPost, job: RankJob) => `${SITE}/library/ranking/${p.id}/lists/${job}`;

export function rankingEmbed(p: RankingPost, v: RankingView) {
  const subject = clean(p.cube?.name || p.set_key || "Cube");
  const list = v.job === "F" ? `Top ${v.rows.length}` : JOB_TITLE[v.job];
  const first = v.rows[0];
  const printing = first ? p.cube?.printings?.[first.id] : undefined;
  const status = statusText(p, v);
  return {
    title: `${subject} · ${list}`.slice(0, 256),
    url: rankingLink(p, v.job),
    author: { name: `Ranking by ${rankingTitle(p.by?.display_name, p.name)}`.slice(0, 256) },
    description: status || undefined,
    color: ACCENT,
    fields: rankingFields(v.rows),
    thumbnail: printing ? { url: imageUrl(printing, null) } : undefined,
    footer: { text: p.set_key ? "Table 1 Rankings · Limited" : "Table 1 Rankings" },
  };
}

/** Open in Table 1 when the ranking is shared (its cube's audience, or a set's friends); Only me opens for no one else. */
export const rankingComponents = (p: RankingPost, job: RankJob) =>
  p.sharing === "private" ? [] : [{ type: 1, components: [{ type: 2, style: 5, label: "Open in Table 1", url: rankingLink(p, job) }] }];
