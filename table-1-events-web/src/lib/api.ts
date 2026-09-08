import { supabase } from "./supabaseClient";
import type {
  Match,
  MatchSide,
  Participant,
  RoundWithMatches,
  Table1Event,
} from "./types";
import type { ProposedMatch } from "./pairings";

export interface EventBundle {
  event: Table1Event;
  participants: Participant[];
  rounds: RoundWithMatches[];
}

/* ── row mapping ─────────────────────────────────────────────────────────── */

const toEvent = (r: any): Table1Event => ({
  id: r.id,
  shortCode: r.short_code,
  name: r.name,
  format: r.format,
  status: r.status,
  numberOfRounds: r.number_of_rounds,
  currentRound: r.current_round,
  roundLengthSeconds: r.round_length_seconds,
  allowPlayerReporting: r.allow_player_reporting,
  createdBy: r.created_by,
});

const toParticipant = (r: any): Participant => ({
  id: r.id,
  eventId: r.event_id,
  podId: r.pod_id,
  displayName: r.display_name,
  seat: r.seat,
  status: r.status,
  droppedInRound: r.dropped_in_round,
});

const toSide = (r: any): MatchSide => ({
  id: r.id,
  matchId: r.match_id,
  participantId: r.participant_id,
  side: r.side,
  gameWins: r.game_wins,
});

const toMatch = (r: any): Match => ({
  id: r.id,
  eventId: r.event_id,
  roundId: r.round_id,
  tableNumber: r.table_number,
  isBye: r.is_bye,
  gameDraws: r.game_draws,
  intentionalDraw: r.intentional_draw,
  status: r.status,
  sides: (r.match_sides ?? []).map(toSide).sort((a: MatchSide, b: MatchSide) => a.side - b.side),
});

const toRound = (r: any): RoundWithMatches => ({
  id: r.id,
  eventId: r.event_id,
  number: r.number,
  status: r.status,
  timerDurationSeconds: r.timer_duration_seconds,
  timerRemainingAtChange: r.timer_remaining_at_change,
  timerStatus: r.timer_status,
  timerLastStartedAt: r.timer_last_started_at,
  matches: (r.matches ?? []).map(toMatch).sort(
    (a: Match, b: Match) => (a.tableNumber ?? 0) - (b.tableNumber ?? 0),
  ),
});

/* ── reads ───────────────────────────────────────────────────────────────── */

export async function fetchEventIdByCode(code: string): Promise<string | null> {
  const { data, error } = await supabase
    .from("events")
    .select("id")
    .ilike("short_code", code.trim())
    .maybeSingle();
  if (error) throw error;
  return data?.id ?? null;
}

export async function fetchBundle(eventId: string): Promise<EventBundle> {
  const [eventRes, participantRes, roundRes] = await Promise.all([
    supabase.from("events").select("*").eq("id", eventId).single(),
    supabase.from("participants").select("*").eq("event_id", eventId).order("seat"),
    supabase
      .from("rounds")
      .select("*, matches(*, match_sides(*))")
      .eq("event_id", eventId)
      .order("number"),
  ]);
  if (eventRes.error) throw eventRes.error;
  if (participantRes.error) throw participantRes.error;
  if (roundRes.error) throw roundRes.error;

  return {
    event: toEvent(eventRes.data),
    participants: (participantRes.data ?? []).map(toParticipant),
    rounds: (roundRes.data ?? []).map(toRound),
  };
}

/** Everything in an event changes together, so one subscription refetches all. */
export function subscribeToEvent(eventId: string, onChange: () => void) {
  const channel = supabase.channel(`event:${eventId}`);
  for (const table of ["events", "participants", "rounds", "matches", "match_sides"]) {
    channel.on(
      "postgres_changes",
      { event: "*", schema: "public", table },
      () => onChange(),
    );
  }
  channel.subscribe();
  return () => {
    supabase.removeChannel(channel);
  };
}

/* ── writes ──────────────────────────────────────────────────────────────── */

export async function createEvent(input: {
  name: string;
  format?: string;
  rounds: number;
  roundSeconds: number;
  playerNames: string[];
}): Promise<{ eventId: string; shortCode: string }> {
  const { data, error } = await supabase.rpc("create_event", {
    p_name: input.name,
    p_format: input.format ?? "draft",
    p_rounds: input.rounds,
    p_round_seconds: input.roundSeconds,
    p_player_names: input.playerNames,
  });
  if (error) throw error;
  return { eventId: data.event_id, shortCode: data.short_code };
}

export async function joinEvent(code: string, displayName: string) {
  const { data, error } = await supabase.rpc("join_event", {
    p_code: code,
    p_display_name: displayName,
  });
  if (error) throw error;
  return data as {
    event_id: string;
    short_code: string;
    participant_id: string;
    token: string;
  };
}

