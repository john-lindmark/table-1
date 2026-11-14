// Dev server only (`?demo`): stand-in events for entry fees, teams that sign themselves up, Team Trios and the top 4
// cut, and the room tools (contracts entry-fees, teams-finals-alerts and room-tools, 2026-11-13), so every new screen
// opens on the real organizer, player and event pages without an account or a server. Rounds are paired by the app's
// own rules; nobody here is a real person; changes stay in memory. Production builds drop this file.
//
//   /e/demo-ev-up-1?demo     Setup: a $25 fee (app or door) with mixed payments, in a league that takes $7 an entry
//   /p/demo-ev-up-1?demo     the same event as a player who hasn't paid;  /s/demo-ev-up-1?demo  its public page
//   /e/demo-ev-up-2?demo     the season's final: Setup → Players → Qualified
//   /e/demo-trios?demo       Team Trios, teams signing themselves up;     /s/demo-trios?demo    Sign up a team / Join a team
//   /e/demo-trioslive?demo   Team Trios at the top 4: the team semifinals being played
//   /e/demo-top4?demo        Swiss is in: Cut to top 4
//   /e/demo-room?demo        round 2 with a judge call and a table on extra time;  /p/demo-room?demo  that table's player
//   /e/demo-prizes?demo      finished, with prizes
import type { EventBundle } from "./api";
import { DEFAULT_SEAT_FORMATS } from "./leagues";
import { PAYOUT_PRESETS, poolOf, prizeAt, type EventMoney, type Fee, type FeePatch, type MyPayment, type PayMethod, type PayStatus, type StripeAccount } from "./money";
import { mulberry32, pairRound, type ProposedMatch } from "./pairings";
import { playoffStandings } from "./playoffs";
import type { EventRoom, JudgeCall, RoomDisplay, RoomExtension } from "./room";
import { computeTeamStandings, membersOf, pairTeamPlayoff, pairTeamSwissRound, type Team } from "./teams";
import type { ListedTeam, MyTeam, TeamMember, TeamMine, TeamPatch } from "./teamSignup";
import type { EventTeam, FormatName, Match, Participant, RoundWithMatches, Table1Event, TopCut } from "./types";

export { leagueDueMark, leagueMoney } from "./leaguesDemo";

const ME = "demo";
const uid = (n: number) => `d0000000-0000-0000-0000-0000000f${String(n).padStart(4, "0")}`;
const NAMES = ["Sam Reyes", "Mara Quinn", "Theo Vance", "Ines Ruiz", "Sam Okafor", "Lee Park", "Kai Brandt", "Bea Lindqvist", "Cy Moreau", "Dee Zhou",
  "Eli Varga", "Fen Adeyemi", "Gus Novak", "Hal Sato", "Ivy Bianchi", "Jo Weber", "Kit Aldana", "Lu Fischer", "Max Berg", "Nia Alvarez"];
const now = Date.now();
const err = (message: string, code: string) => Object.assign(new Error(message), { code });
/** The page the demo is on decides who is asking: an organizer on /e/, a player on /p/ and /life, a visitor elsewhere. */
const asking = (): "organizer" | "player" | "visitor" => {
  const p = typeof location === "undefined" ? "" : location.pathname;
  return p.startsWith("/e/") || p.startsWith("/dev/") ? "organizer" : p.startsWith("/p/") || p.startsWith("/life") || p.startsWith("/pay/") ? "player" : "visitor";
};

/* ── events ──────────────────────────────────────────────────────────── */

interface Demo {
  event: Table1Event; participants: Participant[]; rounds: RoundWithMatches[]; teams: Team[];
  /** The demo account plays in it (seat p1). */
  playing: boolean;
}

function event(id: string, name: string, formatName: FormatName, formatLabel: string, over: Partial<Table1Event>): Table1Event {
  return {
    id, shortCode: id.replace(/[^a-z0-9]/gi, "").slice(-4).toUpperCase(), name, format: "constructed", status: "setup", numberOfRounds: 3, currentRound: 0,
    roundLengthSeconds: 3000, allowPlayerReporting: true, createdBy: ME, cancelReason: null, formatName, formatLabel, eventType: "constructed",
    teamSize: null, setName: null, cubeName: null, cubeUrl: null, setCode: null, formatOther: null, cancelledAt: null,
    updatedAt: new Date(now).toISOString(), showClock: true, autoName: false, pairing: "swiss", topCut: 0, autoRounds: false, seatFormats: null,
    teamSignup: false, visibility: "public", seatEnds: false, capacity: null, startsAt: null, venueName: "MeH Games", decklists: "off",
    pods: null, podPairing: "cross", ...over,
  };
}

