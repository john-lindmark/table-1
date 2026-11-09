// What the bot shows: the event card, the results post, deck and card posts, /help. Pure functions over the JSON the
// database returns (contract/discord-2026-10-29.md §5), so they are tested without Discord or a database. Also the
// option reading, the button ids and the "when" parsing the commands need.
import commands from "./commands.json" with { type: "json" };
import { podPlan } from "../events-engine/seating.ts";

export const ACCENT = 0x00ffd9;
export const SITE = "https://table-1.site";
export const EPHEMERAL = 64;

// ---------------------------------------------------------------- interaction shapes (the parts we read)

export interface Option {
  name: string;
  type: number;
  value?: string | number | boolean;
  options?: Option[];
  focused?: boolean;
}

export interface Interaction {
  type: number;
  id: string;
  token: string;
  application_id: string;
  guild_id?: string;
  channel_id?: string;
  member?: { user: { id: string }; permissions?: string };
  user?: { id: string };
  data?: { name?: string; options?: Option[]; custom_id?: string; component_type?: number };
  message?: { id: string; flags?: number };
}

export const InteractionType = { PING: 1, COMMAND: 2, COMPONENT: 3, AUTOCOMPLETE: 4 } as const;
export const ResponseType = { PONG: 1, MESSAGE: 4, DEFERRED: 5, UPDATE_MESSAGE: 7, AUTOCOMPLETE: 8 } as const;

/** "event create" for a subcommand, "help" for a plain command. */
export function commandPath(ix: Interaction): { path: string; options: Option[] } {
  const name = ix.data?.name ?? "";
  const first = ix.data?.options?.[0];
  if (first && first.type === 1) return { path: `${name} ${first.name}`, options: first.options ?? [] };
  return { path: name, options: ix.data?.options ?? [] };
}

export function opt<T = string>(options: Option[], name: string): T | undefined {
  const o = options.find((x) => x.name === name);
  return o?.value as T | undefined;
}

export function focused(options: Option[]): Option | undefined {
  return options.find((o) => o.focused);
}

export const userId = (ix: Interaction) => ix.member?.user.id ?? ix.user?.id ?? "";
export const isSnowflake = (s: string | undefined | null): s is string => typeof s === "string" && /^[0-9]{5,25}$/.test(s);

/** Discord permission bits on the member: Manage Server (1 << 5) or Administrator (1 << 3). */
export function canManageServer(ix: Interaction): boolean {
  const p = ix.member?.permissions;
  if (!p || !/^\d+$/.test(p)) return false;
  const bits = BigInt(p);
  return (bits & 32n) !== 0n || (bits & 8n) !== 0n;
}

// ---------------------------------------------------------------- button ids

export type ButtonAction = "up" | "down" | "link" | "deck" | "wants" | "trades";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export const buttonId = (action: ButtonAction, id?: string) => id ? `t1:${action}:${id}` : `t1:${action}`;

export function parseButtonId(customId: string | undefined): { action: ButtonAction; id: string | null } | null {
  if (!customId) return null;
  const m = /^t1:(up|down|link|deck|wants|trades)(?::([0-9a-f-]{36}))?$/.exec(customId);
  if (!m) return null;
  if (m[2] && !UUID.test(m[2])) return null;
  return { action: m[1] as ButtonAction, id: m[2] ?? null };
}

/** An event id out of a pasted table-1.site link, or a bare id. */
export function eventIdFrom(text: string): string | null {
  const t = text.trim();
  if (UUID.test(t)) return t;
  const m = /table-1\.site\/(?:s|e|p)\/([0-9a-f-]{36})/i.exec(t);
  return m && UUID.test(m[1].toLowerCase()) ? m[1].toLowerCase() : null;
}

// ---------------------------------------------------------------- when

export interface When {
  iso: string;
  localDate: string;
}

function offsetMinutes(utcMs: number, tz: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(utcMs));
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? 0);
  const asUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  return (asUtc - utcMs) / 60000;
}

export function validZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return /^[A-Za-z_]+(\/[A-Za-z0-9_+-]+)+$|^UTC$/.test(tz);
  } catch {
    return false;
  }
}

