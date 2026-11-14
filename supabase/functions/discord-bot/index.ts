// discord-bot: Table 1's Discord interactions endpoint (contract/discord-2026-10-29.md). Discord POSTs every slash
// command, button click and autocomplete here, signed with the application's Ed25519 key; nothing else may call it
// (deployed with verify_jwt off: the signature is the credential). Each interaction is one database round trip,
// made as the linked Table 1 account by the discord_* RPCs, answered inside Discord's 3 seconds; storing message ids,
// follow-ups and telemetry run afterwards in EdgeRuntime.waitUntil. The database also POSTs here (x-t1-secret,
// {refresh: event id}) whenever an event with a posted card changes, and the card is redrawn.
//   secrets: DISCORD_PUBLIC_KEY, DISCORD_BOT_TOKEN (follow-ups use the interaction's own application id),
//            POSTHOG_KEY, POSTHOG_HOST (telemetry; off when empty), DISCORD_TELEMETRY_SALT, T1_ENVIRONMENT
import { createClient } from "npm:@supabase/supabase-js@2";
import { DiscordRest } from "./discord.ts";
import {
  type Card, type CardHit, canManageServer, cardEmbed, commandPath, deckComponents, deckEmbed, deckImageUrl, type DeckPost, EPHEMERAL,
  eventIdFrom, eventMessage, focused, helpEmbed, type Interaction, InteractionType, isSnowflake, linkMessage,
  eventComponents, META_FORMATS, metaAsk, metaComponents, metaEmbed, metaImageUrl, type MetaKind, needLinkMessage, opt, outcomeText,
  parseButtonId, parseWhen, type Part, partComponents, partConfirmMessage, partEmbed,
  type PartPost, ResponseType, resultsComponents, resultsEmbed, userId, zoneChoices,
} from "./embeds.ts";
import {
  emptyText, RANKING_FILE, rankingChoice, rankingComponents, rankingEmbed, rankingImageAsk, type RankingPost, type RankingRow, rankingView, rankShow,
} from "./ranking.ts";
import { batches, type PhotoPick, type PhotoRow, photoEmbed, photoFile, photosHeader, pickPhotos, uprightJpeg } from "./photos.ts";
import { isTeamFormat, loadStandings, type ResultRow } from "./standings.ts";
import { hashId, Telemetry } from "./telemetry.ts";
import { verifyInteraction } from "./verify.ts";

const env = (k: string, d = "") => Deno.env.get(k) ?? d;
// The application's Ed25519 public key (John, 2026-10-29). Not a secret: it only lets us check Discord's signatures.
// The DISCORD_PUBLIC_KEY secret, when set, wins (a new application or a reset key).
const PUBLIC_KEY = env("DISCORD_PUBLIC_KEY") || "cd5249585e23c7a5ac9af4c457d4bba723806dce107724b5143a2c49fc623878";
const BOT_TOKEN = env("DISCORD_BOT_TOKEN");
const ENVIRONMENT = env("T1_ENVIRONMENT", "production");
const SALT = env("DISCORD_TELEMETRY_SALT") || env("DISCORD_APPLICATION_ID");
// Where a deck's picture is drawn (the deck-image function; contract § The deck picture).
const DECK_IMAGE = env("DECK_IMAGE_URL") || `${env("SUPABASE_URL")}/functions/v1/deck-image`;
// Where Insights pictures are drawn (the meta-image function; contract § Insights images).
const META_IMAGE = env("META_IMAGE_URL") || `${env("SUPABASE_URL")}/functions/v1/meta-image`;
// Where a ranking's picture is drawn (the ranking-image function, asked with the service key; contract § Rankings).
const RANKING_IMAGE = env("RANKING_IMAGE_URL") || `${env("SUPABASE_URL")}/functions/v1/ranking-image`;

const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
const rest = new DiscordRest(BOT_TOKEN);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const reply = (data: Record<string, unknown>) => json({ type: ResponseType.MESSAGE, data });
const ephemeral = (content: string, extra: Record<string, unknown> = {}) => reply({ content, flags: EPHEMERAL, ...extra });
const update = (data: Record<string, unknown>) => json({ type: ResponseType.UPDATE_MESSAGE, data });
const choices = (list: { name: string; value: string }[]) =>
  json({ type: ResponseType.AUTOCOMPLETE, data: { choices: list.slice(0, 25).map((c) => ({ name: c.name.slice(0, 100), value: c.value.slice(0, 100) })) } });