function people(eventId: string, n: number, me: boolean): Participant[] {
  return Array.from({ length: n }, (_, i) => {
    const name = NAMES[(i + (me ? 0 : 1)) % NAMES.length];
    return { id: `p${i + 1}`, eventId, podId: null, displayName: name, seat: null, status: "active" as const, droppedInRound: null,
             userId: name === "Sam Reyes" ? ME : i < 7 ? uid(i + 1) : null };
  });
}

/** A round from its proposed pairings: the first `played` real matches have a result. */
function round(eventId: string, number: number, stage: RoundWithMatches["stage"], proposed: ProposedMatch[], played: number, open: boolean,
               rng: () => number, id = `${eventId}-r${number}`): RoundWithMatches {
  let done = 0;
  const matches: Match[] = proposed.map((m) => {
    const mid = `${id}-m${m.tableNumber}`;
    const scored = m.isBye || done < played;
    if (!m.isBye && scored) done++;
    const roll = rng();
    const [a, b] = !scored || m.isBye ? [m.isBye ? 2 : 0, 0] : roll < 0.4 ? [2, 0] : roll < 0.62 ? [2, 1] : roll < 0.85 ? [0, 2] : [1, 2];
    return {
      id: mid, eventId, roundId: id, tableNumber: m.isBye ? null : m.tableNumber, isBye: m.isBye, gameDraws: 0, intentionalDraw: false,
      status: scored ? "confirmed" : "pending", version: 0, disputed: false, extraSeconds: 0,
      sides: [{ id: `${mid}a`, matchId: mid, participantId: m.side0ParticipantId, side: 0, gameWins: a },
              ...(m.side1ParticipantId ? [{ id: `${mid}b`, matchId: mid, participantId: m.side1ParticipantId, side: 1 as const, gameWins: b }] : [])],
    };
  });
  const elapsed = 14 * 60;
  return {
    id, eventId, number, status: open ? "active" : "recorded", stage, matches, pairingsPublishedAt: new Date(now - elapsed * 1000).toISOString(),
    timerDurationSeconds: 3000, timerRemainingAtChange: open ? 3000 : 0, timerStatus: open ? "running" : "paused",
    timerLastStartedAt: open ? new Date(now - elapsed * 1000).toISOString() : null, timerEndsAt: open ? new Date(now + (3000 - elapsed) * 1000).toISOString() : null,
  };
}

/** Swiss rounds for players: `count` paired, the last one open with `playedInOpen` results (null: every round recorded). */
function swiss(eventId: string, participants: Participant[], count: number, playedInOpen: number | null, seed: number): RoundWithMatches[] {
  const rng = mulberry32(seed);
  const rounds: RoundWithMatches[] = [];
  for (let n = 1; n <= count; n++) {
    const proposed = pairRound({ participants, rounds, roundNumber: n, rng });
    const open = n === count && playedInOpen != null;
    rounds.push(round(eventId, n, "swiss", proposed, open ? playedInOpen! : proposed.length, open, rng));
  }
  return rounds;
}

const TEAM_NAMES = ["Glacial Chasm", "Dack's Duplicates", "Three Wishes", "Storm Count", "Bolt the Bird", "Second Sunrise"];

