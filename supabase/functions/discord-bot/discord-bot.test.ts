import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  type Card, canManageServer, cardEmbed, commandPath, deckEmbed, deckImageUrl, eventComponents, eventEmbed, eventIdFrom, helpEmbed, HELP,
  COMMANDS, podsLine, metaAsk, metaComponents, metaEmbed, metaImageUrl, outcomeText, parseButtonId, parseWhen, partConfirmMessage, partEmbed, resultsEmbed, statusLine, validZone, zoneChoices,
} from "./embeds.ts";
import { DiscordRest } from "./discord.ts";
import { isTeamFormat, podCode, podCodes, toRows, toTeamRows } from "./standings.ts";
import { cleanProperties, hashId, Telemetry } from "./telemetry.ts";
import { hexToBytes, verifyInteraction } from "./verify.ts";

const hex = (b: ArrayBuffer | Uint8Array) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");

async function keyPair() {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pub = hex(await crypto.subtle.exportKey("raw", kp.publicKey));
  const sign = async (timestamp: string, body: string) =>
    hex(await crypto.subtle.sign({ name: "Ed25519" }, kp.privateKey, new TextEncoder().encode(timestamp + body)));
  return { pub, sign };
}

Deno.test("signatures: only a fresh, correctly signed request passes", async () => {
  const { pub, sign } = await keyPair();
  const other = await keyPair();
  const now = Date.now();
  const ts = String(Math.floor(now / 1000));
  const body = JSON.stringify({ type: 1 });
  const sig = await sign(ts, body);
  assert(await verifyInteraction(pub, sig, ts, body, now));
  assert(!(await verifyInteraction(pub, sig, ts, body + " ", now)), "a changed body fails");
  assert(!(await verifyInteraction(pub, sig, String(Number(ts) + 1), body, now)), "a changed timestamp fails");
  assert(!(await verifyInteraction(other.pub, sig, ts, body, now)), "another key fails");
  assert(!(await verifyInteraction(pub, await other.sign(ts, body), ts, body, now)), "a signature from another key fails");
  assert(!(await verifyInteraction(pub, sig, ts, body, now + 6 * 60 * 1000)), "six minutes later it's a replay");
  assert(!(await verifyInteraction(pub, sig, ts, body, now - 6 * 60 * 1000)), "six minutes early fails too");
  assert(!(await verifyInteraction(pub, null, ts, body, now)));
  assert(!(await verifyInteraction(pub, sig, null, body, now)));
  assert(!(await verifyInteraction("", sig, ts, body, now)));
  assert(!(await verifyInteraction(pub, "zz" + sig.slice(2), ts, body, now)), "bad hex never throws");
  assert(!(await verifyInteraction(pub, sig.slice(2), ts, body, now)), "a short signature fails");
  assertThrows(() => hexToBytes("abc"));
});

Deno.test("command paths and options", () => {
  const sub = commandPath({ type: 2, id: "1", token: "t", application_id: "a", data: { name: "event", options: [{ name: "create", type: 1, options: [{ name: "format", type: 3, value: "modern" }] }] } });
  assertEquals(sub.path, "event create");
  assertEquals(sub.options[0].value, "modern");
  const plain = commandPath({ type: 2, id: "1", token: "t", application_id: "a", data: { name: "card", options: [{ name: "name", type: 3, value: "Opt" }] } });
  assertEquals([plain.path, plain.options.length], ["card", 1]);
});

Deno.test("button ids round-trip and refuse anything else", () => {
  const id = "0a1b2c3d-0000-4000-8000-000000000001";
  assertEquals(parseButtonId(`t1:up:${id}`), { action: "up", id });
  assertEquals(parseButtonId(`t1:down:${id}`), { action: "down", id });
  assertEquals(parseButtonId("t1:link"), { action: "link", id: null });
  assertEquals(parseButtonId(`t1:deck:${id}`), { action: "deck", id });
  assertEquals(parseButtonId("t1:up:not-an-id"), null);
  assertEquals(parseButtonId("t1:wants"), { action: "wants", id: null });
  assertEquals(parseButtonId("t1:trades"), { action: "trades", id: null });
  assertEquals(parseButtonId("t1:nuke:" + id), null);
  assertEquals(parseButtonId(undefined), null);
  assertEquals(parseButtonId("t1:up:" + id + ";drop table"), null);
});