/** A refused RPC: PostgREST passes the raise's message, which is already a sentence for the person. */
class Refused extends Error {
  constructor(public code: string, message: string) {
    super(message);
  }
}

async function rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw new Refused(error.code ?? "", error.message ?? "Table 1 didn't answer");
  return data as T;
}

/** Side work after the answer: never blocks the response, failures are logged without personal data. */
function later(ctx: Ctx, work: () => Promise<unknown>) {
  ctx.side.push(work);
}

interface Ctx {
  ix: Interaction;
  discordId: string;
  guildId: string;
  channelId: string;
  side: (() => Promise<unknown>)[];
  tel: Telemetry;
  distinct: string;
  linked: boolean;
  telemetry: Record<string, unknown>[];
}

// ---------------------------------------------------------------- commands

async function linkFlow(ctx: Ctx): Promise<Response> {
  const r = await rpc<{ linked: boolean; token?: string; expires_at?: string; display_name?: string }>("discord_link_start", { p_discord_id: ctx.discordId });
  if (r.linked) return ephemeral(`This Discord account is already linked to ${r.display_name ?? "your Table 1 account"}. Use /unlink to change that.`);
  ctx.telemetry.push({ event: "discord_link_started", via: "link" });
  return reply(linkMessage(r.token!, r.expires_at!));
}

/** The card drawn for this viewer (`me` says whether they're in). */
async function cardFor(ctx: Ctx, eventId: string): Promise<Card> {
  return await rpc<Card>("discord_event_card", { p_guild_id: ctx.guildId, p_event_id: eventId, p_discord_id: ctx.discordId });
}

/** After the first response made a public card: remember which message it is. */
function rememberPost(ctx: Ctx, eventId: string, kind: "event" | "results") {
  later(ctx, async () => {
    const id = await rest.originalMessageId(ctx.ix);
    if (id) await rpc("discord_event_posted", { p_event_id: eventId, p_kind: kind, p_message_id: id });
  });
}

async function eventCreate(ctx: Ctx, options: Parameters<typeof opt>[0]): Promise<Response> {
  const format = opt(options, "format") ?? "";
  const whenText = opt(options, "when");
  let tz = opt(options, "timezone");
  let startsAt: string | null = null;
  let localDate: string | null = null;
  if (whenText) {
    if (!tz) tz = (await rpc<{ timezone: string }>("discord_guild_timezone", { p_guild_id: ctx.guildId })).timezone;
    const w = parseWhen(whenText, tz);
    if (w === null) return ephemeral(`I couldn't read "${whenText}". Write the start as YYYY-MM-DD HH:MM, for example 2026-11-07 18:30, in ${tz} (change the zone with the timezone option or /settings timezone).`);
    if (w === "past") return ephemeral("That start is in the past.");
    if (w === "far") return ephemeral("Pick a start within a year.");
    startsAt = w.iso;
    localDate = w.localDate;
  }
  const card = await rpc<Card>("discord_event_create", {
    p_discord_id: ctx.discordId, p_guild_id: ctx.guildId, p_channel_id: ctx.channelId, p_format_name: format,
    p_name: opt(options, "name") ?? null, p_starts_at: startsAt, p_venue_name: opt(options, "venue") ?? null,
    p_capacity: opt<number>(options, "cap") ?? null, p_top_cut: opt<boolean>(options, "top8") ? 8 : 0,
    p_rounds: opt<number>(options, "rounds") ?? null, p_set_code: opt(options, "set") ?? null,
    p_cube_name: opt(options, "cube") ?? null, p_local_date: localDate,
    p_pods: opt<number>(options, "pods") ?? null, p_pod_pairing: opt(options, "pairing") ?? null,
  });
  ctx.telemetry.push({
    event: "discord_event_created", format, scheduled: Boolean(startsAt), capped: card.capacity != null,
    top_cut: card.top_cut, auto_rounds: card.auto_rounds, named: Boolean(opt(options, "name")),
    pods: card.pods ?? 0, pod_pairing: card.pod_pairing ?? null,
  });
  rememberPost(ctx, card.event_id, "event");
  return reply(eventMessage(card));
}

