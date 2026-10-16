// events-engine: the one place Table 1's tournament rules run.
//   POST { action: "standings", event_id }     -> computed standings, plus team standings for team events (public)
//   POST { action: "seat_players", event_id }  -> random draft seats via rpc seat_event (organizers only; older builds)
//   POST { action: "pair_round", event_id }    -> pairs and opens the next round (organizers only)
// Rules are the same files the web app ships (standings, pairings, seating, teams), so web and server agree.
import { createClient } from "npm:@supabase/supabase-js@2";
import { computeStandings } from "./standings.ts";
import { pairRound, type ProposedMatch } from "./pairings.ts";
import { pairRoundRobin, roundRobinRoster, roundRobinRounds } from "./roundrobin.ts";
import { computeTeamStandings, membersOf, pairTeamDraftRound, pairTeamSwissRound, teamProblems, type Team } from "./teams.ts";
import type { Match, MatchSide, Participant, RoundWithMatches } from "./types.ts";

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
const toRound = (r: any): RoundWithMatches => ({
  id: r.id, eventId: r.event_id, number: r.number, status: r.status,
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

/** Draft seats for every active player, in one Postgres transaction (public.seat_event). */
async function writeSeats(eventId: string) {
  const { error } = await admin.rpc("seat_event", { p_event_id: eventId });
  if (error) throw new HttpError(409, error.message);
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

async function standings(eventId: string) {
  const { event, participants, rounds, teams, pods } = await loadEvent(eventId);
  if (!event) return json({ error: "Event not found" }, 404);
  const rows = computeStandings(participants, rounds).map((s) => ({
    rank: s.rank,
    participant_id: s.participantId,
    display_name: s.displayName,
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
                                         slot: m.slot, match_wins: m.matchWins, status: m.status })),
      }))
    : null;
  return json({
    event_id: eventId, current_round: event.current_round, standings: rows, teams: teamRows,
    seating: isDraft(event) ? seatingView(participants, pods, teams) : null,
  });
}

async function pairNextRound(eventId: string, authHeader: string) {
  const auth = await callerIsOrganizer(eventId, authHeader);
  if (auth.error) return auth.error;

  let { event, participants, rounds, teams, pods } = await loadEvent(eventId);
  if (!event) return json({ error: "Event not found" }, 404);
  if (event.status === "cancelled") return json({ error: "That event was cancelled" }, 409);
  if (["completed", "archived"].includes(event.status)) return json({ error: "That event has finished" }, 409);
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
  const roundRobin = event.pairing === "round_robin";
  const totalRounds = roundRobin ? roundRobinRounds(roundRobinRoster(participants).length) : event.number_of_rounds;
  if (roundNumber > totalRounds) return json({ error: "All rounds have been played" }, 409);

  if (isTeamEvent(event)) {
    const problem = teamProblems(teams, participants, event.team_size ?? 3, event.format_name);
    if (problem) return json({ error: problem }, 409);
  }
  // Drafts pair round 1 across the table, so seat everyone first if the organizer hasn't.
  if (roundNumber === 1 && isDraft(event) && participants.some((p) => p.status === "active" && p.seat == null)) {
    await writeSeats(eventId);
    ({ event, participants, rounds, teams, pods } = await loadEvent(eventId));
  }

  let proposed: ProposedMatch[];
  if (roundRobin) {
    proposed = pairRoundRobin(participants, roundNumber);
  } else if (event.format_name === "team_draft") {
    proposed = pairTeamDraftRound(membersOf(teams[0].id, participants), membersOf(teams[1].id, participants), roundNumber);
  } else if (event.format_name === "team_sealed") {
    proposed = pairTeamSwissRound(teams, participants, rounds, roundNumber);
  } else {
    proposed = pairRound({
      participants, rounds, roundNumber,
      draftSeating: event.format_name === "draft",
      podOrder: pods.map((p) => p.id),
    });
  }
  if (proposed.length === 0) return json({ error: "No active players to pair" }, 409);

  if (open) {
    const { error } = await admin.from("rounds")
      .update({ status: "recorded", recorded_at: new Date().toISOString() }).eq("id", open.id);
    if (error) throw error;
  }

  const now = new Date();
  const endsAt = new Date(now.getTime() + event.round_length_seconds * 1000);
  const { data: round, error: roundError } = await admin.from("rounds").insert({
    event_id: eventId, number: roundNumber, status: "active",
    timer_duration_seconds: event.round_length_seconds, timer_remaining_at_change: event.round_length_seconds,
    timer_status: "running", timer_last_started_at: now.toISOString(), started_at: now.toISOString(),
    pairings_published_at: now.toISOString(), timer_ends_at: endsAt.toISOString(),
  }).select().single();
  if (roundError) throw roundError;

  const { data: matchRows, error: matchError } = await admin.from("matches").insert(
    proposed.map((m) => ({
      event_id: eventId, round_id: round.id, table_number: m.tableNumber, is_bye: m.isBye,
      status: m.isBye ? "confirmed" : "pending",
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
      ...(roundRobin ? { number_of_rounds: totalRounds } : {}),
    }).eq("id", eventId);
  if (eventError) throw eventError;

  // One push per round, to every account seated in a match (the notify-worker expands it per device).
  const userIds = (await admin.from("participants").select("user_id")
    .in("id", proposed.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId]).filter(Boolean) as string[]))
    .data?.map((r) => r.user_id).filter(Boolean) ?? [];
  if (userIds.length) {
    await admin.rpc("enqueue_notification", {
      p_kind: "round.paired", p_event_id: eventId, p_user_ids: userIds,
      p_data: { round: roundNumber, ends_at: endsAt.toISOString() },
    });
  }

  await admin.from("audit_log").insert({
    event_id: eventId, action: "round.paired", target_type: "round", target_id: round.id,
    after: { round: roundNumber, tables: proposed.length },
  });

  return json({ round_id: round.id, round_number: roundNumber, timer_ends_at: endsAt.toISOString(), matches: proposed });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const eventId = String(body.event_id ?? "");
    if (!/^[0-9a-f-]{36}$/i.test(eventId)) return json({ error: "event_id is required" }, 400);
    if (body.action === "standings") return await standings(eventId);
    if (body.action === "pair_round" || body.action === "seat_players") {
      const auth = req.headers.get("Authorization") ?? "";
      if (!auth.startsWith("Bearer ")) return json({ error: "Sign in required" }, 401);
      return body.action === "pair_round" ? await pairNextRound(eventId, auth) : await seatPlayers(eventId, auth);
    }
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    if (e instanceof HttpError) return json({ error: e.message }, e.status);
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
