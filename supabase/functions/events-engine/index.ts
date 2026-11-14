// events-engine: the one place Table 1's tournament rules run.
//   POST { action: "standings", event_id, token? } -> computed standings, plus team standings (and `clinched`) for team events, for
//                                                  anyone public.event_public lets in (link holders of non-private
//                                                  events, members, guests with their claim token)
//   POST { action: "seat_players", event_id }  -> random draft seats via rpc seat_event (organizers only; older builds)
//   POST { action: "pair_round", event_id }    -> pairs and opens the next round (organizers only): Swiss, then the
//                                                  top 8 quarterfinals, semifinals and final when events.top_cut = 8
//   POST { action: "repair_round", event_id, round_id, clear_results?, reason? }
//                                              -> pairs the latest, still active round again from the results as they
//                                                  are now (organizers only; contract/repair-round-2026-11-09.md)
//   POST { action: "placements", event_id } + x-t1-secret
//                                              -> writes a finished event's final places (public.event_placements);
//                                                  the database asks (contract/public-events-leagues-2026-11-13.md)
// Rules are the same files the web app ships (standings, pairings, seating, teams), so web and server agree.
import { createClient } from "npm:@supabase/supabase-js@2";
import { pairRound, type ProposedMatch } from "./pairings.ts";
import { pairRoundRobin, roundRobinRoster, roundRobinRounds } from "./roundrobin.ts";
import {
  bracket, draftRounds, nextStage, pairPlayoff, playoffStandings, stageOf, swissRounds, type Stage, type StagedRound,
} from "./playoffs.ts";
import {
  computeTeamStandings, membersOf, pairTeamDraftRound, pairTeamSwissRound, teamClinch, teamProblems, type Team,
} from "./teams.ts";
import { placementRows } from "./placements.ts";
import type { Match, MatchSide, Participant } from "./types.ts";

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

// deno-lint-ignore no-explicit-any
const toParticipant = (r: any): Participant => ({
  id: r.id, eventId: r.event_id, podId: r.pod_id, displayName: r.display_name,
  seat: r.seat, status: r.status, droppedInRound: r.dropped_in_round, userId: r.user_id,
  teamId: r.team_id ?? null, teamSlot: r.team_slot ?? null,
});
// deno-lint-ignore no-explicit-any
const toSide = (r: any): MatchSide => ({
  id: r.id, matchId: r.match_id, participantId: r.participant_id, side: r.side, gameWins: r.game_wins,
});
// deno-lint-ignore no-explicit-any
const toMatch = (r: any): Match => ({
  id: r.id, eventId: r.event_id, roundId: r.round_id, tableNumber: r.table_number, isBye: r.is_bye,
  gameDraws: r.game_draws, intentionalDraw: r.intentional_draw, status: r.status,
  sides: (r.match_sides ?? []).map(toSide).sort((a: MatchSide, b: MatchSide) => a.side - b.side),
});
// deno-lint-ignore no-explicit-any
const toRound = (r: any): StagedRound => ({
  id: r.id, eventId: r.event_id, number: r.number, status: r.status, stage: r.stage ?? "swiss",
  timerDurationSeconds: r.timer_duration_seconds, timerRemainingAtChange: r.timer_remaining_at_change,
  timerStatus: r.timer_status, timerLastStartedAt: r.timer_last_started_at,
  matches: (r.matches ?? []).map(toMatch),
});

async function loadEvent(eventId: string) {
  const [ev, parts, rounds, teams, pods] = await Promise.all([
    admin.from("events").select("*").eq("id", eventId).maybeSingle(),
    admin.from("participants").select("*").eq("event_id", eventId).order("seat"),
    admin.from("rounds").select("*, matches(*, match_sides(*))").eq("event_id", eventId).order("number"),
    admin.from("event_teams").select("*").eq("event_id", eventId).eq("active", true).order("display_order"),
    admin.from("pods").select("*").eq("event_id", eventId).order("display_order"),
  ]);
  for (const r of [ev, parts, rounds, teams, pods]) if (r.error) throw r.error;
  return {
    event: ev.data,
    participants: (parts.data ?? []).map(toParticipant),
    rounds: (rounds.data ?? []).map(toRound),
    teams: (teams.data ?? []).map((t): Team => ({ id: t.id, name: t.name, order: t.display_order })),
    // deno-lint-ignore no-explicit-any
    pods: (pods.data ?? []) as any[],
  };
}

const isTeamEvent = (event: { format_name?: string | null }) =>
  event.format_name === "team_draft" || event.format_name === "team_sealed";