Deno.test("event ids from pasted links", () => {
  const id = "0a1b2c3d-0000-4000-8000-000000000001";
  assertEquals(eventIdFrom(`https://table-1.site/s/${id}`), id);
  assertEquals(eventIdFrom(`https://www.table-1.site/e/${id.toUpperCase()}?x=1`), id);
  assertEquals(eventIdFrom(id), id);
  assertEquals(eventIdFrom("https://example.com/s/" + id), null);
  assertEquals(eventIdFrom("ABCD"), null);
});

Deno.test("when: wall-clock time in a zone becomes an instant, DST included", () => {
  const now = Date.parse("2026-10-29T12:00:00Z");
  const sthlm = parseWhen("2026-11-07 18:30", "Europe/Stockholm", now);
  assertEquals(sthlm, { iso: "2026-11-07T17:30:00.000Z", localDate: "2026-11-07" });
  const ny = parseWhen("2026-11-07T18:30", "America/New_York", now);
  assertEquals((ny as { iso: string }).iso, "2026-11-07T23:30:00.000Z");
  // Before the US clocks change (1 Nov 2026) New York is UTC-4.
  assertEquals((parseWhen("2026-10-30 18.30", "America/New_York", now) as { iso: string }).iso, "2026-10-30T22:30:00.000Z");
  assertEquals(parseWhen("2026-11-07 18:30", "UTC", now), { iso: "2026-11-07T18:30:00.000Z", localDate: "2026-11-07" });
  assertEquals(parseWhen("tomorrow", "UTC", now), null);
  assertEquals(parseWhen("2026-13-01 10:00", "UTC", now), null);
  assertEquals(parseWhen("2026-11-07 18:30", "Nowhere/Land", now), null);
  assertEquals(parseWhen("2026-10-29 09:00", "UTC", now), "past");
  assertEquals(parseWhen("2026-10-29 11:30", "UTC", now) !== "past", true, "an hour's grace");
  assertEquals(parseWhen("2027-12-01 10:00", "UTC", now), "far");
  assert(validZone("Europe/Stockholm") && validZone("UTC") && !validZone("Nowhere/Land") && !validZone("+02"));
  assertEquals(zoneChoices("stock")[0], { name: "Europe/Stockholm", value: "Europe/Stockholm" });
  assertEquals(zoneChoices("Asia/Kathmandu")[0].value, "Asia/Kathmandu", "a valid zone not in the list is offered");
  assert(zoneChoices("").length <= 25);
});

Deno.test("Manage Server permission bit", () => {
  const ix = (p?: string) => ({ type: 2, id: "1", token: "t", application_id: "a", member: { user: { id: "100001" }, permissions: p } });
  assert(canManageServer(ix("32")));
  assert(canManageServer(ix("8")));
  assert(canManageServer(ix(String((1n << 40n) | 32n))));
  assert(!canManageServer(ix("2048")));
  assert(!canManageServer(ix(undefined)));
  assert(!canManageServer(ix("abc")));
});

const card: Card = {
  event_id: "0a1b2c3d-0000-4000-8000-000000000001", name: "Friday **Modern**", format_label: "Modern", set_name: null, cube_name: null,
  status: "setup", starts_at: "2026-11-07T17:30:00Z", venue_name: "The Shop", capacity: 8, top_cut: 8, auto_rounds: true,
  number_of_rounds: 3, current_round: 0, short_code: "AB12", organizer_name: "Ana", sign_up: "open", players: 3,
  player_names: ["Ana", "Bea @everyone", "Cal_"], waitlist: 0, waitlist_names: [], link: "https://table-1.site/s/0a1b2c3d-0000-4000-8000-000000000001",
};

Deno.test("the event card: parameters, who's in, escaped names, viewer-local time, the link", () => {
  const e = eventEmbed(card);
  assertEquals(e.title, "Friday \\*\\*Modern\\*\\*");
  assertEquals(e.url, card.link);
  assert(e.description.includes("<t:1794072600:F>"), "Discord renders the time in each viewer's zone");
  assert(e.description.includes("The Shop") && e.description.includes("Organizer: Ana"));
  const players = e.fields[0];
  assertEquals(players.name, "Players · 3/8");
  assert(players.value.includes("Bea @​everyone"), "mentions are defused");
  assert(players.value.includes("Cal\\_"));
  assertEquals(e.fields.find((f) => f.name === "Top cut")?.value, "Top 8");
  assertEquals(e.fields.find((f) => f.name === "Join code")?.value, "`AB12`");
  assertEquals(e.footer.text, "Table 1 · Sign-ups open");
  const buttons = eventComponents(card)[0].components;
  assertEquals(buttons.map((b) => b.label), ["Sign up", "Open in Table 1"], "the public card offers Sign up only");
  assertEquals(buttons[0].custom_id, `t1:up:${card.event_id}`);
  assertEquals(buttons[1].url, card.link);
  assert(!JSON.stringify(e).includes("guild"), "no Discord ids in the embed");
});