async function eventAttach(ctx: Ctx, link: string): Promise<Response> {
  const id = eventIdFrom(link);
  if (!id) return ephemeral("Pick one of your events from the list, or paste the event's table-1.site link.");
  const card = await rpc<Card>("discord_event_attach", { p_discord_id: ctx.discordId, p_guild_id: ctx.guildId, p_channel_id: ctx.channelId, p_event_id: id });
  ctx.telemetry.push({ event: "discord_event_attached" });
  rememberPost(ctx, card.event_id, "event");
  return reply(eventMessage(card));
}

async function eventList(ctx: Ctx): Promise<Response> {
  const rows = await rpc<{ event_id: string; name: string; format_label: string; starts_at: string | null; players: number; capacity: number | null }[]>(
    "discord_events_list", { p_guild_id: ctx.guildId, p_state: "open", p_query: null, p_limit: 25 });
  if (!rows.length) return ephemeral("No open events here yet. Make one with /event create.");
  const lines = rows.map((r) =>
    `• **${r.name.replace(/[*_`~|>\\]/g, "")}** · ${r.format_label} · ${r.players}${r.capacity ? `/${r.capacity}` : ""} players${r.starts_at ? ` · <t:${Math.floor(new Date(r.starts_at).getTime() / 1000)}:f>` : ""} · [open](https://table-1.site/s/${r.event_id})`
  );
  return ephemeral(lines.join("\n").slice(0, 1900));
}

async function signUpOrDrop(ctx: Ctx, action: "up" | "down", eventId: string, via: "button" | "command"): Promise<Response> {
  const fn = action === "up" ? "discord_event_sign_up" : "discord_event_drop";
  const r = await rpc<Card & { result: string; position?: number | null }>(fn, { p_discord_id: ctx.discordId, p_guild_id: ctx.guildId, p_event_id: eventId });
  const note = outcomeText(r.result, r, r.position);
  if (action === "up" && (r.result === "joined" || r.result === "waitlisted")) {
    ctx.telemetry.push({ event: "discord_event_signed_up", status: r.result, via });
  }
  if (action === "down" && (r.result === "left" || r.result === "left_waitlist")) {
    ctx.telemetry.push({ event: "discord_event_left", waitlist: r.result === "left_waitlist", via });
  }
  if (via === "button") {
    // The clicked message becomes the fresh card (its own kind: the public one keeps Sign up, a personal one shows
    // what now applies); the clicker gets a private note with their own button. The public card is redrawn when
    // Table 1 asks (refreshCard), as for a sign-up from the app.
    const personal = ((ctx.ix.message?.flags ?? 0) & EPHEMERAL) !== 0;
    later(ctx, () => rest.followUp(ctx.ix, { content: note, components: eventComponents(r, true), flags: EPHEMERAL }));
    return update(eventMessage(r, personal));
  }
  return ephemeral(note, eventMessage(r, true));
}

async function results(ctx: Ctx, eventId: string): Promise<Response> {
  const r = await rpc<Card & { final: boolean; organizer: boolean }>("discord_event_results", { p_discord_id: ctx.discordId, p_guild_id: ctx.guildId, p_event_id: eventId, p_channel_id: ctx.channelId });
  const [{ rows, teams }, photos] = await Promise.all([
    loadStandings(admin, eventId, isTeamFormat(r.format_name), r.format_name === "draft"),
    r.final ? deckPhotos(eventId) : Promise.resolve([] as PhotoRow[]),
  ]);
  const picks = pickPhotos(photos, rows);
  const players = new Set(picks.map((p) => p.photo.participant_id)).size;
  ctx.telemetry.push({ event: "discord_results_posted", final: r.final, players: rows.length, teams: teams?.length ?? 0, photos: picks.length, photo_players: players });
  rememberPost(ctx, eventId, "results");
  if (picks.length) later(ctx, () => postPhotos(ctx, r.name, picks, players, rows));
  return reply({ embeds: [resultsEmbed(r, rows, r.final, teams)], components: resultsComponents(r) });
}

/** The event's deck photos as players and organizers see them once it's over: hidden ones (moderation) left out. */
async function deckPhotos(eventId: string): Promise<PhotoRow[]> {
  const { data, error } = await admin.from("event_deck_photos").select("participant_id, path, note, turns, created_at")
    .eq("event_id", eventId).is("hidden_at", null);
  if (error) {
    console.error("discord-bot: deck photos", error.message);
    return [];
  }
  return (data ?? []) as PhotoRow[];
}

/** Each player's deck photo under the results, in standings order, as files on follow-up messages. A photo that
 *  can't be read from storage is left out (logged); nothing is posted when none can. */