function build(): Map<string, Demo> {
  const out = new Map<string, Demo>();
  const days = (n: number, hour = 10) => { const d = new Date(now + n * 86_400_000); d.setHours(hour, 0, 0, 0); return d.toISOString(); };

  // A league event with a fee, before round 1.
  out.set("demo-ev-up-1", {
    event: event("demo-ev-up-1", "Modern Open", "modern", "Modern", { startsAt: days(8), topCut: 8, autoRounds: true, numberOfRounds: 4, decklists: "optional" }),
    participants: people("demo-ev-up-1", 12, true), rounds: [], teams: [], playing: true,
  });
  // The season's final (invitation only), free to enter with the league's prize pool added.
  out.set("demo-ev-up-2", {
    event: event("demo-ev-up-2", "The Final", "modern", "Modern", { startsAt: days(29, 9), topCut: 8, autoRounds: true, numberOfRounds: 4, capacity: 32,
                                                                 venueName: "The Wizard's Chest", visibility: "private" }),
    participants: people("demo-ev-up-2", 9, true), rounds: [], teams: [], playing: true,
  });
  // Team Trios, teams signing themselves up: three whole teams, one of two, one of one.
  {
    const id = "demo-trios";
    const sizes = [3, 3, 3, 2, 1];
    const ps = people(id, 12, false);
    let k = 0;
    const teams: Team[] = sizes.map((n, t) => {
      for (let s = 1; s <= n; s++) Object.assign(ps[k++], { teamId: `${id}-t${t + 1}`, teamSlot: s });
      return { id: `${id}-t${t + 1}`, name: TEAM_NAMES[t], order: t };
    });
    out.set(id, {
      event: event(id, "Team Trios Open", "team_trios", "Team Trios", { startsAt: days(12, 11), teamSize: 3, seatFormats: [...DEFAULT_SEAT_FORMATS],
                                                                        teamSignup: true, topCut: 4, numberOfRounds: 3, capacity: 24, venueName: "Mythic Games" }),
      participants: ps, rounds: [], teams, playing: false,
    });
  }
  // Team Trios at the top 4: six teams, three Swiss rounds in, the team semifinals being played.
  {
    const id = "demo-trioslive";
    const ps = people(id, 18, false);
    const teams: Team[] = TEAM_NAMES.map((name, t) => ({ id: `${id}-t${t + 1}`, name, order: t }));
    ps.forEach((p, i) => Object.assign(p, { teamId: teams[Math.floor(i / 3)].id, teamSlot: (i % 3) + 1 }));
    const rng = mulberry32(4107);
    const rounds: RoundWithMatches[] = [];
    for (let n = 1; n <= 3; n++) {
      const proposed = pairTeamSwissRound(teams, ps, rounds, n, rng);
      rounds.push(round(id, n, "swiss", proposed, proposed.length, false, rng));
    }
    const semis = pairTeamPlayoff("semifinal", teams, ps, rounds);
    rounds.push(round(id, 4, "semifinal", semis, 4, true, rng));
    out.set(id, {
      event: event(id, "Team Trios Open", "team_trios", "Team Trios", { status: "in_progress", teamSize: 3, seatFormats: [...DEFAULT_SEAT_FORMATS], topCut: 4,
                                                                        numberOfRounds: 3, currentRound: 4, venueName: "Mythic Games" }),
      participants: ps, rounds, teams, playing: false,
    });
  }
  // Eight players, top 4: every Swiss result is in, the cut is next.
  {
    const id = "demo-top4";
    const ps = people(id, 8, false);
    out.set(id, {
      event: event(id, "Pauper Weekly", "pauper", "Pauper", { status: "in_progress", topCut: 4, numberOfRounds: 3, currentRound: 3, venueName: "Black & Read" }),
      participants: ps, rounds: swiss(id, ps, 3, 4, 8804), teams: [], playing: false,
    });
  }
  // Sixteen players, round 2 being played: a judge call, a table on extra time, an announcement on the display.
  {
    const id = "demo-room";
    const ps = people(id, 16, true);
    out.set(id, {
      event: event(id, "Modern Open", "modern", "Modern", { status: "in_progress", numberOfRounds: 4, currentRound: 2, venueName: "MeH Games" }),
      participants: ps, rounds: swiss(id, ps, 2, 3, 1602), teams: [], playing: true,
    });
  }
  // Finished, with a fee and prizes.
  {
    const id = "demo-prizes";
    const ps = people(id, 8, true);
    out.set(id, {
      event: event(id, "Legacy Open", "legacy", "Legacy", { status: "completed", numberOfRounds: 3, currentRound: 3, venueName: "Mythic Games" }),
      participants: ps, rounds: swiss(id, ps, 3, null, 3305), teams: [], playing: true,
    });
  }
  return out;
}

let made: Map<string, Demo> | null = null;
const demos = () => (made ??= build());
const demoOf = (eventId: string) => demos().get(eventId) ?? null;

/** A stand-in event as event_bundle would answer, or null for an id that isn't one. */
export function demoBundle(eventId: string): EventBundle | null {
  const d = demoOf(eventId);
  if (!d) return null;
  const ext = new Map(roomOf(eventId).extensions.map((x) => [x.match_id, x.extra_seconds]));
  return {
    event: d.event, participants: d.participants,
    rounds: d.rounds.map((r) => ({ ...r, matches: r.matches.map((m) => ({ ...m, extraSeconds: ext.get(m.id) ?? 0 })) })),
    waitlist: [], decklists: [], pods: [],
  };
}

export function demoTeams(eventId: string): EventTeam[] {
  const d = demoOf(eventId);
  if (!d) return [];
  return d.teams.map((t) => ({
    id: t.id, name: t.name, order: t.order,
    members: membersOf(t.id, d.participants, false).map((p) => ({ participant_id: p.id, display_name: p.displayName, slot: p.teamSlot ?? 0,
                                                                  user_id: p.userId ?? null, status: p.status })),
  }));
}

