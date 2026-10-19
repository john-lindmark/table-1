import { supabase } from "./supabaseClient";
import type { User } from "@supabase/supabase-js";
import { capture, signInStarted } from "./telemetry";
import type {
  AccountOverview,
  DraftableSet,
  EventFormat,
  EventTeam,
  FormatName,
  HomeData,
  LiveSnapshot,
  Match,
  MatchSide,
  Participant,
  RoundWithMatches,
  SeatingPod,
  SuggestedPlayer,
  Table1Event,
  TrackerMode,
} from "./types";
import type { Side, TrackerClock, TrackerGame, TrackerOp } from "./tracker";

export interface EventBundle {
  event: Table1Event;
  participants: Participant[];
  rounds: RoundWithMatches[];
}

/** Readable text for any thrown value (PostgrestError is a plain object with `message`). */
export function errorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

/* ── row mapping ─────────────────────────────────────────────────────────── */

/** Pre-2026-10-13 rows have only the old `format`; map it onto the typed format. */
const LEGACY_FORMAT: Record<EventFormat, FormatName> = {
  draft: "draft",
  sealed: "sealed",
  cube: "draft",
  constructed: "other_constructed",
};
const LEGACY_LABEL: Record<EventFormat, string> = {
  draft: "Draft",
  sealed: "Sealed",
  cube: "Cube draft",
  constructed: "Constructed",
};

/** What to show wherever an event's format appears. */
export function formatLabelOf(row: { format_label?: string | null; format?: string | null }): string {
  if (row.format_label) return row.format_label;
  const f = row.format as EventFormat | undefined;
  return (f && LEGACY_LABEL[f]) || (row.format ?? "");
}

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
  cancelReason: r.cancel_reason ?? null,
  formatName: (r.format_name ?? LEGACY_FORMAT[r.format as EventFormat] ?? "draft") as FormatName,
  formatLabel: formatLabelOf(r),
  eventType: r.event_type ?? (r.format === "constructed" ? "constructed" : "limited"),
  teamSize: r.team_size ?? null,
  setName: r.set_name ?? null,
  cubeName: r.cube_name ?? null,
  cubeUrl: r.cube_url ?? null,
  setCode: r.set_code ?? null,
  formatOther: r.format_other ?? null,
  cancelledAt: r.cancelled_at ?? null,
  updatedAt: r.updated_at ?? null,
  showClock: r.show_clock ?? true,
  autoName: r.auto_name ?? false,
  pairing: r.pairing === "round_robin" ? "round_robin" : "swiss",
});