/** "2026-11-07 18:30" (or with T, or "18.30") read as wall-clock time in `tz`, to an instant. Null = not a time. */
export function parseWhen(text: string, tz: string, nowMs = Date.now()): When | null | "past" | "far" {
  const m = /^\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2})[:.](\d{2})\s*$/.exec(text);
  if (!m || !validZone(tz)) return null;
  const [y, mo, d, h, mi] = m.slice(1).map(Number);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59) return null;
  const wall = Date.UTC(y, mo - 1, d, h, mi);
  let utc = wall - offsetMinutes(wall, tz) * 60000;
  utc = wall - offsetMinutes(utc, tz) * 60000; // once more for a DST edge
  if (Number.isNaN(utc)) return null;
  if (utc < nowMs - 60 * 60000) return "past";
  if (utc > nowMs + 366 * 86400000) return "far";
  return { iso: new Date(utc).toISOString(), localDate: `${y}-${String(mo).padStart(2, "0")}-${String(d).padStart(2, "0")}` };
}

export const COMMON_ZONES = [
  "UTC", "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin", "Europe/Madrid", "Europe/Rome",
  "Europe/Amsterdam", "Europe/Brussels", "Europe/Zurich", "Europe/Vienna", "Europe/Prague", "Europe/Warsaw", "Europe/Stockholm",
  "Europe/Oslo", "Europe/Copenhagen", "Europe/Helsinki", "Europe/Athens", "Europe/Istanbul", "Europe/Kyiv", "Europe/Moscow",
  "America/New_York", "America/Chicago", "America/Denver", "America/Phoenix", "America/Los_Angeles", "America/Anchorage",
  "Pacific/Honolulu", "America/Toronto", "America/Vancouver", "America/Mexico_City", "America/Bogota", "America/Lima",
  "America/Santiago", "America/Sao_Paulo", "America/Argentina/Buenos_Aires", "Asia/Tokyo", "Asia/Seoul", "Asia/Shanghai",
  "Asia/Hong_Kong", "Asia/Taipei", "Asia/Singapore", "Asia/Manila", "Asia/Bangkok", "Asia/Jakarta", "Asia/Kolkata",
  "Asia/Dubai", "Asia/Jerusalem", "Africa/Johannesburg", "Africa/Cairo", "Africa/Lagos", "Africa/Nairobi",
  "Australia/Sydney", "Australia/Melbourne", "Australia/Brisbane", "Australia/Perth", "Pacific/Auckland",
];

export function zoneChoices(query: string): { name: string; value: string }[] {
  const q = query.trim().toLowerCase().replace(/ /g, "_");
  const hits = COMMON_ZONES.filter((z) => !q || z.toLowerCase().includes(q)).slice(0, 24);
  if (q && validZone(query.trim()) && !hits.some((z) => z.toLowerCase() === q)) hits.unshift(query.trim());
  return hits.slice(0, 25).map((z) => ({ name: z.replace(/_/g, " "), value: z }));
}

// ---------------------------------------------------------------- the card

export interface Card {
  event_id: string;
  name: string;
  format_label: string | null;
  format_name?: string | null;
  set_name: string | null;
  cube_name: string | null;
  status: string;
  starts_at: string | null;
  venue_name: string | null;
  capacity: number | null;
  top_cut: number;
  auto_rounds: boolean;
  number_of_rounds: number;
  current_round: number;
  short_code: string | null;
  organizer_name: string | null;
  sign_up: "open" | "full" | "closed";
  players: number;
  player_names: string[];
  waitlist: number;
  waitlist_names: string[];
  link: string;
  /** Where the viewer the card was drawn for stands: in the event, on the waitlist, or not in (null; also unlinked). */
  me?: "player" | "waitlisted" | null;
  organizer?: boolean;
  guild_id?: string | null;
  channel_id?: string | null;
  message_id?: string | null;
  results_message_id?: string | null;
  /** Drafts (contract/draft-pods-2026-11-09.md): the organizer's number of pods (null = automatic), how rounds
   *  after the first pair, and once the seats are drawn each pod's size in order. Absent on other formats. */
  pods?: number | null;
  pod_pairing?: "pod" | "cross" | null;
  pod_sizes?: number[] | null;
}