async function postPhotos(ctx: Ctx, eventName: string, picks: PhotoPick[], players: number, rows: ResultRow[]) {
  const names = new Map(rows.map((r) => [r.participantId, r.name]));
  const read: { pick: PhotoPick; bytes: Uint8Array<ArrayBuffer>; size: number }[] = [];
  for (let i = 0; i < picks.length; i += 4) {
    const got = await Promise.all(picks.slice(i, i + 4).map(async (pick) => {
      const { data, error } = await admin.storage.from("deck-photos").download(pick.photo.path);
      if (error || !data) {
        console.error("discord-bot: deck photo download failed", error?.message ?? "");
        return null;
      }
      const bytes = uprightJpeg(new Uint8Array(await data.arrayBuffer()), pick.photo.turns);
      return { pick, bytes, size: bytes.length };
    }));
    for (const g of got) if (g) read.push(g);
  }
  let n = 0;
  for (const [m, batch] of batches(read).entries()) {
    const files = batch.map((b, i) => ({ name: photoFile(i), bytes: b.bytes, type: "image/jpeg" }));
    const embeds = batch.map((b, i) => photoEmbed(b.pick, files[i].name, names.get(b.pick.photo.participant_id) ?? null));
    const r = await rest.followUpFiles(ctx.ix, { ...(m === 0 ? { content: photosHeader(eventName, read.length, players) } : {}), embeds }, files);
    if (!r.ok) break;
    n += batch.length;
  }
  console.log(`discord-bot: deck photos posted ${n}/${picks.length}`);
}

