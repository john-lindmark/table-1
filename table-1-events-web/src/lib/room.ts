// Organizer tools for the room (contract/room-tools-2026-11-13.md): what displays show and say, extra time for a
// table, judge calls. `event_room` is read with the event (on its `event:<id>` ping, on foreground, with the 15–20 s
// refresh) by whoever can open it; a server before it, or a failed read, answers null and every part it feeds hides.
import { useCallback, useEffect, useState } from "react";
import { phasesDemo, rpc } from "./leagues";
import { capture } from "./telemetry";
import type { DisplayShow } from "./display";

export interface RoomDisplay { show: DisplayShow; message: string | null }
export interface RoomExtension { match_id: string; table_number: number | null; extra_seconds: number }
export interface JudgeCall { call_id: string; match_id: string; table_number: number | null; called_at: string; by: string | null }
export interface MyRoomMatch { match_id: string; table_number: number | null; extra_seconds: number; call_open: boolean }
export interface EventRoom {
  display: RoomDisplay;
  extensions: RoomExtension[];
  /** Organizers: open judge calls, oldest first; null for everyone else. */
  calls: JudgeCall[] | null;
  /** A player in the newest round. */
  my_match: MyRoomMatch | null;
}

export const MESSAGE_MAX = 140;
/** "24 / 140". */
export const messageCount = (text: string) => `${text.length} / ${MESSAGE_MAX}`;
export const SHOW_LABELS: { value: DisplayShow; label: string }[] = [
  { value: "auto", label: "Auto" }, { value: "clock", label: "Clock" }, { value: "pairings", label: "Pairings" }, { value: "standings", label: "Standings" },
];
/** Extra time a table can be given in one tap; "Take it back" clears what it has. */
export const EXTRA_PICKS = [180, 300, 600];
export const EXTRA_MAX = 3600;

function clean(r: Partial<EventRoom> | null | undefined): EventRoom {
  const show = r?.display?.show;
  return {
    display: { show: show === "clock" || show === "pairings" || show === "standings" ? show : "auto", message: r?.display?.message?.trim() || null },
    extensions: (r?.extensions ?? []).filter((x) => (x.extra_seconds ?? 0) > 0),
    calls: r?.calls ?? null,
    my_match: r?.my_match ?? null,
  };
}

/** The room's state; null when the server has none yet or the read fails. */
export async function eventRoom(eventId: string, token?: string | null): Promise<EventRoom | null> {
  try {
    const d = await phasesDemo();
    return clean(d ? d.eventRoom(eventId) : await rpc<EventRoom>("event_room", token ? { p_event_id: eventId, p_token: token } : { p_event_id: eventId }));
  } catch {
    return null;
  }
}

/** A table's extra seconds by match, from the room (the newest round's tables). */
export const extraByMatch = (room: EventRoom | null | undefined) => new Map((room?.extensions ?? []).map((x) => [x.match_id, x.extra_seconds]));
/** Extra seconds by table number, for lists that only know the table (the display's pairings). */
export const extraByTable = (room: EventRoom | null | undefined) =>
  new Map((room?.extensions ?? []).filter((x) => x.table_number != null).map((x) => [x.table_number as number, x.extra_seconds]));

export async function eventDisplaySet(eventId: string, patch: { show?: DisplayShow; message?: string | null }): Promise<RoomDisplay> {
  const d = await phasesDemo();
  const r = d ? d.eventDisplaySet(eventId, patch) : await rpc<RoomDisplay>("event_display_set", { p_event_id: eventId, p_patch: patch });
  capture("display_set", { show: r.show, message: !!r.message });
  return r;
}

/** Adds `seconds` to a table's extra time (negative takes time back; the table's total stays 0–3600). */
export async function matchTimeExtend(matchId: string, seconds: number, eventId?: string): Promise<RoomExtension> {
  const d = await phasesDemo();
  const r = d ? d.matchTimeExtend(eventId ?? "", matchId, seconds)
    : await rpc<RoomExtension>("match_time_extend", { p_match_id: matchId, p_seconds: seconds });
  capture("time_extended", { seconds });
  return r;
}

export async function judgeCall(matchId: string, token?: string | null, eventId?: string): Promise<void> {
  const d = await phasesDemo();
  if (d) d.judgeCall(eventId ?? "", matchId);
  else await rpc<unknown>("judge_call", token ? { p_match_id: matchId, p_token: token } : { p_match_id: matchId });
  capture("judge_called", {});
}

export async function judgeCallCancel(matchId: string, token?: string | null, eventId?: string): Promise<void> {
  const d = await phasesDemo();
  if (d) d.judgeCallCancel(eventId ?? "", matchId);
  else await rpc<unknown>("judge_call_cancel", token ? { p_match_id: matchId, p_token: token } : { p_match_id: matchId });
  capture("judge_cancelled", {});
}

export async function judgeCallResolve(callId: string, eventId?: string): Promise<void> {
  const d = await phasesDemo();
  if (d) d.judgeCallResolve(eventId ?? "", callId);
  else await rpc<unknown>("judge_call_resolve", { p_call_id: callId });
  capture("judge_resolved", {});
}

/**
 * The room for a screen that already shows the event: read once, then whenever `version` changes (the screen's own
 * reload, which follows the `event:<id>` ping, the 20 s refresh and the tab coming back), and after `reload()`.
 * `poll` adds a 15 s refresh of its own, for a screen with no event on it (the tracker). It doesn't listen for the
 * event's ping: realtime hands back one channel per topic, so the tracker closing would unsubscribe the event screen
 * under it (the same reason the tracker asks for the next round by polling).
 */
export function useEventRoom(eventId: string | null | undefined, token?: string | null, version: unknown = 0, poll = false) {
  const [room, setRoom] = useState<EventRoom | null>(null);
  const reload = useCallback(async () => {
    if (!eventId) return;
    const r = await eventRoom(eventId, token);
    setRoom(r);
  }, [eventId, token]);
  useEffect(() => {
    void reload();
  }, [reload, version]);
  useEffect(() => {
    if (!poll || !eventId) return;
    const id = window.setInterval(() => { if (document.visibilityState === "visible") void reload(); }, 15000);
    const back = () => { if (document.visibilityState === "visible") void reload(); };
    document.addEventListener("visibilitychange", back);
    return () => {
      window.clearInterval(id);
      document.removeEventListener("visibilitychange", back);
    };
  }, [poll, eventId, reload]);
  return { room, reload, setRoom };
}