/** Text from people, safe in an embed: no markdown, no mentions, one line. */
export const clean = (s: string) => s.replace(/[*_`~|>\\]/g, (c) => `\\${c}`).replace(/@/g, "@​").replace(/\s+/g, " ").trim();

function names(list: string[], max = 25): string {
  if (!list.length) return "—";
  const shown = list.slice(0, max).map(clean);
  const more = list.length - shown.length;
  return shown.join(", ") + (more > 0 ? ` and ${more} more` : "");
}

const unix = (iso: string) => Math.floor(new Date(iso).getTime() / 1000);

export function statusLine(c: Card): string {
  if (c.status === "cancelled") return "Cancelled";
  if (c.status === "completed" || c.status === "archived") return "Finished";
  if (c.status === "in_progress") return `Round ${c.current_round} of ${c.number_of_rounds}`;
  if (c.sign_up === "full") return "Full · waitlist open";
  if (c.sign_up === "closed") return "Sign-ups closed";
  return "Sign-ups open";
}

/** The card's Pods line for a draft: the seated pods once drawn, else the pick for the players so far. Nothing for
 *  one pod nobody asked for (an ordinary draft of up to 8) or for other formats.
 *  "2 pods · 8, 7 · paired inside pods" / "3 pods · 6, 6, 5 · Swiss across pods" / "2 pods · paired inside pods". */
export function podsLine(c: Card): string | null {
  if (c.format_name !== "draft") return null;
  const sizes = c.pod_sizes?.length ? c.pod_sizes : podPlan(c.players, c.pods ?? null);
  if (sizes.length < 2 && c.pods == null) return null;
  const pairing = c.pod_pairing === "cross" ? "Swiss across pods" : "paired inside pods";
  if (!sizes.length) return `${c.pods} pod${c.pods === 1 ? "" : "s"} · ${pairing}`;
  if (sizes.length === 1) return `1 pod · ${sizes[0]}`;
  return `${sizes.length} pods · ${sizes.join(", ")} · ${pairing}`;
}

export function eventEmbed(c: Card) {
  const product = c.set_name ?? c.cube_name;
  const lines: string[] = [];
  lines.push(clean(product ? `${c.format_label ?? ""} · ${product}` : (c.format_label ?? "")));
  if (c.starts_at) lines.push(`<t:${unix(c.starts_at)}:F> · <t:${unix(c.starts_at)}:R>`);
  if (c.venue_name) lines.push(clean(c.venue_name));
  if (c.organizer_name) lines.push(`Organizer: ${clean(c.organizer_name)}`);
  const fields = [
    { name: c.capacity ? `Players · ${c.players}/${c.capacity}` : `Players · ${c.players}`, value: names(c.player_names), inline: false },
  ];
  if (c.waitlist > 0) fields.push({ name: `Waitlist · ${c.waitlist}`, value: names(c.waitlist_names), inline: false });
  fields.push({ name: "Rounds", value: c.auto_rounds && c.status === "setup" ? `${c.number_of_rounds} (follows the players)` : String(c.number_of_rounds), inline: true });
  fields.push({ name: "Top cut", value: c.top_cut === 8 ? "Top 8" : "None", inline: true });
  const pods = podsLine(c);
  if (pods) fields.push({ name: "Pods", value: pods, inline: true });
  if (c.short_code && c.sign_up !== "closed") fields.push({ name: "Join code", value: `\`${c.short_code}\``, inline: true });
  return {
    title: clean(c.name).slice(0, 256),
    url: c.link,
    description: lines.filter(Boolean).join("\n").slice(0, 4000),
    color: ACCENT,
    fields,
    footer: { text: `Table 1 · ${statusLine(c)}` },
  };
}

/** The card's buttons. A Discord message shows the same buttons to everyone, so the public card offers Sign up only
 *  (a tap by someone already in answers privately with Drop); a personal card (an ephemeral one, drawn for its viewer)
 *  offers the one that applies: Drop when they're in or waiting, else Sign up. Closed sign-ups leave only the link. */