const toParticipant = (r: any): Participant => ({
  id: r.id,
  eventId: r.event_id,
  podId: r.pod_id,
  displayName: r.display_name,
  seat: r.seat,
  status: r.status,
  droppedInRound: r.dropped_in_round,
  userId: r.user_id ?? null,
  teamId: r.team_id ?? null,
  teamSlot: r.team_slot ?? null,
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
  version: r.version ?? 0,
  disputed: r.disputed ?? false,
  reportedByUser: r.reported_by_user ?? null,
  reportedByParticipant: r.reported_by_participant ?? null,
  resultSource: r.result_source ?? null,
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
  timerEndsAt: r.timer_ends_at ?? null,
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

/**
 * Everything in an event changes together, so one subscription refetches all. A single write can touch
 * many rows (seating updates every participant), so a burst of changes becomes one refetch.
 */
export function subscribeToEvent(eventId: string, onChange: () => void) {
  const channel = supabase.channel(`event:${eventId}`);
  let timer: number | undefined;
  const changed = () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(onChange, 120);
  };
  const filters: [string, string][] = [
    ["events", `id=eq.${eventId}`],
    ["participants", `event_id=eq.${eventId}`],
    ["rounds", `event_id=eq.${eventId}`],
    ["matches", `event_id=eq.${eventId}`],
    ["match_sides", `event_id=eq.${eventId}`],
  ];
  for (const [table, filter] of filters) {
    channel.on("postgres_changes", { event: "*", schema: "public", table, filter }, changed);
  }
  channel.subscribe();
  return () => {
    window.clearTimeout(timer);
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
  // A code that leads nowhere joinable comes back as {error, message} (so the server's miss count sticks).
  if (data?.error) throw new Error(data.message ?? "No event found with that code");
  capture("event_joined", { via: "link" });
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
  capture("match_reported", { status: "unknown", games: side0Wins + side1Wins + draws, draws });
}

/**
 * Organizer-side entry and correction. Goes through set_match_result so the change is
 * versioned, audited with a reason, and applied to lifetime records and head-to-head.
 */
export async function setResultAsOrganizer(
  match: Match,
  side0Wins: number,
  side1Wins: number,
  draws = 0,
  reason = "Entered by organizer",
) {
  const { error } = await supabase.rpc("set_match_result", {
    p_match_id: match.id,
    p_side0_wins: side0Wins,
    p_side1_wins: side1Wins,
    p_draws: draws,
    p_reason: reason,
  });
  if (error) throw error;
  capture("result_overridden");
}

/* ── V1: accounts, QR join, results, records ─────────────────────────────── */

export type OAuthProvider = "apple" | "google";

/** Apple or Google, then straight back to the page that asked. */
export async function signInWith(provider: OAuthProvider, returnTo = window.location.href) {
  signInStarted(provider);
  const { error } = await supabase.auth.signInWithOAuth({
    provider,
    options: { redirectTo: returnTo },
  });
  if (error) {
    capture("sign_in_failed", { method: provider, reason: "error" });
    throw error;
  }
}

/** Ends the session here. Telemetry resets on the SIGNED_OUT that follows. */
export async function signOut() {
  capture("signed_out", { reason: "user" });
  await supabase.auth.signOut();
}

/** Email accounts start without a name; one is required before the app opens. Apple and Google bring theirs. */
export function needsName(user: User | null | undefined): boolean {
  const ids = user?.identities ?? [];
  if (!user || ids.length === 0 || !ids.every((i) => i.provider === "email")) return false;
  return !String(user.user_metadata?.first_name ?? "").trim();
}

/** First and last name: kept on the account and shown in events as "First Last". */
export async function saveName(userId: string, first: string, last: string) {
  const f = first.trim();
  const l = last.trim();
  const full = `${f} ${l}`;
  await setDisplayName(userId, full);
  const { error } = await supabase.auth.updateUser({ data: { first_name: f, last_name: l, full_name: full } });
  if (error) throw error;
}

/** Where the email link should land after signing in, when it is opened in this browser. */
const EMAIL_RETURN_KEY = "t1.signin.returnTo";

/** Sends the sign-in email: a link (opens the app when installed) and the same one-time code. */
export async function sendEmailCode(email: string, returnTo = window.location.pathname + window.location.search) {
  signInStarted("email");
  const { error } = await supabase.auth.signInWithOtp({ email, options: { shouldCreateUser: true } });
  if (error) throw error;
  try {
    localStorage.setItem(EMAIL_RETURN_KEY, returnTo);
  } catch {
    /* private mode: the link lands on Home */
  }
}

/** The code typed from the email. */
export async function verifyEmailCode(email: string, code: string) {
  const { error } = await supabase.auth.verifyOtp({ email, token: code, type: "email" });
  if (error) throw error;
}

/** The email's link (/auth/confirm?token_hash=…&type=email). Returns where to go next. */
export async function verifyEmailLink(tokenHash: string): Promise<string> {
  const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: "email" });
  if (error) throw error;
  let next = "/";
  try {
    next = localStorage.getItem(EMAIL_RETURN_KEY) || "/";
    localStorage.removeItem(EMAIL_RETURN_KEY);
  } catch {
    /* ignore */
  }
  // Same-origin paths only.
  return next.startsWith("/") && !next.startsWith("//") ? next : "/";
}

export interface JoinQr {
  shortCode: string;
  secret: string;
  url: string;
}

/** The organizer's QR payload. Rotating invalidates every code shown before. */
export async function getJoinQr(eventId: string, rotate = false): Promise<JoinQr> {
  const { data, error } = await supabase.rpc("get_join_qr", { p_event_id: eventId, p_rotate: rotate });
  if (error) throw error;
  // Point the QR at this web origin so it also works on staging and localhost.
  const url = `${window.location.origin}/j/${data.short_code}?s=${data.secret}`;
  return { shortCode: data.short_code, secret: data.secret, url };
}