async function deck(ctx: Ctx, listId: string, confirm: boolean): Promise<Response> {
  const d = await rpc<DeckPost & { needs_confirm: boolean; list_id: string; new_link?: boolean }>("discord_deck_share", { p_discord_id: ctx.discordId, p_list_id: listId, p_confirm: confirm });
  if (d.needs_confirm) {
    return ephemeral(`Posting **${d.name.replace(/[*_`~|>\\]/g, "")}** here makes a link anyone can open (you can stop sharing it any time under Sharing in Table 1). Post it?`, {
      components: [{ type: 1, components: [{ type: 2, style: 1, label: "Post the deck", custom_id: `t1:deck:${d.list_id}` }] }],
    });
  }
  const me = await rpc<{ display_name?: string }>("discord_me", { p_discord_id: ctx.discordId });
  ctx.telemetry.push({ event: "discord_deck_shared", format: d.format, new_link: Boolean(d.new_link) });
  return reply({ embeds: [deckEmbed(d, me.display_name ?? null, deckImageUrl(DECK_IMAGE, d))], components: deckComponents(d) });
}

/** /wants and /trades: the whole list or one card, behind the part's share link. With no live link the bot asks
 *  first; the confirm button then posts the whole list (the link it makes serves every later one-card post). */
async function part(ctx: Ctx, which: Part, query: string | null, confirm: boolean): Promise<Response> {
  const p = await rpc<PartPost & { needs_confirm: boolean; new_link?: boolean }>("discord_part", { p_discord_id: ctx.discordId, p_part: which, p_query: query, p_confirm: confirm });
  if (p.needs_confirm) return reply(partConfirmMessage(which));
  ctx.telemetry.push({ event: "discord_part_posted", part: which, single: Boolean(query), new_link: Boolean(p.new_link), rows: p.rows_total });
  return reply({ embeds: [partEmbed(p)], components: partComponents(p) });
}

async function card(ctx: Ctx, query: string): Promise<Response> {
  const h = await rpc<CardHit | null>("discord_card", { p_query: query });
  ctx.telemetry.push({ event: "discord_card_looked_up", found: Boolean(h) });
  if (!h) return ephemeral(`No card matches "${query.slice(0, 60)}".`);
  return reply({ embeds: [cardEmbed(h)] });
}

/** /meta matchups | winrates | deck: an Insights picture, public in the channel. No link needed: Insights is the same
 *  for everyone. The archetype list comes from the format's pack base (names as the apps show them). */
async function meta(ctx: Ctx, kind: MetaKind, options: Parameters<typeof opt>[0]): Promise<Response> {
  const ask = metaAsk(kind, options);
  if (!ask) return ephemeral(kind === "deck" ? "Pick an archetype from the list (after the format)." : "Pick a format from the list.");
  let archetype: string | null = null;
  if (ask.kind === "deck") {
    const base = await rpc<{ archetypes: { id: number; name: string }[] } | null>("meta_pack_base", { p_format: ask.format });
    archetype = base?.archetypes.find((x) => x.id === ask.a)?.name ?? null;
    if (!archetype) return ephemeral(`That isn't one of ${META_FORMATS[ask.format]}'s archetypes. Pick one from the list.`);
  }
  ctx.telemetry.push({ event: "discord_meta_posted", kind: ask.kind, format: ask.format, tier: ask.tier, days: ask.days });
  const picture = metaImageUrl(META_IMAGE, ask, ctx.ix.id);
  return reply({ embeds: [metaEmbed(ask, archetype, picture)], components: metaComponents(ask) });
}

/** /ranking: one of your rankings, its final top 50 / 100 or one color's list, as the apps' Top 100 picture, public in
 *  the channel. Drawing takes seconds, so the answer is Discord's "thinking…" and the post is put in place once
 *  ranking-image has drawn it; if it can't be drawn, the post is taken down and only the person is told. Nothing is
 *  shared on Table 1 by posting: Open in Table 1 is there only when the ranking is shared. */
async function ranking(ctx: Ctx, id: string, showValue: string | undefined): Promise<Response> {
  const p = await rpc<RankingPost>("discord_ranking", { p_discord_id: ctx.discordId, p_id: id });
  const show = rankShow(showValue, p.top);
  if (!show) return ephemeral("Pick Top 50, Top 100 or a color.");
  const v = rankingView(p, show);
  const empty = emptyText(p, show.job, v);
  if (empty || !v) return ephemeral(empty ?? "Nothing to post yet.");
  ctx.telemetry.push({ event: "discord_ranking_posted", show: show.job === "F" ? String(show.n) : show.job, kind: p.set_key ? "set" : "cube", done: v.done, places: v.rows.length });
  later(ctx, async () => {
    const png = await drawRanking(rankingImageAsk(p, v));
    if (png) {
      const r = await rest.editOriginal(ctx.ix, { embeds: [rankingEmbed(p, v)], components: rankingComponents(p, show.job) }, { name: RANKING_FILE, bytes: png, type: "image/png" });
      if (r.ok) return;
    }
    await rest.deleteOriginal(ctx.ix);
    await rest.followUp(ctx.ix, { content: "Couldn't draw the ranking's picture just now. Try /ranking again in a moment.", flags: EPHEMERAL });
  });
  return json({ type: ResponseType.DEFERRED });
}

/** The ranking's picture from ranking-image, or null (logged) when it can't be drawn. */
async function drawRanking(ask: ReturnType<typeof rankingImageAsk>): Promise<Uint8Array<ArrayBuffer> | null> {
  try {
    const r = await fetch(RANKING_IMAGE, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${env("SUPABASE_SERVICE_ROLE_KEY")}` },
      body: JSON.stringify(ask),
      signal: AbortSignal.timeout(60000),
    });
    if (!r.ok) {
      console.error(`discord-bot: ranking-image → ${r.status}`);
      await r.body?.cancel();
      return null;
    }
    return new Uint8Array(await r.arrayBuffer());
  } catch (e) {
    console.error("discord-bot: ranking-image failed", e instanceof Error ? e.message : e);
    return null;
  }
}

async function settingsTimezone(ctx: Ctx, zone: string): Promise<Response> {
  if (!canManageServer(ctx.ix)) return ephemeral("Only people with Manage Server can change this.");
  const r = await rpc<{ timezone: string }>("discord_guild_timezone", { p_guild_id: ctx.guildId, p_timezone: zone.trim() });
  return ephemeral(`Event times in this server are read in ${r.timezone}. Posted times show in each person's own zone.`);
}

// ---------------------------------------------------------------- autocomplete