const isDraft = (event: { format_name?: string | null }) =>
  event.format_name === "draft" || event.format_name === "team_draft";

async function callerIsOrganizer(eventId: string, authHeader: string) {
  // Checked with the caller's own token, against the same RLS helper the app uses.
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data, error } = await asCaller.rpc("is_event_organizer", { p_event_id: eventId });
  if (error) return { error: json({ error: error.message }, 401) };
  if (!data) return { error: json({ error: "Only organizers can do that" }, 403) };
  return { error: null };
}

// deno-lint-ignore no-explicit-any
function seatingView(participants: Participant[], pods: any[], teams: Team[]) {
  const teamName = new Map(teams.map((t) => [t.id, t.name]));
  return pods
    .map((pod) => ({
      pod_id: pod.id,
      name: pod.name,
      seats: participants
        .filter((p) => p.podId === pod.id && p.status === "active" && p.seat != null)
        .sort((a, b) => (a.seat ?? 0) - (b.seat ?? 0))
        .map((p) => ({ seat: p.seat, participant_id: p.id, display_name: p.displayName,
                       team: p.teamId ? teamName.get(p.teamId) ?? null : null })),
    }))
    .filter((pod) => pod.seats.length > 0);
}

/**
 * Draft seats before round 1, in one Postgres transaction: not drawn yet → public.seat_event draws every pod and
 * seat; drawn → public.seat_fill seats only the newcomers, so pods the organizer arranged by hand stay.
 */
async function writeSeats(eventId: string, drawn: boolean) {
  const { error } = await admin.rpc(drawn ? "seat_fill" : "seat_event", { p_event_id: eventId });
  if (error) throw new HttpError(409, error.message);
}

/** Sizes of the pods active players sit in (a draft's pods as seated). */
function seatedPodSizes(participants: Participant[]): number[] {
  const sizes = new Map<string, number>();
  for (const p of participants) {
    if (p.status !== "active") continue;
    sizes.set(p.podId ?? "", (sizes.get(p.podId ?? "") ?? 0) + 1);
  }
  return [...sizes.values()];
}

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

async function seatPlayers(eventId: string, authHeader: string) {
  // Kept for older builds; clients now call rpc seat_event directly. The caller's token goes straight
  // to Postgres, which checks the organizer and does the whole seating in one round trip.
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data, error } = await asCaller.rpc("seat_event", { p_event_id: eventId });
  if (error) {
    const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 : 409;
    return json({ error: error.message }, status);
  }
  return json(data);
}

/** Whoever public.event_public refuses (private events, demo, cancelled for non-members) gets nothing here either. */
async function callerCanSee(eventId: string, authHeader: string, token: string | null) {
  const asCaller = createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader || `Bearer ${anonKey}` } },
    auth: { persistSession: false },
  });
  const { error } = await asCaller.rpc("event_public", { p_event_id: eventId, p_token: token });
  if (!error) return null;
  return json({ error: "That event isn't available" }, error.code === "42501" ? 404 : 401);
}

async function standings(eventId: string, authHeader: string, token: string | null) {
  const refused = await callerCanSee(eventId, authHeader, token);
  if (refused) return refused;
  const { event, participants, rounds, teams, pods } = await loadEvent(eventId);
  if (!event) return json({ error: "That event isn't available" }, 404);
  const podOf = new Map(participants.map((p) => [p.id, p.podId]));
  // Tiebreakers are Swiss only; once the top 8 is cut, rank is the final order (playoffs.ts).
  const rows = playoffStandings(participants, rounds).map((s) => ({
    rank: s.rank,
    swiss_rank: s.swissRank,
    playoff: s.playoff,
    participant_id: s.participantId,
    display_name: s.displayName,
    pod_id: podOf.get(s.participantId) ?? null,
    status: s.status,
    match_points: s.matchPoints,
    match_wins: s.matchWins,
    match_losses: s.matchLosses,
    match_draws: s.matchDraws,
    byes: s.byes,
    omw: s.opponentMatchWinPct,
    gw: s.gameWinPct,
    ogw: s.opponentGameWinPct,
  }));
  const teamRows = isTeamEvent(event)
    ? computeTeamStandings(teams, participants, rounds).map((t) => ({
        rank: t.rank, team_id: t.teamId, name: t.name, points: t.points, wins: t.wins, losses: t.losses,
        draws: t.draws, byes: t.byes, match_wins: t.matchWins, gw: t.gameWinPct,
        members: t.members.map((m) => ({ participant_id: m.participantId, display_name: m.displayName,
                                         slot: m.slot, match_wins: m.matchWins, match_losses: m.matchLosses,
                                         match_draws: m.matchDraws, status: m.status })),
      }))
    : null;
  const clinch = isTeamEvent(event) && ["seated", "in_progress"].includes(event.status)
    ? teamClinch(teams, participants, rounds, event.number_of_rounds)
    : null;
  return json({
    event_id: eventId, current_round: event.current_round, standings: rows, teams: teamRows,
    top_cut: event.top_cut ?? 0, bracket: bracket(participants, rounds),
    // Team events: the team that can no longer be caught, so the organizer may finish early.
    clinched: clinch && { team_id: clinch.teamId, name: clinch.name, match_wins: clinch.matchWins,
                          opponent_match_wins: clinch.opponentMatchWins, remaining: clinch.remaining },
    seating: isDraft(event) ? seatingView(participants, pods, teams) : null,
    pod_pairing: event.format_name === "draft" ? event.pod_pairing ?? "cross" : null,
  });
}