/** Player-side reporting. The token proves they are on the match. */
export async function reportResultAsPlayer(
  matchId: string,
  token: string,
  side0Wins: number,
  side1Wins: number,
  draws = 0,
) {
  const { error } = await supabase.rpc("report_result", {
    p_match_id: matchId,
    p_token: token,
    p_side0_wins: side0Wins,
    p_side1_wins: side1Wins,
    p_draws: draws,
  });
  if (error) throw error;
}

/** Organizer-side entry and correction. Goes straight through RLS. */
export async function setResultAsOrganizer(
  match: Match,
  side0Wins: number,
  side1Wins: number,
  draws = 0,
) {
  const side0 = match.sides.find((s) => s.side === 0);
  const side1 = match.sides.find((s) => s.side === 1);

  if (side0) {
    const { error } = await supabase
      .from("match_sides")
      .update({ game_wins: side0Wins })
      .eq("id", side0.id);
    if (error) throw error;
  }
  if (side1) {
    const { error } = await supabase
      .from("match_sides")
      .update({ game_wins: side1Wins })
      .eq("id", side1.id);
    if (error) throw error;
  }
  const { error } = await supabase
    .from("matches")
    .update({
      game_draws: draws,
      status: "confirmed",
      reported_at: new Date().toISOString(),
    })
    .eq("id", match.id);
  if (error) throw error;
}

export async function startRound(
  eventId: string,
  roundNumber: number,
  proposed: ProposedMatch[],
  durationSeconds: number,
): Promise<void> {
  const { data: roundRow, error: roundError } = await supabase
    .from("rounds")
    .insert({
      event_id: eventId,
      number: roundNumber,
      status: "active",
      timer_duration_seconds: durationSeconds,
      timer_remaining_at_change: durationSeconds,
      timer_status: "paused",
      started_at: new Date().toISOString(),
    })
    .select()
    .single();
  if (roundError) throw roundError;

  const { data: matchRows, error: matchError } = await supabase
    .from("matches")
    .insert(
      proposed.map((m) => ({
        event_id: eventId,
        round_id: roundRow.id,
        table_number: m.tableNumber,
        is_bye: m.isBye,
        status: m.isBye ? "confirmed" : "pending",
      })),
    )
    .select();
  if (matchError) throw matchError;

  const sides = proposed.flatMap((m, i) => {
    const matchId = matchRows[i].id;
    const rows = [
      {
        match_id: matchId,
        participant_id: m.side0ParticipantId,
        side: 0,
        game_wins: m.isBye ? 2 : 0,
      },
    ];
    if (m.side1ParticipantId) {
      rows.push({
        match_id: matchId,
        participant_id: m.side1ParticipantId,
        side: 1,
        game_wins: 0,
      });
    }
    return rows;
  });
  const { error: sideError } = await supabase.from("match_sides").insert(sides);
  if (sideError) throw sideError;

  const { error: eventError } = await supabase
    .from("events")
    .update({ current_round: roundNumber, status: "in_progress", updated_at: new Date().toISOString() })
    .eq("id", eventId);
  if (eventError) throw eventError;
}

export async function recordRound(eventId: string, roundId: string, isFinal: boolean) {
  const { error } = await supabase
    .from("rounds")
    .update({ status: "recorded", recorded_at: new Date().toISOString() })
    .eq("id", roundId);
  if (error) throw error;
  if (isFinal) {
    const { error: e2 } = await supabase
      .from("events")
      .update({ status: "completed", updated_at: new Date().toISOString() })
      .eq("id", eventId);
    if (e2) throw e2;
  }
}

export async function setTimer(
  roundId: string,
  patch: {
    timer_status?: "running" | "paused";
    timer_remaining_at_change?: number;
    timer_last_started_at?: string | null;
    timer_duration_seconds?: number;
  },
) {
  const { error } = await supabase.from("rounds").update(patch).eq("id", roundId);
  if (error) throw error;
}

export async function setParticipantStatus(
  participantId: string,
  status: "active" | "dropped",
  roundNumber: number | null,
) {
  const { error } = await supabase
    .from("participants")
    .update({ status, dropped_in_round: status === "dropped" ? roundNumber : null })
    .eq("id", participantId);
  if (error) throw error;
}

export async function addParticipant(eventId: string, podId: string | null, displayName: string, seat: number) {
  const { error } = await supabase
    .from("participants")
    .insert({ event_id: eventId, pod_id: podId, display_name: displayName, seat });
  if (error) throw error;
}

export async function writeAudit(entry: {
  eventId: string;
  action: string;
  targetType?: string;
  targetId?: string;
  reason?: string;
  before?: unknown;
  after?: unknown;
}) {
  await supabase.from("audit_log").insert({
    event_id: entry.eventId,
    action: entry.action,
    target_type: entry.targetType,
    target_id: entry.targetId,
    reason: entry.reason,
    before: entry.before ?? null,
    after: entry.after ?? null,
  });
}