/** The seat the demo account holds in a stand-in event (the player screens find themselves by it). */
export function demoSeat(eventId: string): { participantId: string; displayName: string } | null {
  const d = demoOf(eventId);
  const p = d?.participants.find((x) => x.userId === ME && (d.playing || x.id === "p-me")) ?? null;
  return p ? { participantId: p.id, displayName: p.displayName } : null;
}

/* ── money ───────────────────────────────────────────────────────────── */

interface Pay { status: PayStatus; method: PayMethod }
interface MoneyState { fee: Fee | null; pays: Map<string, Pay>; custom: Map<string, number> | null; paid: Map<string, string>; polls: number }
const moneyState = new Map<string, MoneyState>();
let account: StripeAccount = { connected: true, ready: true, payouts: true, details_submitted: true, disabled_reason: null };

const fee = (over: Partial<Fee>): Fee => ({
  amount_cents: 2500, currency: "usd", pay_mode: "either", refund_hours: 24, host_keep: { kind: "percent", value: 10 }, added_cents: 0,
  payout: PAYOUT_PRESETS.top4, league_cut_cents: 0, ...over,
});

function moneyOf(eventId: string): MoneyState {
  let s = moneyState.get(eventId);
  if (s) return s;
  const d = demoOf(eventId);
  const pays = new Map<string, Pay>();
  const mixed: Pay[] = [{ status: "unpaid", method: null }, { status: "paid", method: "app" }, { status: "paid", method: "app" }, { status: "paid", method: "door" },
    { status: "paid", method: "comp" }, { status: "pending", method: "app" }, { status: "paid", method: "app" }, { status: "unpaid", method: null },
    { status: "refunded", method: "app" }, { status: "paid", method: "door" }, { status: "unpaid", method: null }, { status: "unpaid", method: null }];
  s = { fee: null, pays, custom: null, paid: new Map(), polls: 0 };
  if (eventId === "demo-ev-up-1") {
    s.fee = fee({ league_cut_cents: 700 });
    d?.participants.forEach((p, i) => pays.set(p.id, mixed[i % mixed.length]));
  } else if (eventId === "demo-ev-up-2") {
    s.fee = fee({ amount_cents: 0, pay_mode: "door", refund_hours: null, host_keep: { kind: "none", value: 0 }, added_cents: 140000, payout: PAYOUT_PRESETS.top8 });
  } else if (eventId === "demo-prizes") {
    s.fee = fee({ amount_cents: 2000, host_keep: { kind: "flat", value: 2000 }, added_cents: 5000 });
    d?.participants.forEach((p, i) => pays.set(p.id, { status: "paid", method: i % 3 === 0 ? "door" : "app" }));
    const first = d ? playoffStandings(d.participants, d.rounds)[0] : null;
    if (first) s.paid.set(first.participantId, "cash");
  } else if (eventId === "demo-trios") {
    s.fee = fee({ amount_cents: 1500, pay_mode: "door", refund_hours: null, host_keep: { kind: "none", value: 0 }, payout: PAYOUT_PRESETS.top2 });
  }
  // A checkout started before this page loaded (Stripe's return is a fresh page): still on its way, then paid.
  const kept = keptCheckout();
  if (kept?.eventId === eventId && s.fee && d?.playing) {
    s.pays.set("p1", kept.paid ? { status: "paid", method: "app" } : { status: "pending", method: "app" });
    s.polls = kept.paid ? 0 : 2;
  }
  moneyState.set(eventId, s);
  return s;
}

const CHECKOUT_KEY = "table1.demo.checkout";
function keptCheckout(): { eventId: string; paid: boolean } | null {
  try {
    return JSON.parse(sessionStorage.getItem(CHECKOUT_KEY) ?? "null");
  } catch {
    return null;
  }
}
function keepCheckout(v: { eventId: string; paid: boolean } | null) {
  try {
    if (v) sessionStorage.setItem(CHECKOUT_KEY, JSON.stringify(v));
    else sessionStorage.removeItem(CHECKOUT_KEY);
  } catch { /* private window: the demo's payment lasts for this page */ }
}