export async function joinEventByQr(shortCode: string, secret: string) {
  const { data, error } = await supabase.rpc("join_event_qr", { p_short_code: shortCode, p_secret: secret });
  if (error) throw error;
  // The web only joins from /j/ links (a phone camera or a shared URL), like a universal link in the apps.
  const r = data as { event_id: string; participant_id: string; already_joined: boolean };
  if (!r.already_joined) capture("event_joined", { via: "link" });
  return r;
}

export interface ReportOutcome {
  ok: boolean;
  status: "pending" | "reported" | "confirmed";
  version: number;
  conflict?: boolean;
}

/** Signed-in player reports (or confirms, by entering the same score) their own match. */
export async function reportMatch(
  match: Match,
  side0Wins: number,
  side1Wins: number,
  draws = 0,
  idempotencyKey: string = crypto.randomUUID(),
): Promise<ReportOutcome> {
  const { data, error } = await supabase.rpc("report_match", {
    p_match_id: match.id,
    p_side0_wins: side0Wins,
    p_side1_wins: side1Wins,
    p_draws: draws,
    p_expected_version: match.version ?? null,
    p_idempotency_key: idempotencyKey,
  });
  if (error) throw error;
  const outcome = data as ReportOutcome;
  capture("match_reported", { status: outcome?.status ?? "unknown", games: side0Wins + side1Wins + draws, draws });
  return outcome;
}

export async function respondToResult(matchId: string, accept: boolean) {
  const { error } = await supabase.rpc("respond_to_result", { p_match_id: matchId, p_accept: accept });
  if (error) throw error;
  capture("result_responded", { accepted: accept });
}

export async function respondToInvite(eventId: string, accept: boolean) {
  const { data, error } = await supabase.rpc("respond_to_invite", { p_event_id: eventId, p_accept: accept });
  if (error) throw error;
  capture("invite_responded", { accepted: accept });
  return data as { status: string; event_id?: string; participant_id?: string };
}

/** Deletes the signed-in account (profile scrubbed, results kept as "Deleted player"), then signs out locally. */
export async function deleteAccount() {
  const { error } = await supabase.functions.invoke("delete-account", { body: {} });
  if (error) throw error;
  capture("account_deleted");
  await supabase.auth.signOut({ scope: "local" });
}

/* ── Events tab, Account tab ──────────────────────────────────────────── */

/** Everything the Events tab shows, in one call. The web never shows demo data (TestFlight only). */
export async function fetchEventsHome(): Promise<HomeData> {
  const { data, error } = await supabase.rpc("events_home", { p_include_demo: false });
  if (error) throw error;
  return data as HomeData;
}

/** Live seats with table, opponent, ranks and clock. Empty when signed out or nothing is live. */
export async function fetchLiveSnapshots(): Promise<LiveSnapshot[]> {
  const { data, error } = await supabase.functions.invoke("live-activity", { body: { action: "state" } });
  if (error) return [];
  return (data?.snapshots ?? []) as LiveSnapshot[];
}

/** Report from the Events tab's live card, by match id (same RPC, version check and idempotency). */
export async function reportFromHome(
  matchId: string,
  mySide: number,
  my: number,
  their: number,
  version?: number,
  draws = 0,
) {
  const { data, error } = await supabase.rpc("report_match", {
    p_match_id: matchId,
    p_side0_wins: mySide === 0 ? my : their,
    p_side1_wins: mySide === 0 ? their : my,
    p_draws: draws,
    p_expected_version: version ?? null,
    p_idempotency_key: crypto.randomUUID(),
  });
  if (error) throw error;
  capture("match_reported", { status: (data as ReportOutcome | null)?.status ?? "unknown", games: my + their + draws, draws });
}

export async function fetchAccountOverview(): Promise<AccountOverview> {
  const { data, error } = await supabase.rpc("account_overview", { p_include_demo: false });
  if (error) throw error;
  return data as AccountOverview;
}