Deno.test("the card at 30 players, full, closed and finished", () => {
  const many = { ...card, players: 30, capacity: 30, sign_up: "full" as const, player_names: Array.from({ length: 30 }, (_, i) => `P${i + 1}`), waitlist: 2, waitlist_names: ["W1", "W2"] };
  const e = eventEmbed(many);
  assert(e.fields[0].value.endsWith("and 5 more"));
  assertEquals(e.fields[1].name, "Waitlist · 2");
  assertEquals(statusLine(many), "Full · waitlist open");
  const closed = { ...card, sign_up: "closed" as const, status: "in_progress", current_round: 2 };
  assertEquals(statusLine(closed), "Round 2 of 3");
  assertEquals(eventComponents(closed)[0].components.map((b) => b.label), ["Open in Table 1"], "closed: the link only");
  assertEquals(eventComponents({ ...closed, me: "player" }, true)[0].components.map((b) => b.label), ["Open in Table 1"]);
  assertEquals(eventEmbed(closed).fields.some((f) => f.name === "Join code"), false);
  assertEquals(statusLine({ ...card, status: "completed", sign_up: "closed" }), "Finished");
});

Deno.test("a personal card shows the one button that applies to its viewer", () => {
  const labels = (c: Card) => eventComponents(c, true)[0].components.map((b) => b.label);
  assertEquals(labels({ ...card, me: null }), ["Sign up", "Open in Table 1"]);
  assertEquals(labels({ ...card }), ["Sign up", "Open in Table 1"], "unlinked or unknown: Sign up");
  assertEquals(labels({ ...card, me: "player" }), ["Drop", "Open in Table 1"]);
  assertEquals(labels({ ...card, me: "waitlisted" }), ["Leave the waitlist", "Open in Table 1"]);
  assertEquals(eventComponents({ ...card, me: "player" }, true)[0].components[0].custom_id, `t1:down:${card.event_id}`);
  assertEquals(eventComponents({ ...card, me: "player" })[0].components[0].label, "Sign up", "the public card doesn't change with the viewer");
});

Deno.test("what the clicker is told", () => {
  assertEquals(outcomeText("joined", card), "You're in · Friday \\*\\*Modern\\*\\*");
  assertEquals(outcomeText("waitlisted", card, 2), "Friday \\*\\*Modern\\*\\* is full. You're number 2 on the waitlist.");
  assertEquals(outcomeText("left", card), "You left · Friday \\*\\*Modern\\*\\*");
  assertEquals(outcomeText("not_in", card), "You weren't in · Friday \\*\\*Modern\\*\\*");
});

Deno.test("results: ranks, records, points, the winner, the link", () => {
  const rows = toRows([
    { rank: 1, swissRank: 2, playoff: "winner", participantId: "p1", displayName: "Bea", status: "active", matchWins: 4, matchLosses: 0, matchDraws: 0, byes: 1, matchPoints: 15, matchesPlayed: 4, gamePoints: 0, gamesPlayed: 0, opponentIds: [], matchWinPct: 1, gameWinPct: 1, opponentMatchWinPct: 0.5, opponentGameWinPct: 0.5 },
    { rank: 2, swissRank: 1, playoff: "final", participantId: "p2", displayName: "Ana", status: "active", matchWins: 4, matchLosses: 1, matchDraws: 0, byes: 0, matchPoints: 12, matchesPlayed: 5, gamePoints: 0, gamesPlayed: 0, opponentIds: [], matchWinPct: 0.8, gameWinPct: 0.6, opponentMatchWinPct: 0.5, opponentGameWinPct: 0.5 },
    { rank: 3, swissRank: 3, playoff: null, participantId: "p3", displayName: "Cal", status: "dropped", matchWins: 1, matchLosses: 2, matchDraws: 1, byes: 0, matchPoints: 4, matchesPlayed: 4, gamePoints: 0, gamesPlayed: 0, opponentIds: [], matchWinPct: 0.3, gameWinPct: 0.4, opponentMatchWinPct: 0.5, opponentGameWinPct: 0.5 },
  ]);
  const done = { ...card, status: "completed", sign_up: "closed" as const };
  const e = resultsEmbed(done, rows, true);
  assertEquals(e.title, "Results · Friday \\*\\*Modern\\*\\*");
  assertEquals(e.description?.split("\n"), ["🏆 Bea · 5-0 · 15 pts", "2. Ana · 4-1 · 12 pts", "3. Cal (dropped) · 1-2-1 · 4 pts"]);
  assertEquals(e.footer.text, "Table 1 · Final standings · 3 players");
  assertEquals(e.url, card.link);
  const many = Array.from({ length: 20 }, (_, i) => ({ ...rows[2], rank: i + 1, name: `P${i + 1}` }));
  assert(resultsEmbed(done, many, true).description?.endsWith("…and 12 more"));
  const sofar = resultsEmbed({ ...card, status: "in_progress", current_round: 2 }, rows, false);
  assertEquals(sofar.title, "Standings so far · Friday \\*\\*Modern\\*\\*");
  assert(sofar.description?.startsWith("1. Bea"), "no trophy before the end");
  assertEquals(sofar.footer.text, "Table 1 · After round 2 of 3");
});

