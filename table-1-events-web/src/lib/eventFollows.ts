// Following events you're not in, and the public event page's matchups (contract/event-follows-2026-11-09.md,
// contract/event-links-2026-11-09.md). Rules shared with iOS and Android through testdata/event-links/cases.json.
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import { roundName, when } from "./scheduledEvents";

export interface EventFollow { following: boolean; notify: boolean; can_follow?: boolean }

/** An event you follow, for the Events home's Following section. */
export interface FollowedEvent {
  event_id: string;
  name: string;
  format_label: string | null;
  status: string | null;
  current_round: number;
  number_of_rounds: number;
  top_cut?: number;
  starts_at: string | null;
  venue_name: string | null;
  notify?: boolean;
  stage: string | null;
}

/** "Round 2 of 4 · Modern", "Final standings · Modern", "Sat 8 Nov · 18:30 · The Shop · Modern". */
export function followedDetail(e: Pick<FollowedEvent, "status" | "current_round" | "number_of_rounds" | "stage" | "format_label" | "starts_at" | "venue_name">): string {
  const state = e.status === "completed" ? "Final standings"
    : e.current_round > 0 ? roundName(e.stage, e.current_round, e.number_of_rounds)
    : [when(e.starts_at), e.venue_name].filter(Boolean).join(" · ") || null;
  return [state, e.format_label].filter(Boolean).join(" · ");
}

/** A Matchups section header: "Round 2 · now", "Semifinals". */
export const roundTitle = (number: number, stage: string | null | undefined, status: string | null | undefined) =>
  ((stage ?? "swiss") === "swiss" ? `Round ${number}` : roundName(stage, number, 0)) + (status === "active" ? " · now" : "");

/** A match row's score: "2–1", "0–2–1", or "vs" before a result. */
export function matchScore(status: string, sides: { side: number; gameWins: number }[], gameDraws: number): string {
  if (status === "pending") return "vs";
  const a = sides.find((s) => s.side === 0)?.gameWins ?? 0, b = sides.find((s) => s.side === 1)?.gameWins ?? 0;
  return `${a}–${b}${gameDraws > 0 ? `–${gameDraws}` : ""}`;
}

export async function fetchEventFollow(eventId: string): Promise<EventFollow> {
  const { data, error } = await supabase.rpc("event_follow_get", { p_event_id: eventId });
  if (error) throw error;
  return data as EventFollow;
}

/** Follow or unfollow; `notify` turns its notifications on or off (null keeps). */
export async function setEventFollow(eventId: string, follow: boolean, notify: boolean | null = null): Promise<EventFollow> {
  const { data, error } = await supabase.rpc("event_follow_set", { p_event_id: eventId, p_follow: follow, p_notify: notify });
  if (error) throw error;
  const r = data as EventFollow;
  if (notify != null && follow) capture("event_follow_notify", { notify: r.notify });
  else capture(follow ? "event_followed" : "event_unfollowed");
  return r;
}

/** The Events home's Following section; a server without it (or a failed read) gives none. */
export async function fetchEventsFollowed(): Promise<FollowedEvent[]> {
  const { data, error } = await supabase.rpc("events_followed");
  if (error) return [];
  return (data ?? []) as FollowedEvent[];
}