export function eventComponents(c: Card, personal = false) {
  const buttons: Record<string, unknown>[] = [];
  if (c.sign_up !== "closed") {
    const inIt = personal && (c.me === "player" || c.me === "waitlisted");
    buttons.push(inIt
      ? { type: 2, style: 2, label: c.me === "waitlisted" ? "Leave the waitlist" : "Drop", custom_id: buttonId("down", c.event_id) }
      : { type: 2, style: 1, label: "Sign up", custom_id: buttonId("up", c.event_id) });
  }
  buttons.push({ type: 2, style: 5, label: "Open in Table 1", url: c.link });
  return [{ type: 1, components: buttons }];
}

export const eventMessage = (c: Card, personal = false) => ({ embeds: [eventEmbed(c)], components: eventComponents(c, personal) });

/** The one-line note the clicker gets after a sign-up or drop. */
export function outcomeText(result: string, c: Card, position?: number | null): string {
  const n = clean(c.name);
  switch (result) {
    case "joined": return `You're in · ${n}`;
    case "waitlisted": return `${n} is full. You're number ${position ?? "?"} on the waitlist.`;
    case "already_joined": return `You're already in · ${n}`;
    case "already_waitlisted": return `You're already on the waitlist · ${n}${position ? ` (number ${position})` : ""}`;
    case "left": return `You left · ${n}`;
    case "left_waitlist": return `You left the waitlist · ${n}`;
    case "not_in": return `You weren't in · ${n}`;
  }
  return n;
}

// ---------------------------------------------------------------- results

import type { ResultRow, TeamResultRow } from "./standings.ts";

const record = (w: number, l: number, d: number) => `${w}-${l}${d ? `-${d}` : ""}`;

/** The results post. A team event (teams given) shows each team on its own, members best first under it, as the
 *  apps' team table does; otherwise the players in order. */
export function resultsEmbed(c: Card, rows: ResultRow[], final: boolean, teams: TeamResultRow[] | null = null) {
  const title = `${final ? "Results" : "Standings so far"} · ${clean(c.name)}`.slice(0, 256);
  const after = `Table 1 · After round ${c.current_round} of ${c.number_of_rounds}`;
  if (teams?.length) {
    const shown = teams.slice(0, 10);
    const fields = shown.map((t) => ({
      name: `${t.rank === 1 && final ? "🏆" : `${t.rank}.`} ${clean(t.name)} · ${record(t.wins, t.losses, t.draws)} · ${t.points} pts · ${t.matchWins} match win${t.matchWins === 1 ? "" : "s"}`.slice(0, 256),
      value: (t.members.length
        ? t.members.map((m) => `${clean(m.name)}${m.dropped ? " (dropped)" : ""} · ${record(m.wins, m.losses, m.draws)}`).join("\n")
        : "—").slice(0, 1024),
      inline: false,
    }));
    if (teams.length > shown.length) fields.push({ name: `…and ${teams.length - shown.length} more teams`, value: "On Table 1", inline: false });
    return {
      title,
      url: c.link,
      color: ACCENT,
      fields,
      footer: { text: final ? `Table 1 · Final standings · ${teams.length} teams · ${rows.length} players` : after },
    };
  }
  const shown = rows.slice(0, final ? 8 : 16);
  // Drafts with two or more pods tag each player with theirs ("P1"), like the apps' standings.
  const lines = shown.map((r) =>
    `${r.rank === 1 && final ? "🏆" : `${r.rank}.`} ${clean(r.name)}${r.pod ? ` · ${r.pod}` : ""}${r.dropped ? " (dropped)" : ""} · ${record(r.wins, r.losses, r.draws)} · ${r.points} pts`
  );
  if (rows.length > shown.length) lines.push(`…and ${rows.length - shown.length} more`);
  if (!rows.length) lines.push("No results yet.");
  return {
    title,
    url: c.link,
    description: lines.join("\n").slice(0, 4000),
    color: ACCENT,
    footer: { text: final ? `Table 1 · Final standings · ${rows.length} players` : after },
  };
}

export const resultsComponents = (c: Card) => [{
  type: 1,
  components: [{ type: 2, style: 5, label: final_label(c), url: c.link }],
}];
const final_label = (c: Card) => c.status === "completed" || c.status === "archived" ? "Standings on Table 1" : "Open in Table 1";