export async function fetchNearbyAlerts(userId: string): Promise<boolean> {
  const { data } = await supabase.from("notification_prefs").select("nearby_alerts").eq("user_id", userId).maybeSingle();
  return !!data?.nearby_alerts;
}

export async function setNearbyAlerts(userId: string, enabled: boolean) {
  const { error } = await supabase.from("notification_prefs").upsert({ user_id: userId, nearby_alerts: enabled });
  if (error) throw error;
  capture("nearby_alerts_changed", { enabled });
}

export async function setDisplayName(userId: string, name: string) {
  const trimmed = name.trim().slice(0, 40);
  if (!trimmed) return;
  const { error } = await supabase.from("profiles").update({ display_name: trimmed }).eq("id", userId);
  if (error) throw error;
}

/* ── organizer: cancel, add players ──────────────────────────────────── */

/** Cancels the event for everyone. Results already confirmed stay on players' records. */
export async function cancelEvent(eventId: string, reason: string) {
  const { error } = await supabase.rpc("cancel_event", { p_event_id: eventId, p_reason: reason });
  if (error) throw error;
  capture("event_cancelled");
}

/** People who've shared your events, most-shared first (optionally filtered by name). */
export async function fetchSuggestedPlayers(eventId: string, query: string): Promise<SuggestedPlayer[]> {
  const { data, error } = await supabase.rpc("suggested_players", {
    p_event_id: eventId,
    p_query: query,
    p_limit: 50,
    p_include_demo: false,
  });
  if (error) throw error;
  return (data ?? []) as SuggestedPlayer[];
}

/** `friends`: how many of them are friends (telemetry only). */
export async function invitePlayers(eventId: string, userIds: string[], friends = 0): Promise<number> {
  const { data, error } = await supabase.rpc("invite_players", { p_event_id: eventId, p_user_ids: userIds });
  if (error) throw error;
  const invited = (data?.invited as number) ?? 0;
  capture("players_invited", { count: invited, via: "account", friends });
  return invited;
}

/** Existing accounts only; the answer never says whether the address has one. */
export async function inviteByEmail(eventId: string, email: string) {
  const { error } = await supabase.rpc("invite_by_email", { p_event_id: eventId, p_email: email });
  if (error) throw error;
  capture("players_invited", { count: 1, via: "email" });
}

/**
 * Ends the event: records the open round (if any) and marks the event completed, in one audited server call.
 * Pairing the next round records the previous one on the server, so this is only for the last round.
 * Refused while a result is disputed (resolve it with setMatchResult first).
 */
export async function finishEvent(eventId: string, openRoundId: string | null) {
  const { error } = await supabase.rpc("record_round", {
    p_event_id: eventId,
    p_round_id: openRoundId,
    p_final: true,
  });
  if (error) throw error;
  capture("round_recorded", { final: true });
}

export type ClockAction = "pause" | "resume" | "add";

export interface RoundClockResult {
  round_id: string;
  timer_status: "running" | "paused";
  remaining_seconds: number;
  duration_seconds: number;
  ends_at: string | null;
}

/**
 * The only way the organizer changes a round clock. The server keeps timer_ends_at,
 * timer_last_started_at and timer_remaining_at_change consistent and drives Live Activity pushes.
 * `seconds` is used by "add" (may be negative; never below 0 left).
 */
export async function setRoundClock(roundId: string, action: ClockAction, seconds = 300): Promise<RoundClockResult> {
  const { data, error } = await supabase.rpc("set_round_clock", {
    p_round_id: roundId,
    p_action: action,
    p_seconds: seconds,
  });
  if (error) throw error;
  capture("round_clock_changed", { action });
  return data as RoundClockResult;
}

/** Everything update_event_details takes. Send the full current state on every save. */
export interface EventDetailsInput {
  /** Only for older events with typed names; auto-named events ignore it. */
  name: string | null;
  formatName: FormatName;
  rounds: number;
  showClock: boolean;
  setCode: string | null;
  setName: string | null;
  cubeName: string | null;
  cubeUrl: string | null;
  teamSize: number | null;
  formatOther: string | null;
  /** Roto only (null keeps). */
  pairing?: "swiss" | "round_robin" | null;
}