async function autocomplete(ctx: Ctx, path: string, options: Parameters<typeof opt>[0]): Promise<Response> {
  const f = focused(options);
  const q = String(f?.value ?? "");
  if (f?.name === "timezone" || f?.name === "zone") return choices(zoneChoices(q));
  if (f?.name === "event") {
    const states = path === "event results" ? ["done", "open"] : ["open"];
    const out: { name: string; value: string }[] = [];
    const seen = new Set<string>();
    for (const state of states) {
      const rows = await rpc<{ event_id: string; name: string; format_label: string; players: number; status: string }[]>(
        "discord_events_list", { p_guild_id: ctx.guildId, p_state: state, p_query: q || null, p_limit: 25 });
      for (const r of rows) {
        seen.add(r.event_id);
        out.push({ name: `${r.name} · ${r.format_label} · ${r.players} players${state === "done" ? " · finished" : ""}`, value: r.event_id });
      }
    }
    // Results: your own events too (run or played in), finished ones first, even when the bot never posted them.
    if (path === "event results") {
      try {
        for (const state of ["done", "open"]) {
          const mine = await rpc<{ event_id: string; name: string; format_label: string; players: number; status: string; role: string }[]>(
            "discord_my_events", { p_discord_id: ctx.discordId, p_query: q || null, p_limit: 25, p_state: state });
          for (const r of mine) {
            if (seen.has(r.event_id)) continue;
            seen.add(r.event_id);
            out.push({ name: `${r.name} · ${r.format_label} · ${r.players} players · ${r.role === "organizer" ? "you ran it" : "you played"}${state === "done" ? " · finished" : ""}`, value: r.event_id });
          }
        }
      } catch (e) {
        if (!(e instanceof Refused && e.code === "28000")) throw e;
      }
    }
    return choices(out);
  }
  if (f?.name === "link" && path === "event post") {
    try {
      const rows = await rpc<{ event_id: string; name: string; format_label: string; status: string; role: string; players: number }[]>(
        "discord_my_events", { p_discord_id: ctx.discordId, p_query: q || null, p_limit: 25 });
      const out = rows.map((r) => ({ name: `${r.name} · ${r.format_label} · ${r.players} players · ${r.role === "organizer" ? "you run it" : "you play"}`, value: r.event_id }));
      if (q && eventIdFrom(q)) out.unshift({ name: `Use this link`, value: eventIdFrom(q)! });
      return choices(out);
    } catch (e) {
      if (e instanceof Refused && e.code === "28000") return choices([{ name: "Link your Table 1 account first: /link", value: "unlinked" }]);
      throw e;
    }
  }
  if (f?.name === "card" && (path === "wants" || path === "trades")) {
    try {
      const names = await rpc<string[]>("discord_part_names", { p_discord_id: ctx.discordId, p_part: path === "wants" ? "wants" : "for_trade", p_query: q || null, p_limit: 25 });
      return choices(names.map((n) => ({ name: n, value: n })));
    } catch (e) {
      if (e instanceof Refused && e.code === "28000") return choices([{ name: "Link your Table 1 account first: /link", value: "unlinked" }]);
      throw e;
    }
  }
  if (f?.name === "archetype" && path === "meta deck") {
    const format = String(opt(options, "format") ?? "");
    if (!META_FORMATS[format]) return choices([{ name: "Pick a format first", value: "none" }]);
    const base = await rpc<{ archetypes: { id: number; name: string }[] } | null>("meta_pack_base", { p_format: format });
    const needle = q.trim().toLowerCase();
    const list = (base?.archetypes ?? []).filter((x) => !needle || x.name.toLowerCase().includes(needle))
      .sort((x, y) => Number(x.id === 0) - Number(y.id === 0) || x.name.localeCompare(y.name));
    return choices(list.map((x) => ({ name: x.name, value: String(x.id) })));
  }
  if (f?.name === "ranking" && path === "ranking") {
    try {
      const rows = await rpc<RankingRow[]>("discord_my_rankings", { p_discord_id: ctx.discordId, p_query: q || null, p_limit: 25 });
      if (!rows.length) return choices([{ name: q ? "None of your rankings match" : "No rankings yet: rank a cube or set on Table 1", value: "none" }]);
      return choices(rows.map((r) => ({ name: rankingChoice(r), value: r.id })));
    } catch (e) {
      if (e instanceof Refused && e.code === "28000") return choices([{ name: "Link your Table 1 account first: /link", value: "unlinked" }]);
      throw e;
    }
  }
  if (f?.name === "deck") {
    try {
      const rows = await rpc<{ list_id: string; name: string; format: string; cards: number }[]>("discord_my_decks", { p_discord_id: ctx.discordId, p_query: q || null, p_limit: 25 });
      return choices(rows.map((r) => ({ name: `${r.name} · ${r.format} · ${r.cards} cards`, value: r.list_id })));
    } catch (e) {
      if (e instanceof Refused && e.code === "28000") return choices([{ name: "Link your Table 1 account first: /link", value: "unlinked" }]);
      throw e;
    }
  }
  return choices([]);
}

// ---------------------------------------------------------------- routing