Deno.test("drafts with pods: the card's Pods line, before and after the draw, and nothing for one pod or other formats", () => {
  const draft = { ...card, format_name: "draft", format_label: "Draft", pod_pairing: "pod" as const, pods: null, pod_sizes: null };
  assertEquals(podsLine({ ...draft, players: 6 }), null, "an ordinary draft of up to 8 says nothing");
  assertEquals(podsLine({ ...draft, players: 17 }), "3 pods · 6, 6, 5 · paired inside pods", "automatic, before the draw");
  assertEquals(podsLine({ ...draft, players: 15, pods: 2, pod_pairing: "cross" }), "2 pods · 8, 7 · Swiss across pods");
  assertEquals(podsLine({ ...draft, players: 0, pods: 2 }), "2 pods · paired inside pods", "picked before anyone signed up");
  assertEquals(podsLine({ ...draft, players: 12, pods: 1 }), "1 pod · 12", "one pod, asked for");
  assertEquals(podsLine({ ...draft, status: "seated", players: 16, pods: 2, pod_sizes: [9, 7] }), "2 pods · 9, 7 · paired inside pods",
    "seated: the pods as drawn and moved by hand, not the plan");
  assertEquals(podsLine({ ...card, format_name: "modern", players: 30 }), null, "constructed");
  assertEquals(podsLine({ ...card, format_name: "team_draft", players: 8 }), null, "team drafts are one pod");
  const e = eventEmbed({ ...draft, players: 15, pods: 2 });
  assertEquals(e.fields.find((f) => f.name === "Pods")?.value, "2 pods · 8, 7 · paired inside pods");
  assertEquals(eventEmbed(card).fields.some((f) => f.name === "Pods"), false);
});

Deno.test("drafts with pods: results tag each player's pod when there are two or more", () => {
  const p = (id: string, podId: string | null, seat: number | null = 1) =>
    ({ id, eventId: "e", podId, displayName: id, seat, status: "active" as const, droppedInRound: null });
  const pods = [{ id: "b", name: "Pod 2", display_order: 1 }, { id: "a", name: "Pod 1", display_order: 0 }, { id: "c", name: "Pod 3", display_order: 2 }];
  const codes = podCodes([p("x", "a"), p("y", "b"), p("z", "c", null)], pods);
  assertEquals([...codes.entries()], [["x", "P1"], ["y", "P2"]], "an empty pod (nobody seated) isn't counted or tagged");
  assertEquals(podCodes([p("x", "a"), p("y", "a")], pods).size, 0, "one pod in play: no tags");
  assertEquals(podCode("Pod 7", 0), "P7");
  assertEquals(podCode("Main table", 1), "P2");
  const standing = (participantId: string, rank: number) => ({ rank, swissRank: rank, playoff: null, participantId, displayName: participantId.toUpperCase(),
    status: "active" as const, matchWins: 3 - rank, matchLosses: rank - 1, matchDraws: 0, byes: 0, matchPoints: 3 * (3 - rank), matchesPlayed: 2,
    gamePoints: 0, gamesPlayed: 0, opponentIds: [], matchWinPct: 0.5, gameWinPct: 0.5, opponentMatchWinPct: 0.5, opponentGameWinPct: 0.5 });
  const rows = toRows([standing("x", 1), standing("y", 2)], codes);
  const e = resultsEmbed({ ...card, format_name: "draft", status: "completed", sign_up: "closed" }, rows, true);
  assertEquals(e.description?.split("\n"), ["🏆 X · P1 · 2-0 · 6 pts", "2. Y · P2 · 1-1 · 3 pts"]);
  assertEquals(toRows([standing("x", 1)])[0].pod, null, "no pods given: no tag");
});