export function eventMoney(eventId: string): EventMoney {
  const d = demoOf(eventId);
  const s = moneyOf(eventId);
  if (!s.fee) return { fee: null };
  const f = s.fee;
  const who = asking();
  const payOf = (id: string): Pay => s.pays.get(id) ?? { status: "unpaid", method: null };
  const entries = [...s.pays.values()].filter((p) => p.status === "paid" && p.method !== "comp").length;
  const pool = { entries, added_cents: f.added_cents, ...poolOf(entries, f.amount_cents, f.league_cut_cents, f.host_keep.kind, f.host_keep.value, f.added_cents) };
  const ready = f.pay_mode !== "door" && account.ready;
  const seat = demoSeat(eventId);
  let me: MyPayment | null = null;
  if (seat && who === "player") {
    const p = payOf(seat.participantId);
    // A checkout started in the demo settles on the second read after it, as the webhook would.
    if (p.status === "pending" && s.polls > 0 && --s.polls === 0) {
      s.pays.set(seat.participantId, { status: "paid", method: "app" });
      keepCheckout({ eventId, paid: true });
    }
    const q = payOf(seat.participantId);
    me = { participant_id: seat.participantId, status: q.status, method: q.method, amount_cents: q.status === "paid" && q.method !== "comp" ? f.amount_cents : 0,
           can_pay: f.amount_cents > 0 && ready && q.status !== "paid" && d?.event.status !== "completed",
           can_refund: q.status === "paid" && q.method === "app" && f.refund_hours != null && (d?.rounds.length ?? 0) === 0 };
  }
  const done = d?.event.status === "completed";
  const places = done && d ? playoffStandings(d.participants, d.rounds) : [];
  const prizes = places.map((r) => {
    const table = prizeAt(f.payout, pool.pool_cents, r.rank);
    const amount = s.custom ? s.custom.get(r.participantId) ?? 0 : table;
    return { participant_id: r.participantId, user_id: d?.participants.find((p) => p.id === r.participantId)?.userId ?? null, name: r.displayName,
             place: r.rank, amount_cents: amount, custom: !!s.custom?.has(r.participantId), paid: s.paid.has(r.participantId),
             paid_how: s.paid.get(r.participantId) ?? null };
  }).filter((p) => p.amount_cents > 0 || p.custom);
  return {
    fee: f, app_ready: ready, pool, me, prizes,
    organizer: who === "organizer" ? {
      stripe: { connected: account.connected, ready: account.ready },
      players: (d?.participants ?? []).map((p) => ({ participant_id: p.id, user_id: p.userId ?? null, name: p.displayName, ...payOf(p.id),
                                                     amount_cents: payOf(p.id).status === "paid" && payOf(p.id).method !== "comp" ? f.amount_cents : 0 })),
      unpaid: (d?.participants ?? []).filter((p) => p.status === "active" && payOf(p.id).status !== "paid").length,
    } : null,
  };
}

export function eventFeeSet(eventId: string, patch: FeePatch | null): { fee: Fee | null } {
  const s = moneyOf(eventId);
  if (patch === null) {
    if ([...s.pays.values()].some((p) => p.status === "paid" && p.method === "app")) throw err("Refund the entries paid in the app before removing the fee", "22023");
    s.fee = null;
    return { fee: null };
  }
  const next = { ...(s.fee ?? fee({ league_cut_cents: eventId === "demo-ev-up-1" ? 700 : 0, pay_mode: "door", host_keep: { kind: "none", value: 0 }, payout: [] })), ...patch };
  if (next.pay_mode !== "door" && !account.ready) throw err("Connect Stripe before taking payments in the app", "55000");
  if (next.amount_cents !== 0 && (next.amount_cents < 50 || next.amount_cents > 100000)) throw err("An entry fee is $0.50 to $1,000, or free", "22023");
  s.fee = next;
  return { fee: next };
}

export function eventPaymentMark(eventId: string, participantId: string, state: "door" | "comp" | "unpaid") {
  const s = moneyOf(eventId);
  const was = s.pays.get(participantId);
  if (was?.status === "paid" && was.method === "app") throw err("A payment made in the app changes only by a refund", "22023");
  s.pays.set(participantId, state === "unpaid" ? { status: "unpaid", method: null } : { status: "paid", method: state });
}

export function eventPrizesSet(eventId: string, rows: { participant_id: string; amount_cents: number }[] | null) {
  const s = moneyOf(eventId);
  if (rows === null) { s.custom = null; return; }
  const pool = eventMoney(eventId).pool?.pool_cents ?? 0;
  if (rows.reduce((n, r) => n + r.amount_cents, 0) > pool) throw err("The prizes can't pass the pool", "22023");
  s.custom = new Map(rows.map((r) => [r.participant_id, r.amount_cents]));
}