/** Final places for a finished event, asked for by the database (x-t1-secret) when it completes or a result is
 * corrected afterwards. Written through public.event_placements_put, which ignores events that aren't over. */
async function placements(eventId: string, secret: string) {
  const { data: ok } = await admin.rpc("live_push_secret_ok", { p_secret: secret });
  if (ok !== true) return json({ error: "Not allowed" }, 403);
  const { event, participants, rounds, teams } = await loadEvent(eventId);
  if (!event) return json({ error: "That event isn't available" }, 404);
  const rows = placementRows(participants, rounds, teams, isTeamEvent(event));
  const { data, error } = await admin.rpc("event_placements_put", { p_event_id: eventId, p_rows: rows });
  if (error) return json({ error: error.message }, 500);
  return json(data);
}

/** Re-pair: the latest round, still active, taken back (public.withdraw_round) once its new pairings are known. */
type Repair = { roundId: string; clearResults: boolean; reason: string | null };

async function pairNextRound(eventId: string, authHeader: string, repair: Repair | null = null) {
  const auth = await callerIsOrganizer(eventId, authHeader);
  if (auth.error) return auth.error;

  let { event, participants, rounds, teams, pods } = await loadEvent(eventId);
  if (!event) return json({ error: "Event not found" }, 404);
  if (event.status === "cancelled") return json({ error: "That event was cancelled" }, 409);
  if (["completed", "archived"].includes(event.status)) return json({ error: "That event has finished" }, 409);
  if (repair) {
    const latest = rounds.at(-1);
    if (!latest || latest.id !== repair.roundId) return json({ error: "Only the latest round can be re-paired" }, 409);
    if (latest.status !== "active") return json({ error: `Round ${latest.number} is already recorded` }, 409);
    const entered = latest.matches.filter((m) => !m.isBye && m.status !== "pending").length;
    if (entered > 0 && !repair.clearResults) {
      return json({ error: `Round ${latest.number} has ${entered} ${entered === 1 ? "result" : "results"} in. Clear them to re-pair.`,
                    code: "has_results", results: entered }, 409);
    }
  }
  // Re-pairing works out the round as if it had never been paired; nothing is written until the pairings are known.
  const withoutRepaired = (all: StagedRound[]) => repair ? all.filter((r) => r.id !== repair.roundId) : all;
  rounds = withoutRepaired(rounds);
  const open = rounds.find((r) => r.status === "active");
  if (open) {
    const unreported = open.matches.filter((m) => !m.isBye && m.status === "pending").length;
    if (unreported > 0) return json({ error: `Round ${open.number} still has ${unreported} unreported matches` }, 409);
  }
  const roundNumber = (rounds.at(-1)?.number ?? 0) + 1;
  // Roto: rounds start once every pick is in. Round robin: the roster at round 1 fixes the number of rounds.
  if (event.format_name === "roto" && roundNumber === 1) {
    const { data: draft, error } = await admin.from("roto_drafts").select("finished_at").eq("event_id", eventId).maybeSingle();
    if (error) throw error;
    if (!draft?.finished_at) return json({ error: "Finish the draft before pairing round 1" }, 409);
  }
  // Drafts pair round 1 across the table: draw the pods if the organizer hasn't (in setup, seats are only
  // placeholders), or seat whoever joined after the draw.
  if (roundNumber === 1 && isDraft(event)
      && (event.status === "setup" || participants.some((p) => p.status === "active" && p.seat == null))) {
    await writeSeats(eventId, event.status === "seated");
    ({ event, participants, rounds, teams, pods } = await loadEvent(eventId));
    rounds = withoutRepaired(rounds);
  }
  const roundRobin = event.pairing === "round_robin";
  const active = participants.filter((p) => p.status === "active").length;
  const podPairing: "pod" | "cross" = event.format_name === "draft" && event.pod_pairing === "pod" ? "pod" : "cross";
  // Auto rounds: round 1 fixes the Swiss count from the players there (the database keeps it in step until then);
  // a draft paired inside pods plays enough rounds for its largest pod.
  const swissTotal = event.auto_rounds && roundNumber === 1
    ? (event.format_name === "draft" ? draftRounds(seatedPodSizes(participants), podPairing) : swissRounds(active))
    : event.number_of_rounds;
  const totalRounds = roundRobin ? roundRobinRounds(roundRobinRoster(participants).length) : swissTotal;
  // Swiss events of players go on to the top 8 when there is one; team events and round robin stop at their count.
  let stage: Stage = "swiss";
  if (!roundRobin && !isTeamEvent(event)) {
    const next = nextStage(rounds, swissTotal, event.top_cut ?? 0, active);
    if (!next) return json({ error: "All rounds have been played" }, 409);
    stage = next;
  } else if (roundNumber > totalRounds) {
    return json({ error: "All rounds have been played" }, 409);
  }

  if (isTeamEvent(event)) {
    const problem = teamProblems(teams, participants, event.team_size ?? 3, event.format_name);
    if (problem) return json({ error: problem }, 409);
  }
  // Required decklists: every active player's list is in before round 1 (contract/scheduled-events-2026-10-27.md §9).
  if (roundNumber === 1 && event.decklists === "required") {
    const { data: lists, error } = await admin.from("event_decklists").select("participant_id").eq("event_id", eventId);
    if (error) throw error;
    const sent = new Set((lists ?? []).map((l) => l.participant_id));
    const missing = participants.filter((p) => p.status === "active" && !sent.has(p.id)).length;
    if (missing > 0) {
      return json({ error: `${missing} ${missing === 1 ? "player hasn't" : "players haven't"} sent a decklist` }, 409);
    }
  }
  let proposed: ProposedMatch[];
  if (stage !== "swiss") {
    try {
      proposed = pairPlayoff(stage, participants, rounds);
    } catch (e) {
      return json({ error: e instanceof Error ? e.message : String(e) }, 409);
    }
  } else if (roundRobin) {
    proposed = pairRoundRobin(participants, roundNumber);
  } else if (event.format_name === "team_draft") {
    proposed = pairTeamDraftRound(membersOf(teams[0].id, participants), membersOf(teams[1].id, participants), roundNumber);
  } else if (event.format_name === "team_sealed") {
    proposed = pairTeamSwissRound(teams, participants, rounds, roundNumber);
  } else {
    proposed = pairRound({
      participants, rounds: rounds.filter((r) => stageOf(r) === "swiss"), roundNumber,
      draftSeating: event.format_name === "draft",
      podOrder: pods.map((p) => p.id),
      podPairing,
    });
  }
  if (proposed.length === 0) return json({ error: "No active players to pair" }, 409);

  if (repair) {
    // As the organizer, so withdraw_round's own checks and audit row apply; one transaction.
    const asCaller = createClient(url, anonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false },
    });
    const { error } = await asCaller.rpc("withdraw_round", {
      p_round_id: repair.roundId, p_clear_results: repair.clearResults, p_reason: repair.reason,
    });
    if (error) {
      const status = error.code === "42501" ? 403 : error.code === "P0002" ? 404 : 409;
      return json({ error: error.message, ...(error.code === "PT409" ? { code: "has_results" } : {}) }, status);
    }
  }

  if (open) {
    const { error } = await admin.from("rounds")
      .update({ status: "recorded", recorded_at: new Date().toISOString() }).eq("id", open.id);
    if (error) throw error;
  }

  const now = new Date();
  const endsAt = new Date(now.getTime() + event.round_length_seconds * 1000);
  const { data: round, error: roundError } = await admin.from("rounds").insert({
    event_id: eventId, number: roundNumber, status: "active", stage,
    timer_duration_seconds: event.round_length_seconds, timer_remaining_at_change: event.round_length_seconds,
    timer_status: "running", timer_last_started_at: now.toISOString(), started_at: now.toISOString(),
    pairings_published_at: now.toISOString(), timer_ends_at: endsAt.toISOString(),
  }).select().single();
  if (roundError) throw roundError;

  // Drafts with several pods: a match inside one pod carries it (across pods and playoffs carry none).
  const podOf = new Map(participants.map((p) => [p.id, p.podId]));
  const podsInPlay = new Set(participants.filter((p) => p.status === "active").map((p) => p.podId ?? ""));
  const matchPod = (m: ProposedMatch) => {
    if (event.format_name !== "draft" || stage !== "swiss" || podsInPlay.size < 2) return null;
    const a = podOf.get(m.side0ParticipantId) ?? null;
    return m.side1ParticipantId && podOf.get(m.side1ParticipantId) !== a ? null : a;
  };
  const { data: matchRows, error: matchError } = await admin.from("matches").insert(
    proposed.map((m) => ({
      event_id: eventId, round_id: round.id, table_number: m.tableNumber, is_bye: m.isBye,
      status: m.isBye ? "confirmed" : "pending", pod_id: matchPod(m),
    })),
  ).select("id, table_number");
  if (matchError) throw matchError;
  const idByTable = new Map((matchRows ?? []).map((r) => [r.table_number, r.id]));

  const sides = proposed.flatMap((m) => {
    const matchId = idByTable.get(m.tableNumber)!;
    const rows = [{ match_id: matchId, participant_id: m.side0ParticipantId, side: 0, game_wins: m.isBye ? 2 : 0 }];
    if (m.side1ParticipantId) rows.push({ match_id: matchId, participant_id: m.side1ParticipantId, side: 1, game_wins: 0 });
    return rows;
  });
  const { error: sideError } = await admin.from("match_sides").insert(sides);
  if (sideError) throw sideError;

  const { error: eventError } = await admin.from("events")
    .update({
      current_round: roundNumber, status: "in_progress", updated_at: now.toISOString(),
      ...(roundRobin || (event.auto_rounds && roundNumber === 1) ? { number_of_rounds: totalRounds } : {}),
    }).eq("id", eventId);
  if (eventError) throw eventError;

  // One push per round, to every account seated in a match (the notify-worker expands it per device).
  const userIds = (await admin.from("participants").select("user_id")
    .in("id", proposed.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId]).filter(Boolean) as string[]))
    .data?.map((r) => r.user_id).filter(Boolean) ?? [];
  if (userIds.length) {
    await admin.rpc("enqueue_notification", {
      p_kind: "round.paired", p_event_id: eventId, p_user_ids: userIds,
      p_data: { round: roundNumber, stage, ends_at: endsAt.toISOString(), ...(repair ? { repaired: true } : {}) },
    });
  }

  await admin.from("audit_log").insert({
    event_id: eventId, action: "round.paired", target_type: "round", target_id: round.id,
    after: { round: roundNumber, stage, tables: proposed.length, ...(repair ? { repaired: true } : {}),
             ...(event.format_name === "draft" ? { pod_pairing: podPairing, pods: seatedPodSizes(participants).length } : {}) },
  });

  return json({
    round_id: round.id, round_number: roundNumber, stage, timer_ends_at: endsAt.toISOString(), matches: proposed,
    ...(repair ? { repaired: true } : {}),
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const eventId = String(body.event_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(eventId)) return json({ error: "event_id is required" }, 400);
    if (body.action === "standings") {
      const token = typeof body.token === "string" && body.token ? body.token : null;
      return await standings(eventId, req.headers.get("Authorization") ?? "", token);
    }
    if (body.action === "placements") {
      return await placements(eventId, req.headers.get("x-t1-secret") ?? "");
    }
    if (body.action === "pair_round" || body.action === "seat_players" || body.action === "repair_round") {
      const auth = req.headers.get("Authorization") ?? "";
      if (!auth.startsWith("Bearer ")) return json({ error: "Sign in required" }, 401);
      if (body.action === "repair_round") {
        const roundId = String(body.round_id ?? "");
        if (!/^[0-9a-f-]{36}$/i.test(roundId)) return json({ error: "round_id is required" }, 400);
        const reason = typeof body.reason === "string" && body.reason.trim() ? body.reason.trim().slice(0, 200) : null;
        return await pairNextRound(eventId, auth, { roundId, clearResults: body.clear_results === true, reason });
      }
      return body.action === "pair_round" ? await pairNextRound(eventId, auth) : await seatPlayers(eventId, auth);
    }
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