Deno.test("/event create offers pods and pairing for drafts", () => {
  // deno-lint-ignore no-explicit-any
  const ev = (COMMANDS as any[]).find((c) => c.name === "event");
  // deno-lint-ignore no-explicit-any
  const create = (ev.options as any[]).find((o) => o.name === "create");
  // deno-lint-ignore no-explicit-any
  const byName = new Map((create.options as any[]).map((o) => [o.name, o]));
  assertEquals([byName.get("pods")?.min_value, byName.get("pods")?.max_value], [1, 16]);
  // deno-lint-ignore no-explicit-any
  assertEquals(byName.get("pairing")?.choices.map((c: any) => c.value), ["pod", "cross"]);
  assert(create.options.length <= 25, "Discord allows 25 options");
});

Deno.test("team results: each team on its own, members best first under it", () => {
  const member = (displayName: string, matchWins: number, matchLosses: number, status: "active" | "dropped" = "active") =>
    ({ participantId: displayName, displayName, slot: null, matchWins, matchLosses, matchDraws: 0, status });
  const base = { draws: 0, byes: 0, gameWinPct: 0.5, opponentTeamIds: [] };
  const teams = toTeamRows([
    { ...base, teamId: "t1", name: "Team *Red*", rank: 1, points: 6, wins: 2, losses: 1, matchWins: 5, members: [member("Ana", 3, 0), member("Ben", 1, 2), member("Cal", 1, 2)] },
    { ...base, teamId: "t2", name: "Team Blue", rank: 2, points: 3, wins: 1, losses: 2, matchWins: 4, members: [member("Dee", 2, 1), member("Eli", 1, 2), member("Fay", 1, 2, "dropped")] },
  ]);
  const done = { ...card, format_name: "team_draft", status: "completed", sign_up: "closed" as const };
  const players = toRows([]).concat(Array.from({ length: 6 }, (_, i) => ({ rank: i + 1, name: `P${i}`, wins: 0, losses: 0, draws: 0, points: 0, dropped: false })));
  const e = resultsEmbed(done, players, true, teams);
  assertEquals(e.title, "Results · Friday \\*\\*Modern\\*\\*");
  assertEquals(e.description, undefined, "no player list for a team event");
  assertEquals(e.fields?.map((f) => f.name), ["🏆 Team \\*Red\\* · 2-1 · 6 pts · 5 match wins", "2. Team Blue · 1-2 · 3 pts · 4 match wins"]);
  assertEquals(e.fields?.[0].value.split("\n"), ["Ana · 3-0", "Ben · 1-2", "Cal · 1-2"]);
  assertEquals(e.fields?.[1].value.split("\n"), ["Dee · 2-1", "Eli · 1-2", "Fay (dropped) · 1-2"]);
  assertEquals(e.footer.text, "Table 1 · Final standings · 2 teams · 6 players");
  const sofar = resultsEmbed({ ...done, status: "in_progress", current_round: 2 }, players, false, teams);
  assert(sofar.fields?.[0].name.startsWith("1. Team"), "no trophy before the end");
  assertEquals(sofar.footer.text, "Table 1 · After round 2 of 3");
  assert(isTeamFormat("team_draft") && isTeamFormat("team_sealed") && !isTeamFormat("draft") && !isTeamFormat(null));
  assert(resultsEmbed(done, players, true, []).description?.startsWith("🏆 P0"), "no teams: the players' list");
});