async function route(ctx: Ctx): Promise<Response> {
  const ix = ctx.ix;
  if (ix.type === InteractionType.COMPONENT) {
    const b = parseButtonId(ix.data?.custom_id);
    if (!b) return ephemeral("That button is from an older card. Run /event show for a fresh one.");
    if (b.action === "link") return await linkFlow(ctx);
    if (b.action === "deck" && b.id) return await deck(ctx, b.id, true);
    if (b.action === "wants" || b.action === "trades") return await part(ctx, b.action === "wants" ? "wants" : "for_trade", null, true);
    if ((b.action === "up" || b.action === "down") && b.id) return await signUpOrDrop(ctx, b.action, b.id, "button");
    return ephemeral("That button is from an older card.");
  }
  const { path, options } = commandPath(ix);
  if (ix.type === InteractionType.AUTOCOMPLETE) return await autocomplete(ctx, path, options);
  switch (path) {
    case "help":
      ctx.telemetry.push({ event: "discord_help_viewed" });
      return reply({ embeds: [helpEmbed()], flags: EPHEMERAL });
    case "link":
      return await linkFlow(ctx);
    case "unlink": {
      const r = await rpc<{ unlinked: boolean; via: string | null }>("discord_unlink", { p_discord_id: ctx.discordId });
      if (r.unlinked) ctx.telemetry.push({ event: "discord_unlinked", via: "link" });
      if (r.via === "sign_in") return ephemeral("You sign in to Table 1 with this Discord account, so there's nothing to unlink. Manage sign-in methods in Table 1 → Account.");
      return ephemeral(r.unlinked ? "Unlinked. The bot no longer acts for your Table 1 account." : "This Discord account wasn't linked.");
    }
    case "event create":
      return await eventCreate(ctx, options);
    case "event post": {
      const v = opt(options, "link") ?? "";
      if (v === "unlinked") return reply(needLinkMessage("post an event"));
      return await eventAttach(ctx, v);
    }
    case "wants":
    case "trades": {
      const q = opt(options, "card") ?? null;
      if (q === "unlinked") return reply(needLinkMessage(path === "wants" ? "post your wants" : "post your cards for trade"));
      return await part(ctx, path === "wants" ? "wants" : "for_trade", q, false);
    }
    case "event list":
      return await eventList(ctx);
    case "event show": {
      const id = opt(options, "event") ?? "";
      if (!eventIdFrom(id)) return ephemeral("Pick an event from the list.");
      const c = await cardFor(ctx, id);
      return reply({ ...eventMessage(c, true), flags: EPHEMERAL });
    }
    case "event signup":
    case "event drop": {
      const id = opt(options, "event") ?? "";
      if (!eventIdFrom(id)) return ephemeral("Pick an event from the list.");
      return await signUpOrDrop(ctx, path === "event signup" ? "up" : "down", id, "command");
    }
    case "event results": {
      const id = opt(options, "event") ?? "";
      if (!eventIdFrom(id)) return ephemeral("Pick an event from the list.");
      return await results(ctx, id);
    }
    case "settings timezone":
      return await settingsTimezone(ctx, opt(options, "zone") ?? "");
    case "deck": {
      const id = opt(options, "deck") ?? "";
      if (id === "unlinked") return reply(needLinkMessage("post a deck"));
      if (!eventIdFrom(id)) return ephemeral("Pick a deck from the list.");
      return await deck(ctx, id, false);
    }
    case "card":
      return await card(ctx, opt(options, "name") ?? "");
    case "ranking": {
      const id = opt(options, "ranking") ?? "";
      if (id === "unlinked") return reply(needLinkMessage("post a ranking"));
      if (!eventIdFrom(id)) return ephemeral("Pick one of your rankings from the list.");
      return await ranking(ctx, id, opt(options, "show"));
    }
    case "meta matchups":
    case "meta winrates":
    case "meta deck":
      return await meta(ctx, path.slice(5) as MetaKind, options);
  }
  return ephemeral("I don't know that command. Try /help.");
}

function refusal(e: Refused, path: string): Response {
  if (e.code === "28000") return reply(needLinkMessage(path.startsWith("event") ? "join or run events" : "do that"));
  return ephemeral(e.message);
}

// ---------------------------------------------------------------- the card stays current

/** Table 1 asks (a trigger through pg_net, after commit) when an event with a posted card changed, from anywhere:
 *  the bot, the app, the web, the sign-up link. The card is read now, so it shows the latest state. */