// ---------------------------------------------------------------- decks and cards

export interface DeckPost {
  name: string;
  format: string;
  main: number;
  side: number;
  spice: { score: number; word: string } | null;
  url: string;
  token?: string;
  version?: number;
  hero: { card_id: string; image_ts: number | null; name?: string } | null;
}

/** The deck's picture, drawn by the deck-image function from its share link (a version in the address, so a changed
 *  deck gets a fresh one past Discord's cache). */
export function deckImageUrl(base: string, d: DeckPost): string | null {
  if (!d.token || !/^[A-Za-z0-9_-]{16,40}$/.test(d.token)) return null;
  return `${base.replace(/\/$/, "")}/${d.token}.png?v=${d.version ?? 0}`;
}

export function imageUrl(cardId: string, imageTs: number | null, size: "normal" | "art_crop" | "small" = "normal"): string {
  return `https://cards.scryfall.io/${size}/front/${cardId[0]}/${cardId[1]}/${cardId}.jpg${imageTs ? `?${imageTs}` : ""}`;
}

export function formatName(f: string): string {
  const map: Record<string, string> = {
    standard: "Standard", pioneer: "Pioneer", modern: "Modern", legacy: "Legacy", vintage: "Vintage", pauper: "Pauper",
    premodern: "Premodern", canadian_highlander: "Canadian Highlander", commander: "Commander", oathbreaker: "Oathbreaker",
    cube: "Cube", other: "Other",
  };
  return map[f] ?? f.replace(/_/g, " ").replace(/^\w/, (c) => c.toUpperCase());
}

export function deckEmbed(d: DeckPost, byName: string | null, pictureUrl: string | null = null) {
  const parts = [`${formatName(d.format)} · ${d.main} main${d.side ? ` · ${d.side} side` : ""}`];
  if (d.spice) parts.push(`Spice ${d.spice.score} · ${d.spice.word}`);
  return {
    title: clean(d.name).slice(0, 256),
    url: d.url,
    description: parts.join("\n"),
    color: ACCENT,
    // The whole deck as one picture; the hero card stands in only when the picture can't be addressed.
    image: pictureUrl ? { url: pictureUrl } : undefined,
    thumbnail: !pictureUrl && d.hero ? { url: imageUrl(d.hero.card_id, d.hero.image_ts) } : undefined,
    footer: { text: byName ? `Table 1 · ${clean(byName)}'s deck` : "Table 1" },
  };
}

export const deckComponents = (d: DeckPost) => [{ type: 1, components: [{ type: 2, style: 5, label: "Open on Table 1", url: d.url }] }];

// ---------------------------------------------------------------- /meta: Insights as pictures (contract § Insights images)

export const META_FORMATS: Record<string, string> = {
  standard: "Standard", pioneer: "Pioneer", modern: "Modern", legacy: "Legacy", vintage: "Vintage", pauper: "Pauper",
  canlander: "Canadian Highlander",
};
export const META_DAYS = [7, 14, 30, 90];
export type MetaKind = "matchups" | "winrates" | "deck";
export interface MetaAsk { kind: MetaKind; format: string; tier: "big" | "all"; days: number; a: number | null }

/** The /meta options, checked: a known format, Big or All events (All by default), a window (30 days by default) and,
 *  for a deck, the archetype id its autocomplete chose. Null when the archetype isn't one from the list. */
export function metaAsk(kind: MetaKind, options: Option[]): MetaAsk | null {
  const format = String(opt(options, "format") ?? "");
  if (!META_FORMATS[format]) return null;
  const days = Number(opt(options, "days") ?? 30);
  const raw = String(opt(options, "archetype") ?? "");
  const a = /^[0-9]{1,6}$/.test(raw) ? Number(raw) : null;
  if (kind === "deck" && a == null) return null;
  return { kind, format, tier: opt(options, "events") === "big" ? "big" : "all", days: META_DAYS.includes(days) ? days : 30, a: kind === "deck" ? a : null };
}

/** The picture's address on the meta-image function. `slot` is the post's interaction id, so every post has its own
 *  address and Discord's image cache never serves an older picture to a new post (an hour slot did, after a redraw
 *  within the hour). meta-image keeps its own cache by pack build, so a fresh address costs a fetch, not a draw. */