Deno.test("deck and card posts", () => {
  const d = deckEmbed({ name: "Burn", format: "modern", main: 60, side: 15, spice: { score: 12, word: "Tuned" }, url: "https://table-1.site/l/abc", hero: { card_id: "c1000000-0000-0000-0000-000000000001", image_ts: 1700000000 } }, "Ana");
  assertEquals(d.description, "Modern · 60 main · 15 side\nSpice 12 · Tuned");
  assertEquals(d.thumbnail?.url, "https://cards.scryfall.io/normal/front/c/1/c1000000-0000-0000-0000-000000000001.jpg?1700000000");
  assertEquals(d.footer.text, "Table 1 · Ana's deck");
  const post = { name: "Burn", format: "modern", main: 60, side: 15, spice: null, url: "https://table-1.site/l/Ab3_-x9QzLm2pR7tKw4vYc", token: "Ab3_-x9QzLm2pR7tKw4vYc", version: 7, hero: { card_id: "c1000000-0000-0000-0000-000000000001", image_ts: 1 } };
  const pictureUrl = deckImageUrl("https://x.supabase.co/functions/v1/deck-image/", post);
  assertEquals(pictureUrl, "https://x.supabase.co/functions/v1/deck-image/Ab3_-x9QzLm2pR7tKw4vYc.png?v=7");
  const withPicture = deckEmbed(post, "Ana", pictureUrl);
  assertEquals(withPicture.image?.url, pictureUrl, "the whole deck is the embed's picture");
  assertEquals(withPicture.thumbnail, undefined, "no hero thumbnail beside the picture");
  assertEquals(deckImageUrl("https://x", { ...post, token: "short" }), null);
  assertEquals(deckImageUrl("https://x", { ...post, token: undefined }), null);
  const c = cardEmbed({ oracle_id: "o1", name: "Lightning Bolt", mana_cost: "{R}", type_line: "Instant", card_id: "c1000000-0000-0000-0000-000000000001", image_ts: 1700000000, set_code: "m10", collector_number: "146", usd: "1.50", usd_foil: 9, printings: 2 });
  assertEquals(c.title, "Lightning Bolt  {R}");
  assertEquals(c.description, "Instant\nFrom $1.50 · foil $9.00 (TCGplayer market, near mint)\n2 printings");
  assertEquals(c.footer.text, "Table 1 · M10 146");
  assertEquals(cardEmbed({ oracle_id: "o1", name: "X", mana_cost: null, type_line: null, card_id: null, image_ts: null, set_code: null, collector_number: null, usd: null, usd_foil: null, printings: 1 }).description, "No TCGplayer price\n1 printing");
});

Deno.test("/help lists every registered command, and commands.json is well-formed for Discord", () => {
  const h = helpEmbed();
  const registered = new Set<string>();
  for (const c of COMMANDS as { name: string; options?: { type: number; name: string }[] }[]) {
    const subs = (c.options ?? []).filter((o) => o.type === 1);
    if (subs.length) subs.forEach((s) => registered.add(`/${c.name} ${s.name}`));
    else registered.add(`/${c.name}`);
  }
  const helped = new Set(HELP.map((x) => x.command));
  assertEquals([...registered].sort(), [...helped].sort());
  for (const cmd of registered) assert(h.description.includes(`**${cmd}**`), `${cmd} in /help`);
  assert(h.description.length <= 4096);
  for (const c of COMMANDS as { name: string; description: string; options?: { name: string; description: string; choices?: unknown[]; autocomplete?: boolean }[] }[]) {
    assert(/^[a-z-]{1,32}$/.test(c.name) && c.description.length <= 100, c.name);
    for (const o of c.options ?? []) {
      assert(/^[a-z0-9-]{1,32}$/.test(o.name) && o.description.length <= 100, `${c.name} ${o.name}`);
      assert(!(o.choices && o.autocomplete), "choices and autocomplete don't mix");
      assert((o.choices?.length ?? 0) <= 25);
    }
  }
});

Deno.test("telemetry never carries ids or names", async () => {
  const t = new Telemetry("phc_x", "https://us.i.posthog.com", { platform: "discord", environment: "test" });
  t.capture("u-1", "discord_event_created", { format: "modern", scheduled: true, capped: false, top_cut: 8, auto_rounds: true, named: false });
  assertEquals(t.pending()[0].properties, { platform: "discord", environment: "test", format: "modern", scheduled: true, capped: false, top_cut: 8, auto_rounds: true, named: false });
  assertThrows(() => cleanProperties({ guild_id: "20001" }));
  assertThrows(() => cleanProperties({ name: "Ana" }));
  assertThrows(() => cleanProperties({ who: "123456789012345678" }), Error, "looks like a Discord id");
  const h1 = await hashId("123456789012345678", "salt");
  assert(h1.startsWith("discord:") && h1.length === 24 && !h1.includes("1234"));
  assert(h1 !== await hashId("123456789012345678", "other-salt"));
  const off = new Telemetry("", "", {});
  assert(!off.enabled);
});