export interface EventDetailsResult {
  event_id: string;
  name: string;
  format_name: FormatName;
  format_label: string;
  number_of_rounds: number;
  round_length_seconds: number;
  set_code: string | null;
  set_name: string | null;
  cube_name: string | null;
  cube_url: string | null;
  team_size: number | null;
  format_other: string | null;
}

/**
 * Edits an event's details while it's in setup (no rounds yet). Errors: 55000 "Details lock once round 1
 * is paired", 22023 validation messages. A non-team format releases everyone from their teams.
 */
export async function updateEventDetails(eventId: string, input: EventDetailsInput): Promise<EventDetailsResult> {
  const { data, error } = await supabase.rpc("update_event_details", {
    p_event_id: eventId,
    p_name: input.name,
    p_format_name: input.formatName,
    p_rounds: input.rounds,
    p_round_seconds: 3000,
    p_show_clock: input.showClock,
    p_set_code: input.setCode,
    p_set_name: input.setName,
    p_cube_name: input.cubeName,
    p_cube_url: input.cubeUrl,
    p_team_size: input.teamSize,
    p_format_other: input.formatOther,
    p_pairing: input.pairing ?? null,
  });
  if (error) throw error;
  return data as EventDetailsResult;
}

/** Drop (with the round they dropped after) or reinstate. Organizer only, audited on the server. */
export async function setParticipantStatus(
  participantId: string,
  status: "active" | "dropped",
  roundNumber: number | null,
) {
  const { error } = await supabase.rpc("set_participant_status", {
    p_participant_id: participantId,
    p_status: status,
    p_dropped_in_round: status === "dropped" ? roundNumber : null,
  });
  if (error) throw error;
  capture("player_dropped", { status });
}

/* ── 2026-10-13: typed formats, seating, teams ───────────────────────── */

export interface CreateEventV2Input {
  formatName: FormatName;
  rounds: number;
  /** Rounds always run 50 minutes; this only decides whether clocks are shown. */
  showClock: boolean;
  setCode?: string | null;
  setName?: string | null;
  cubeName?: string | null;
  cubeUrl?: string | null;
  teamSize?: 3 | 4 | null;
  formatOther?: string | null;
  /** Players by name only (no account). */
  playerNames: string[];
  /** Seat the organizer first (default on). */
  includeMe: boolean;
  /** Roto only: swiss | round_robin. */
  pairing?: "swiss" | "round_robin" | null;
}

/** The server names the event ("Draft · Duskmourn · Fri 17 Oct") using the device's date. */
export async function createEventV2(input: CreateEventV2Input): Promise<{ eventId: string; shortCode: string }> {
  const { data, error } = await supabase.rpc("create_event_v2", {
    p_format_name: input.formatName,
    p_rounds: input.rounds,
    p_set_code: input.setCode ?? null,
    p_set_name: input.setName ?? null,
    p_cube_name: input.cubeName ?? null,
    p_cube_url: input.cubeUrl ?? null,
    p_team_size: input.teamSize ?? null,
    p_format_other: input.formatOther ?? null,
    p_player_names: input.playerNames,
    p_include_me: input.includeMe,
    p_show_clock: input.showClock,
    p_local_date: localDate(),
    p_pairing: input.pairing ?? null,
  });
  if (error) throw error;
  capture("event_created", {
    format: input.formatName,
    kind: input.cubeName ? "cube" : input.setCode ? "limited" : "constructed",
    rounds: input.rounds,
    round_timer: input.showClock,
    team_size: input.teamSize ?? 0,
    organizer_plays: input.includeMe,
    guests: input.playerNames.length,
    pairing: input.pairing ?? "swiss",
  });
  return { eventId: data.event_id, shortCode: data.short_code };
}