export function eventPrizeMark(eventId: string, participantId: string, paid: boolean, how: string | null) {
  const s = moneyOf(eventId);
  if (paid) s.paid.set(participantId, how ?? "other");
  else s.paid.delete(participantId);
}

export const paymentsAccount = (): StripeAccount => ({ ...account });
/** Account → Payments in the demo starts where `&stripe=` says: none | started | ready (the default). */
export function demoStripe(state: string | null) {
  if (state === "none") account = { connected: false, ready: false, payouts: false, details_submitted: false, disabled_reason: null };
  if (state === "started") account = { connected: true, ready: false, payouts: false, details_submitted: false, disabled_reason: "requirements.past_due" };
}

if (typeof location !== "undefined") demoStripe(new URLSearchParams(location.search).get("stripe"));

/** The payments function's actions on stand-in data: its links lead to this site's own return pages. */
export function payments(body: Record<string, unknown>): unknown {
  const eventId = String(body.event_id ?? "");
  switch (body.action) {
    case "connect_start":
      if (!account.connected) account = { connected: true, ready: false, payouts: false, details_submitted: false, disabled_reason: "requirements.past_due" };
      return { url: `${location.origin}/pay/connected?demo` };
    case "connect_status":
      // Onboarding finishes between two looks, as it does when Stripe has what it needs.
      if (account.connected && !account.ready) account = { connected: true, ready: true, payouts: true, details_submitted: true, disabled_reason: null };
      return { ...account };
    case "connect_dashboard":
      return { url: "https://connect.stripe.com/express_login" };
    case "checkout": {
      const s = moneyOf(eventId), seat = demoSeat(eventId);
      if (!seat || !s.fee) throw err("Sign up before paying", "22023");
      s.pays.set(seat.participantId, { status: "pending", method: "app" });
      s.polls = 2;
      keepCheckout({ eventId, paid: false });
      return { url: `${location.origin}/pay/done?e=${eventId}&s=cs_demo&demo` };
    }
    case "refund": {
      const s = moneyOf(eventId);
      const id = String(body.participant_id ?? demoSeat(eventId)?.participantId ?? "");
      s.pays.set(id, { status: "refunded", method: "app" });
      if (id === demoSeat(eventId)?.participantId) keepCheckout(null);
      return { refunded: true, amount_cents: s.fee?.amount_cents ?? 0 };
    }
    default:
      throw err("Unknown action", "22023");
  }
}

/* ── teams that sign themselves up ───────────────────────────────────── */

const CODES = ["GLCH7K2M", "DACK4D9P", "WISH3X8T", "STRM6Q2B", "BOLT9R5N", "SNRS2W7C"];
const captains = new Map<string, string | null>();
let mine: string | null = null;

function teamJson(d: Demo, t: Team, full: boolean): MyTeam {
  const members: TeamMember[] = membersOf(t.id, d.participants, false).map((p) => ({ participant_id: p.id, user_id: p.userId ?? `guest-${p.id}`, name: p.displayName, slot: p.teamSlot ?? null }));
  if (!captains.has(t.id)) captains.set(t.id, members[0]?.user_id ?? null);
  return { id: t.id, name: t.name, captain_id: captains.get(t.id) ?? null, join_code: full ? CODES[t.order % CODES.length] : null, members,
           complete: members.length === (d.event.teamSize ?? 3) };
}

export function teamMine(eventId: string): TeamMine {
  const d = demoOf(eventId);
  if (!d) throw err("That event isn't available", "42501");
  const organizer = asking() === "organizer";
  const my = mine ? d.teams.find((t) => t.id === mine) : null;
  const size = d.event.teamSize ?? 3;
  const taken = d.teams.length * size + d.participants.filter((p) => !p.teamId).length;
  const teams: ListedTeam[] = [...d.teams].sort((a, b) => a.order - b.order).map((t) => {
    const full = teamJson(d, t, true);
    return organizer ? full : { id: t.id, name: t.name, members: full.members.length, complete: full.complete };
  });
  return {
    team_signup: d.event.teamSignup, team_size: d.event.teamSize, seat_formats: d.event.seatFormats, team: my ? teamJson(d, my, true) : null,
    captain: !!my && captains.get(my.id) === ME,
    can_create: d.event.teamSignup && !my && !organizer && d.rounds.length === 0 && (d.event.capacity == null || taken + size <= d.event.capacity), teams,
  };
}

export function teamSignupSet(eventId: string, on: boolean): { team_signup: boolean } {
  const d = demoOf(eventId);
  if (!d) throw err("That event isn't available", "42501");
  d.event = { ...d.event, teamSignup: on };
  return { team_signup: on };
}