Deno.test("wants and for-trade posts: the list, one card, prices, the link, no max prices", () => {
  const wants = partEmbed({
    part: "wants", query: null, rows_total: 2, cards: 4, value: null, url: "https://table-1.site/l/Ab3_-x9QzLm2pR7tKw4vYc", owner: "Ana",
    rows: [
      { name: "Lightning Bolt", qty: 1, set: "m10", number: "146", finish: "foil", usd: "9.00", card_id: "c1000000-0000-0000-0000-000000000001", image_ts: 1 },
      { name: "Opt", qty: 3, set: null, number: null, finish: null, usd: "0.10", card_id: null, image_ts: null },
    ],
  });
  assertEquals(wants.title, "Ana's wants");
  assertEquals(wants.description, "1 Lightning Bolt · M10 146 · foil · $9.00\n3 Opt · any printing · from $0.10");
  assertEquals(wants.footer.text, "Table 1 · 4 cards wanted");
  assertEquals(wants.url, "https://table-1.site/l/Ab3_-x9QzLm2pR7tKw4vYc");
  assertEquals(wants.thumbnail, undefined, "a list has no single card to picture");
  assert(!JSON.stringify(wants).includes("max"));
  const one = partEmbed({
    part: "for_trade", query: "bolt", rows_total: 1, cards: 4, value: "6.00", url: "https://table-1.site/l/T", owner: "Ana",
    rows: [{ name: "Lightning Bolt", qty: 4, set: "m10", number: "146", finish: "nonfoil", condition: "LP", lang: "en", usd: 1.35, card_id: "c1000000-0000-0000-0000-000000000001", image_ts: 1700000000 }],
  });
  assertEquals(one.title, "Ana's for trade: Lightning Bolt");
  assertEquals(one.description, "4 Lightning Bolt · M10 146 · LP · $1.35");
  assertEquals(one.footer.text, "Table 1 · 4 cards for trade · $6.00 at market");
  assertEquals(one.thumbnail?.url, "https://cards.scryfall.io/normal/front/c/1/c1000000-0000-0000-0000-000000000001.jpg?1700000000");
  const many = partEmbed({ part: "for_trade", query: null, rows_total: 40, cards: 90, value: 0, url: "u", owner: null,
    rows: Array.from({ length: 40 }, (_, i) => ({ name: `Card ${i}`, qty: 2, set: "m10", number: String(i), finish: "nonfoil", condition: "NM", lang: "en", usd: null, card_id: null, image_ts: null })) });
  assertEquals(many.title, "My cards for trade");
  assert(many.description.endsWith("…and 15 more"));
  assertEquals(many.description.split("\n").length, 26);
  const none = partEmbed({ part: "wants", query: "zzz", rows_total: 0, cards: 0, value: null, url: "u", owner: "Ana", rows: [] });
  assertEquals(none.description, 'Nothing matching "zzz".');
  const ask = partConfirmMessage("for_trade");
  assertEquals(ask.components[0].components[0].custom_id, "t1:trades");
  assert(ask.content.includes("cards for trade"));
});

/** Answers fetches from a script of [status, body] and records what was asked. */
function fakeDiscord(script: [number, unknown][]) {
  const calls: { method: string; url: string }[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = ((url: string, init?: RequestInit) => {
    calls.push({ method: init?.method ?? "GET", url: String(url) });
    const [status, body] = script.shift() ?? [500, {}];
    return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } }));
  }) as typeof fetch;
  return { calls, restore: () => (globalThis.fetch = real) };
}

Deno.test("the posted card's id is read once Discord has the answer (it refuses until then)", async () => {
  const d = fakeDiscord([[400, { code: 10062 }], [404, { code: 10008 }], [200, { id: "123456789012345678" }]]);
  const errors = console.error;
  console.error = () => {};
  try {
    const rest = new DiscordRest("t", [1, 1, 1, 1]);
    assertEquals(await rest.originalMessageId({ application_id: "1", token: "tok" }), "123456789012345678");
    assertEquals(d.calls.length, 3);
    assert(d.calls.every((c) => c.method === "GET" && c.url.endsWith("/webhooks/1/tok/messages/@original")));
  } finally {
    d.restore();
    console.error = errors;
  }
});

Deno.test("follow-ups and card id reads go to the interaction's own application, whatever the secrets say", async () => {
  // Live on 2026-10-29 the DISCORD_APPLICATION_ID secret held its own name: every call went to
  // /webhooks/DISCORD_APPLICATION_ID/… (400 50035), so no card's message id was ever stored.
  const d = fakeDiscord([[200, { id: "1" }], [200, { id: "123456789012345678" }]]);
  try {
    const ix = { application_id: "1565382252706140300", token: "tok" };
    const rest = new DiscordRest("t", [1]);
    await rest.followUp(ix, { content: "hi" });
    assertEquals(await rest.originalMessageId(ix), "123456789012345678");
    assertEquals(d.calls.map((c) => c.url.split("/api/v10")[1]),
      ["/webhooks/1565382252706140300/tok", "/webhooks/1565382252706140300/tok/messages/@original"]);
  } finally {
    d.restore();
  }
});