async function refreshCard(req: Request): Promise<Response> {
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: req.headers.get("x-t1-secret") ?? "" });
  if (!ok) return json({ error: "Forbidden" }, 403);
  const { refresh } = await req.json().catch(() => ({})) as { refresh?: string };
  if (!refresh || !/^[0-9a-f-]{36}$/i.test(refresh)) return json({ error: "refresh: an event id" }, 400);
  const card = await rpc<Card | null>("discord_card_current", { p_event_id: refresh });
  if (!card?.channel_id || !card.message_id) return json({ edited: false });
  const r = await rest.editMessage(card.channel_id, card.message_id, eventMessage(card));
  // Unknown Message / Channel: the card was deleted, so stop asking for it (a fresh /event post makes a new one).
  if (r.status === 404) await rpc("discord_card_lost", { p_event_id: refresh, p_message_id: card.message_id });
  return json({ edited: r.ok, status: r.status });
}

// ---------------------------------------------------------------- the endpoint

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Table 1 for Discord", { status: 405 });
  if (req.headers.has("x-t1-secret")) return await refreshCard(req);
  const body = await req.text();
  const ok = await verifyInteraction(PUBLIC_KEY, req.headers.get("x-signature-ed25519"), req.headers.get("x-signature-timestamp"), body);
  if (!ok) return new Response("invalid request signature", { status: 401 });
  let ix: Interaction;
  try {
    ix = JSON.parse(body);
  } catch {
    return new Response("bad request", { status: 400 });
  }
  if (ix.type === InteractionType.PING) return json({ type: ResponseType.PONG });

  const t0 = performance.now();
  const discordId = userId(ix);
  const guildId = ix.guild_id ?? "";
  const channelId = ix.channel_id ?? "";
  const tel = new Telemetry(env("POSTHOG_KEY"), env("POSTHOG_HOST", "https://us.i.posthog.com"), { platform: "discord", environment: ENVIRONMENT });
  const ctx: Ctx = { ix, discordId, guildId, channelId, side: [], tel, distinct: "", linked: false, telemetry: [] };
  const { path } = commandPath(ix);
  const kind = ix.type === InteractionType.COMPONENT ? "button" : ix.type === InteractionType.AUTOCOMPLETE ? "autocomplete" : "command";
  const command = ix.type === InteractionType.COMPONENT ? `button ${parseButtonId(ix.data?.custom_id)?.action ?? "?"}` : path;

  let res: Response;
  let outcome: "ok" | "refused" | "error" = "ok";
  if (!isSnowflake(discordId) || !isSnowflake(guildId) || !isSnowflake(channelId)) {
    res = ephemeral("Table 1 works inside a server channel.");
    outcome = "refused";
  } else {
    try {
      res = await route(ctx);
    } catch (e) {
      if (e instanceof Refused && e.code && e.code !== "P0001" && !/^5|^XX|^08|^57/.test(e.code)) {
        res = refusal(e, path);
        outcome = "refused";
      } else {
        console.error("discord-bot:", command, e instanceof Error ? `${(e as Refused).code ?? ""} ${e.message}` : e);
        res = ephemeral("Table 1 didn't answer. Try again in a moment.");
        outcome = "error";
      }
    }
  }

  // Telemetry rides after the answer: distinct id is the Table 1 account when linked, else a salted hash.
  if (tel.enabled && ix.type !== InteractionType.AUTOCOMPLETE) {
    later(ctx, async () => {
      let distinct = await hashId(discordId || "0", SALT);
      let linked = false;
      try {
        const me = await rpc<{ linked: boolean; user_id?: string }>("discord_me", { p_discord_id: discordId });
        if (me.linked && me.user_id) {
          distinct = me.user_id;
          linked = true;
        }
      } catch { /* telemetry never fails the interaction */ }
      tel.capture(distinct, "discord_interaction", { kind, command, linked, outcome, duration_ms: Math.round(performance.now() - t0) });
      for (const t of ctx.telemetry) {
        const { event, ...props } = t;
        tel.capture(distinct, String(event), props);
      }
      await tel.flush();
    });
  }
  const side = Promise.allSettled(ctx.side.map((f) => f().catch((e) => console.error("discord-bot: side work failed", e instanceof Error ? e.message : e))));
  // deno-lint-ignore no-explicit-any
  const runtime = (globalThis as any).EdgeRuntime;
  if (runtime?.waitUntil) runtime.waitUntil(side);
  return res;
});