const meIn = (d: Demo, teamId: string, slot: number) =>
  d.participants.push({ id: "p-me", eventId: d.event.id, podId: null, displayName: "Sam Reyes", seat: null, status: "active", droppedInRound: null,
                        userId: ME, teamId, teamSlot: slot });

export function teamCreate(eventId: string, name: string): TeamMine {
  const d = demoOf(eventId);
  const clean = name.trim().replace(/\s+/g, " ");
  if (!d || !d.event.teamSignup) throw err("The organizer builds the teams for this event", "22023");
  if (mine) throw err("You're already on a team", "22023");
  if (clean.length < 2 || clean.length > 40) throw err("Name the team (2 to 40 characters)", "22023");
  if (d.teams.some((t) => t.name.toLowerCase() === clean.toLowerCase())) throw err("Another team has that name", "23505");
  const t: Team = { id: `${eventId}-t${d.teams.length + 1}`, name: clean, order: d.teams.length };
  d.teams.push(t);
  meIn(d, t.id, 1);
  captains.set(t.id, ME);
  mine = t.id;
  return teamMine(eventId);
}

export function teamJoin(eventId: string, code: string): TeamMine {
  const d = demoOf(eventId);
  if (!d) throw err("That event isn't available", "42501");
  if (mine) throw err("You're already on a team", "22023");
  const t = d.teams.find((x) => CODES[x.order % CODES.length] === code.toUpperCase());
  if (!t) throw err("No team has that code", "P0002");
  const members = membersOf(t.id, d.participants, false);
  if (members.length >= (d.event.teamSize ?? 3)) throw err("That team is full", "22023");
  teamJson(d, t, true);   // fixes its captain before you join
  meIn(d, t.id, members.length + 1);
  mine = t.id;
  return teamMine(eventId);
}

export function teamUpdate(eventId: string, teamId: string, patch: TeamPatch): TeamMine {
  const d = demoOf(eventId) ?? [...demos().values()].find((x) => x.teams.some((t) => t.id === teamId));
  const t = d?.teams.find((x) => x.id === teamId);
  if (!d || !t) throw err("That team isn't available", "P0002");
  if ("name" in patch) {
    const clean = patch.name.trim().replace(/\s+/g, " ");
    if (clean.length < 2) throw err("Name the team (2 to 40 characters)", "22023");
    if (d.teams.some((x) => x.id !== t.id && x.name.toLowerCase() === clean.toLowerCase())) throw err("Another team has that name", "23505");
    d.teams = d.teams.map((x) => (x.id === t.id ? { ...x, name: clean } : x));
  } else if ("order" in patch) {
    patch.order.forEach((id, i) => { const p = d.participants.find((x) => x.id === id); if (p) p.teamSlot = i + 1; });
  } else if ("captain" in patch) {
    captains.set(t.id, patch.captain);
  } else if ("remove" in patch) {
    d.participants = d.participants.filter((p) => p.id !== patch.remove);
    membersOf(t.id, d.participants, false).forEach((p, i) => { p.teamSlot = i + 1; });
  }
  return teamMine(d.event.id);
}

/** Leaving a stand-in team event: the captaincy passes to the first member left, and an empty team closes. */
export function demoLeave(eventId: string) {
  const d = demoOf(eventId);
  if (!d || !mine) return;
  const teamId = mine;
  d.participants = d.participants.filter((p) => p.id !== "p-me");
  const left = membersOf(teamId, d.participants, false);
  if (left.length === 0) d.teams = d.teams.filter((t) => t.id !== teamId);
  else {
    left.forEach((p, i) => { p.teamSlot = i + 1; });
    if (captains.get(teamId) === ME) captains.set(teamId, left[0].userId ?? `guest-${left[0].id}`);
  }
  mine = null;
}
/** Whether the demo account has signed up to a stand-in event through a team. */
export const demoOnTeam = (eventId: string) => !!mine && !!demoOf(eventId)?.teams.some((t) => t.id === mine);

/* ── the room ────────────────────────────────────────────────────────── */

interface RoomState { display: RoomDisplay; extensions: RoomExtension[]; calls: JudgeCall[] }
const rooms = new Map<string, RoomState>();