export function metaImageUrl(base: string, ask: MetaAsk, slot: string): string {
  const q = new URLSearchParams({ tier: ask.tier, days: String(ask.days) });
  if (ask.a != null) q.set("a", String(ask.a));
  q.set("v", String(slot));
  return `${base.replace(/\/+$/, "")}/${ask.format}/${ask.kind}.png?${q}`;
}

/** Where the post's link opens: the archetype's page, the grid, or Meta now (win rates). */
export function metaLink(ask: MetaAsk): string {
  const base = `${SITE}/insights/${ask.format}`;
  return ask.kind === "deck" ? `${base}/archetype/${ask.a}` : ask.kind === "matchups" ? `${base}/matchups` : `${base}/part/meta`;
}

export function metaEmbed(ask: MetaAsk, archetype: string | null, pictureUrl: string) {
  const fmt = META_FORMATS[ask.format];
  const what = ask.kind === "matchups" ? "Matchups" : ask.kind === "winrates" ? "Win rates" : "Matchups";
  const title = ask.kind === "deck" ? `${clean(archetype ?? "Other")} · ${fmt}` : `${fmt} · ${what}`;
  return {
    title: title.slice(0, 256),
    url: metaLink(ask),
    description: `${ask.kind === "deck" ? "Matchups · " : ""}${ask.tier === "big" ? "Big events" : "All events"} · last ${ask.days} days`,
    color: ACCENT,
    image: { url: pictureUrl },
    footer: { text: "Table 1 Insights · Magic Online, TopDeck.gg and Melee results" },
  };
}

export const metaComponents = (ask: MetaAsk) => [{ type: 1, components: [{ type: 2, style: 5, label: "Open in Table 1", url: metaLink(ask) }] }];

export interface CardHit {
  oracle_id: string;
  name: string;
  mana_cost: string | null;
  type_line: string | null;
  card_id: string | null;
  image_ts: number | null;
  set_code: string | null;
  collector_number: string | null;
  usd: string | number | null;
  usd_foil: string | number | null;
  printings: number;
}

const money = (v: string | number | null) => v == null ? null : `$${Number(v).toFixed(2)}`;

export function cardEmbed(h: CardHit) {
  const lines: string[] = [];
  if (h.type_line) lines.push(clean(h.type_line));
  const price = [money(h.usd) && `${money(h.usd)}`, money(h.usd_foil) && `foil ${money(h.usd_foil)}`].filter(Boolean).join(" · ");
  lines.push(price ? `From ${price} (TCGplayer market, near mint)` : "No TCGplayer price");
  lines.push(`${h.printings} ${h.printings === 1 ? "printing" : "printings"}`);
  const scryfall = `https://scryfall.com/search?q=${encodeURIComponent(`oracleid:${h.oracle_id}`)}`;
  return {
    title: `${clean(h.name)}${h.mana_cost ? `  ${h.mana_cost}` : ""}`.slice(0, 256),
    url: scryfall,
    description: lines.join("\n"),
    color: ACCENT,
    image: h.card_id && h.image_ts ? { url: imageUrl(h.card_id, h.image_ts) } : undefined,
    footer: { text: h.set_code ? `Table 1 · ${h.set_code.toUpperCase()} ${h.collector_number ?? ""}`.trim() : "Table 1" },
  };
}

// ---------------------------------------------------------------- wants and for trade

export type Part = "wants" | "for_trade";

export interface PartRow {
  name: string;
  qty: number;
  set: string | null;
  number: string | null;
  finish: string | null;
  condition?: string | null;
  lang?: string | null;
  usd: string | number | null;
  card_id: string | null;
  image_ts: number | null;
}

export interface PartPost {
  part: Part;
  query: string | null;
  rows: PartRow[];
  rows_total: number;
  cards: number;
  value: string | number | null;
  url: string;
  token?: string;
  owner: string | null;
}

export const partTitle = (part: Part) => (part === "wants" ? "wants" : "cards for trade");