Deno.test("retries stop on success, on other failures and after the last wait", async () => {
  const errors = console.error;
  const logged: string[] = [];
  console.error = (m: string) => logged.push(m);
  try {
    let d = fakeDiscord([[200, { id: "1" }]]);
    await new DiscordRest("t", [1, 1]).followUp({ application_id: "1", token: "tok" }, { content: "hi" });
    assertEquals(d.calls.length, 1);
    d.restore();
    d = fakeDiscord([[401, { code: 50027 }]]);
    assertEquals(await new DiscordRest("t", [1, 1]).originalMessageId({ application_id: "1", token: "tok" }), null);
    assertEquals(d.calls.length, 1);
    d.restore();
    d = fakeDiscord([[400, {}], [400, {}], [400, { code: 50035 }]]);
    const token = "aW50ZXJhY3Rpb246MTIzNDU2Nzg5MDEyMzQ1Njc4OnNlY3JldA";
    assertEquals(await new DiscordRest("t", [1, 1]).originalMessageId({ application_id: "1", token }), null);
    assertEquals(d.calls.length, 3);
    d.restore();
    assertEquals(logged.length, 2, "only the final failure of each call is logged");
    assert(logged[1].includes("400 (50035)") && !logged[1].includes(token), logged[1]);
  } finally {
    console.error = errors;
  }
});

Deno.test("a card edit waits once when Discord says slow down", async () => {
  const d = fakeDiscord([[429, { retry_after: 0.001 }], [200, { id: "1" }]]);
  try {
    const r = await new DiscordRest("t").editMessage("111111", "222222", { content: "x" });
    assertEquals(r.status, 200);
    assertEquals(d.calls.map((c) => c.method), ["PATCH", "PATCH"]);
    assert(d.calls[0].url.endsWith("/channels/111111/messages/222222"));
  } finally {
    d.restore();
  }
});

Deno.test("/meta: options checked, the picture's address, the post", () => {
  const o = (v: Record<string, string | number>) => Object.entries(v).map(([name, value]) => ({ name, type: 3, value }));
  assertEquals(metaAsk("matchups", o({ format: "modern" })), { kind: "matchups", format: "modern", tier: "all", days: 30, a: null });
  assertEquals(metaAsk("winrates", o({ format: "pauper", events: "big", days: 7 })), { kind: "winrates", format: "pauper", tier: "big", days: 7, a: null });
  assertEquals(metaAsk("matchups", o({ format: "premodern" })), null, "a format Insights doesn't cover");
  assertEquals(metaAsk("matchups", o({ format: "vintage" }))?.format, "vintage", "Legacy and Vintage since 2026-10-31");
  assertEquals(metaAsk("matchups", o({ format: "modern", days: 45 }))!.days, 30, "a window that isn't offered");
  assertEquals(metaAsk("deck", o({ format: "modern", archetype: "none" })), null, "the autocomplete's hint isn't an archetype");
  assertEquals(metaAsk("deck", o({ format: "modern", archetype: "0" }))!.a, 0, "Other");
  const ask = metaAsk("deck", o({ format: "modern", archetype: "11", events: "big", days: 90 }))!;
  assertEquals(metaImageUrl("https://x.supabase.co/functions/v1/meta-image/", ask, "1433000000000000000"),
    "https://x.supabase.co/functions/v1/meta-image/modern/deck.png?tier=big&days=90&a=11&v=1433000000000000000");
  const e = metaEmbed(ask, "Boros Land Destruction", "https://p");
  assertEquals([e.title, e.description, e.url, e.image.url], [
    "Boros Land Destruction · Modern", "Matchups · Big events · last 90 days", "https://table-1.site/insights/modern/archetype/11", "https://p"]);
  const grid = metaEmbed(metaAsk("matchups", o({ format: "canlander" }))!, null, "https://p");
  assertEquals([grid.title, grid.url], ["Canadian Highlander · Matchups", "https://table-1.site/insights/canlander/matchups"]);
  assertEquals(metaEmbed(metaAsk("winrates", o({ format: "modern" }))!, null, "https://p").url, "https://table-1.site/insights/modern/part/meta");
  assertEquals(metaComponents(ask)[0].components[0].url, "https://table-1.site/insights/modern/archetype/11");
});

Deno.test("/meta is registered with its three pictures, each with format, events and days", () => {
  const meta = (COMMANDS as { name: string }[]).find((c) => c.name === "meta") as unknown as { options: { name: string; options: { name: string }[] }[] };
  assertEquals(meta.options.map((x) => x.name), ["matchups", "deck", "winrates"]);
  for (const sub of meta.options) {
    const names = sub.options.map((x) => x.name);
    assert(["format", "events", "days"].every((n) => names.includes(n)), sub.name);
  }
  assert(HELP.some((h) => h.command === "/meta deck"));
});