function roomOf(eventId: string): RoomState {
  let r = rooms.get(eventId);
  if (r) return r;
  r = { display: { show: "auto", message: null }, extensions: [], calls: [] };
  rooms.set(eventId, r);
  if (eventId === "demo-room") {
    const d = demoOf(eventId)!;
    const open = d.rounds[d.rounds.length - 1];
    const real = open.matches.filter((m) => !m.isBye);
    const myTable = real.find((m) => m.sides.some((s) => s.participantId === "p1"));
    const waiting = real.filter((m) => m.status === "pending" && m.id !== myTable?.id);
    if (myTable) r.extensions.push({ match_id: myTable.id, table_number: myTable.tableNumber, extra_seconds: 300 });
    if (waiting[1]) r.extensions.push({ match_id: waiting[1].id, table_number: waiting[1].tableNumber, extra_seconds: 180 });
    if (waiting[0]) {
      const by = d.participants.find((p) => p.id === waiting[0].sides[0]?.participantId)?.displayName ?? null;
      r.calls.push({ call_id: "call-1", match_id: waiting[0].id, table_number: waiting[0].tableNumber, called_at: new Date(Date.now() - 130_000).toISOString(), by });
    }
    r.display.message = "Round 3 starts at 14:30 · lunch is in the back room";
  }
  return r;
}

export function eventRoom(eventId: string): EventRoom {
  const r = roomOf(eventId);
  const d = demoOf(eventId);
  const who = asking();
  const open = d?.rounds[d.rounds.length - 1];
  const seat = who === "player" ? demoSeat(eventId) : null;
  const my = seat && open ? open.matches.find((m) => !m.isBye && m.sides.some((s) => s.participantId === seat.participantId)) : null;
  return {
    display: { ...r.display }, extensions: r.extensions.map((x) => ({ ...x })), calls: who === "organizer" ? r.calls.map((c) => ({ ...c })) : null,
    my_match: my ? { match_id: my.id, table_number: my.tableNumber, extra_seconds: r.extensions.find((x) => x.match_id === my.id)?.extra_seconds ?? 0,
                     call_open: r.calls.some((c) => c.match_id === my.id) } : null,
  };
}

export function eventDisplaySet(eventId: string, patch: { show?: RoomDisplay["show"]; message?: string | null }): RoomDisplay {
  const r = roomOf(eventId);
  if (patch.show) r.display.show = patch.show;
  if ("message" in patch) r.display.message = patch.message?.trim().slice(0, 140) || null;
  return { ...r.display };
}

function matchIn(eventId: string, matchId: string): { d: Demo; m: Match } {
  for (const d of eventId ? [demoOf(eventId)] : demos().values()) {
    const m = d?.rounds.flatMap((r) => r.matches).find((x) => x.id === matchId);
    if (d && m) return { d, m };
  }
  throw err("That match isn't available", "P0002");
}

export function matchTimeExtend(eventId: string, matchId: string, seconds: number): RoomExtension {
  const { d, m } = matchIn(eventId, matchId);
  const r = roomOf(d.event.id);
  const was = r.extensions.find((x) => x.match_id === matchId)?.extra_seconds ?? 0;
  const next = was + seconds;
  if (next < 0 || next > 3600) throw err("A table's extra time stays between 0 and 60 minutes", "22023");
  r.extensions = r.extensions.filter((x) => x.match_id !== matchId);
  const row = { match_id: matchId, table_number: m.tableNumber, extra_seconds: next };
  if (next > 0) r.extensions.push(row);
  r.extensions.sort((a, b) => (a.table_number ?? 0) - (b.table_number ?? 0));
  return row;
}

export function judgeCall(eventId: string, matchId: string) {
  const { d, m } = matchIn(eventId, matchId);
  const r = roomOf(d.event.id);
  if (!r.calls.some((c) => c.match_id === matchId)) {
    r.calls.push({ call_id: `call-${r.calls.length + 2}`, match_id: matchId, table_number: m.tableNumber, called_at: new Date().toISOString(), by: "Sam Reyes" });
  }
}
export function judgeCallCancel(eventId: string, matchId: string) {
  const { d } = matchIn(eventId, matchId);
  const r = roomOf(d.event.id);
  r.calls = r.calls.filter((c) => c.match_id !== matchId);
}
export function judgeCallResolve(eventId: string, callId: string) {
  for (const r of eventId ? [roomOf(eventId)] : rooms.values()) r.calls = r.calls.filter((c) => c.call_id !== callId);
}

/** Final team standings for a stand-in team event (the Results screen reads them itself; here for the display). */
export const demoTeamStandings = (eventId: string) => {
  const d = demoOf(eventId);
  return d ? computeTeamStandings(d.teams, d.participants, d.rounds) : [];
};
export type { TopCut };