function partLine(part: Part, r: PartRow): string {
  const bits = [`${r.qty} ${clean(r.name)}`];
  if (part === "wants") {
    bits.push(r.set ? `${r.set.toUpperCase()} ${r.number ?? ""}`.trim() : "any printing");
    if (r.finish) bits.push(r.finish);
    bits.push(r.usd != null ? `${r.set ? "" : "from "}${money(r.usd)}` : "no price");
  } else {
    bits.push(`${(r.set ?? "").toUpperCase()} ${r.number ?? ""}`.trim());
    if (r.finish && r.finish !== "nonfoil") bits.push(r.finish);
    if (r.condition) bits.push(r.condition);
    if (r.lang && r.lang !== "en") bits.push(r.lang.toUpperCase());
    bits.push(r.usd != null ? money(r.usd)! : "no price");
  }
  return bits.join(" · ");
}

/** The list or the one card, with the link; the card's picture when it's one card. */
export function partEmbed(p: PartPost, max = 25) {
  const what = partTitle(p.part);
  const who = p.owner ? `${clean(p.owner)}'s` : "My";
  const one = p.query && p.rows.length > 0 && new Set(p.rows.map((r) => r.name)).size === 1;
  const title = one ? `${who} ${p.part === "wants" ? "want" : "for trade"}: ${clean(p.rows[0].name)}` : `${who} ${what}`;
  const shown = p.rows.slice(0, max);
  const lines = shown.map((r) => partLine(p.part, r));
  if (p.rows_total > shown.length) lines.push(`…and ${p.rows_total - shown.length} more`);
  if (!p.rows.length) lines.push(p.query ? `Nothing matching "${clean(p.query)}".` : p.part === "wants" ? "No wants yet." : "Nothing for trade yet.");
  const total = p.part === "for_trade" && p.value != null && Number(p.value) > 0 ? ` · ${money(p.value)} at market` : "";
  const first = one ? p.rows[0] : null;
  return {
    title: title.slice(0, 256),
    url: p.url,
    description: lines.join("\n").slice(0, 4000),
    color: ACCENT,
    thumbnail: first?.card_id && first.image_ts ? { url: imageUrl(first.card_id, first.image_ts) } : undefined,
    footer: { text: `Table 1 · ${p.cards} ${p.cards === 1 ? "card" : "cards"} ${p.part === "wants" ? "wanted" : "for trade"}${total}` },
  };
}

export const partComponents = (p: PartPost) => [{ type: 1, components: [{ type: 2, style: 5, label: "Open on Table 1", url: p.url }] }];

export const partConfirmMessage = (part: Part) => ({
  content: `Posting your ${partTitle(part)} here makes a link anyone can open (you can stop sharing it any time under Sharing in Table 1). Post it?`,
  components: [{ type: 1, components: [{ type: 2, style: 1, label: `Post my ${partTitle(part)}`, custom_id: buttonId(part === "wants" ? "wants" : "trades") }] }],
  flags: EPHEMERAL,
});

// ---------------------------------------------------------------- help

export function helpEmbed() {
  const lines = (commands.help as { command: string; text: string }[]).map((h) => `**${h.command}** · ${h.text}`);
  return {
    title: "Table 1 for Discord",
    url: `${SITE}/discord`,
    description: `${lines.join("\n")}\n\nEverything about you is answered so only you see it. Event cards, results and deck posts are public, because you asked for them. More at ${SITE}/discord`.slice(0, 4000),
    color: ACCENT,
    footer: { text: "Table 1" },
  };
}

export const linkMessage = (token: string, expiresAt: string) => ({
  content: `Link your Table 1 account: ${SITE}/discord/link#t=${token}\nThe link works once, until <t:${unix(expiresAt)}:t>. Sign in with Apple, Google, email or Discord on that page; it's the account the bot will act as.`,
  flags: EPHEMERAL,
});

export const needLinkMessage = (what = "do that") => ({
  content: `Link your Table 1 account first to ${what}.`,
  components: [{ type: 1, components: [{ type: 2, style: 1, label: "Link my account", custom_id: buttonId("link") }] }],
  flags: EPHEMERAL,
});

/** The command definitions, for the register tool and the tests. */
export const COMMANDS = commands.commands as unknown[];
export const HELP = commands.help as { command: string; text: string }[];