/** The device's calendar date (YYYY-MM-DD), so the event's name says the day it is here. */
export function localDate(d = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/* ── players before round 1 (organizer) ─────────────────────────────────── */

/** A player by name only, not tied to an account. Refuses a name already in the event. */
export async function addGuest(eventId: string, name: string) {
  const { error } = await supabase.rpc("add_guest", { p_event_id: eventId, p_name: name });
  if (error) throw error;
  capture("guest_added");
}

/** The organizer joins their own event as a player. */
export async function addSelfToEvent(eventId: string) {
  const { error } = await supabase.rpc("add_self_to_event", { p_event_id: eventId });
  if (error) throw error;
}

/** Before round 1 only (after that, Drop). Seats after theirs move up one. */
export async function removeParticipant(participantId: string) {
  const { error } = await supabase.rpc("remove_participant", { p_participant_id: participantId });
  if (error) throw error;
  capture("player_removed");
}

/** The signed-in player's name as events show it. */
export async function myDisplayName(): Promise<string | null> {
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return null;
  const { data } = await supabase.from("profiles").select("display_name, handle").eq("id", auth.user.id).maybeSingle();
  return (data?.display_name?.trim() || data?.handle?.trim()) ?? null;
}

/* ── cubes ──────────────────────────────────────────────────────────────── */

export interface RecentCube {
  cube_name: string;
  cube_url: string | null;
  last_used_at: string | null;
}

/** Cubes this account has run, newest first. */
export async function fetchRecentCubes(): Promise<RecentCube[]> {
  const { data, error } = await supabase.rpc("recent_cubes", { p_limit: 5 });
  if (error) return [];
  return (data ?? []) as RecentCube[];
}

export interface CubeLookup {
  cube_id: string;
  name: string;
  card_count: number | null;
  url: string;
}

/** Cube Cobra link → name (server-side, so no CORS). Throws with the server's message. */
export async function lookupCube(url: string): Promise<CubeLookup> {
  const { data, error } = await supabase.functions.invoke("cube-lookup", { body: { url } });
  if (error) {
    let message = "Couldn't reach Cube Cobra";
    const ctx = (error as { context?: unknown }).context;
    if (ctx && typeof (ctx as Response).json === "function") {
      try {
        const payload = await (ctx as Response).clone().json();
        if (payload?.error) message = String(payload.error);
      } catch {
        /* not JSON */
      }
    }
    throw new Error(message);
  }
  return data as CubeLookup;
}

/** Scryfall sets for limited events, newest first. */
export async function fetchDraftableSets(query: string, limit = 40): Promise<DraftableSet[]> {
  const { data, error } = await supabase.rpc("draftable_sets", {
    p_query: query.trim() || null,
    p_limit: limit,
  });
  if (error) throw error;
  return (data ?? []) as DraftableSet[];
}

/**
 * Calls events-engine with the user's token. A non-2xx answer carries `{error}`; surface that text
 * instead of supabase-js's generic "Edge Function returned a non-2xx status code".
 */
async function invokeEngine<T>(body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke("events-engine", { body });
  if (error) {
    let message = error.message;
    const ctx = (error as { context?: unknown }).context;
    if (ctx && typeof (ctx as Response).json === "function") {
      try {
        const payload = await (ctx as Response).clone().json();
        if (payload?.error) message = String(payload.error);
      } catch {
        /* not JSON; keep the generic message */
      }
    }
    throw new Error(message);
  }
  if (data && typeof data === "object" && "error" in data && (data as { error?: unknown }).error) {
    throw new Error(String((data as { error: unknown }).error));
  }
  return data as T;
}

/** Pairs (and opens) the next round on the server: Swiss, draft across-the-table, or team pairings. */
export async function pairNextRound(eventId: string, pairing: "swiss" | "round_robin" = "swiss") {
  const r = await invokeEngine<{ round_id: string; round_number: number; timer_ends_at: string }>({
    action: "pair_round",
    event_id: eventId,
  });
  capture("round_paired", { round: r?.round_number ?? 0, pairing });
  return r;
}

/** Random draft seats in pods of up to 8. Calling again re-shuffles. */
/** Seats (or re-seats) a draft in one call; returns the new seating. */
export async function seatPlayers(eventId: string): Promise<SeatingPod[]> {
  const { data, error } = await supabase.rpc("seat_event", { p_event_id: eventId });
  if (error) throw error;
  const pods = (data?.pods ?? []) as SeatingPod[];
  capture("seating_drawn", { pods: pods.length });
  return pods;
}

export interface EngineStandings {
  seating: SeatingPod[] | null;
}

/** Public. Used here for the seating view (pods with names, team per seat). */
export async function fetchEngineStandings(eventId: string): Promise<EngineStandings> {
  const data = await invokeEngine<{ seating?: SeatingPod[] | null }>({ action: "standings", event_id: eventId });
  return { seating: data.seating ?? null };
}

export async function fetchEventTeams(eventId: string): Promise<EventTeam[]> {
  const { data, error } = await supabase.rpc("get_event_teams", { p_event_id: eventId });
  if (error) throw error;
  return (data ?? []) as EventTeam[];
}

export async function randomizeTeams(eventId: string): Promise<EventTeam[]> {
  const { data, error } = await supabase.rpc("randomize_teams", { p_event_id: eventId });
  if (error) throw error;
  const teams = (data ?? []) as EventTeam[];
  capture("teams_set", { teams: teams.length, random: true });
  return teams;
}

/** Saves the whole layout. Member order is slot order (1 = seat A). */
export async function saveTeams(eventId: string, teams: { name: string; members: string[] }[]): Promise<EventTeam[]> {
  const { data, error } = await supabase.rpc("set_teams", { p_event_id: eventId, p_teams: teams });
  if (error) throw error;
  capture("teams_set", { teams: teams.length, random: false });
  return (data ?? []) as EventTeam[];
}

/* ── life tracker ─────────────────────────────────────────────────────── */

export interface TrackerState {
  session_id: string;
  match_id: string;
  event_id: string;
  starting_life: number;
  my_side: Side | null;
  names: string[];
  event_name: string;
  round: number;
  table: number | null;
  /** The match's round timer; null when there's no round. Kept live from rounds UPDATEs. */
  clock: TrackerClock | null;
  games: TrackerGame[];
  ops: TrackerOp[];
}

export async function trackerOpen(matchId: string, startingLife = 20): Promise<TrackerState> {
  const { data, error } = await supabase.rpc("tracker_open", { p_match_id: matchId, p_starting_life: startingLife });
  if (error) throw error;
  return data as TrackerState;
}

export async function trackerState(sessionId: string): Promise<TrackerState> {
  const { data, error } = await supabase.rpc("tracker_state", { p_session_id: sessionId });
  if (error) throw error;
  return data as TrackerState;
}

export async function trackerPush(sessionId: string, ops: TrackerOp[]): Promise<{ inserted: number; game_no: number }> {
  const { data, error } = await supabase.rpc("tracker_push", {
    p_session_id: sessionId,
    p_ops: ops.map(({ client_op_id, game_no, side, counter, delta, tapped_at }) => ({
      client_op_id, game_no, side, counter, delta, tapped_at,
    })),
  });
  if (error) throw error;
  return data as { inserted: number; game_no: number };
}

export async function trackerRecordGame(
  sessionId: string,
  gameNo: number,
  winnerSide: Side | null,
  draw: boolean,
): Promise<TrackerState> {
  const { data, error } = await supabase.rpc("tracker_record_game", {
    p_session_id: sessionId,
    p_game_no: gameNo,
    p_winner_side: draw ? null : winnerSide,
    p_draw: draw,
  });
  if (error) throw error;
  capture("tracker_game_recorded", { draw, game_no: gameNo });
  return data as TrackerState;
}

/* ── settings ─────────────────────────────────────────────────────────── */

export async function fetchTrackerMode(userId: string): Promise<TrackerMode> {
  const { data, error } = await supabase.from("user_settings").select("tracker_mode").eq("user_id", userId).maybeSingle();
  if (error) throw error;
  return data?.tracker_mode === "tracker" ? "tracker" : "elsewhere";
}

export async function saveTrackerMode(userId: string, mode: TrackerMode) {
  const { error } = await supabase
    .from("user_settings")
    .upsert({ user_id: userId, tracker_mode: mode, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
  if (error) throw error;
  capture("tracker_mode_changed", { mode });
}
