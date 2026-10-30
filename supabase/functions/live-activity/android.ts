// Android's Live Activities: the same states, sent as data-only FCM messages that the app draws as an ongoing
// notification (apps/android util/LiveUpdates.kt). One message per device, per audience:
//   kind "live.player"    live = {eventId, eventName, participantId, state}   (silent: notify-worker already alerts
//                                                                               players about rounds and results)
//   kind "live.organizer" live = {eventId, eventName, state}                  (alerts: a dispute, all results in)
// event: start | update | end, as the APNs payloads. FCM data values are strings, so `live` is JSON text.
import type { AndroidAlert } from "../notify-worker/fcm.ts";
import type { OrgState } from "./organizer.ts";
import type { PlayerState } from "./state.ts";

export type LiveEvent = "start" | "update" | "end";

export function playerMessage(token: string, ps: PlayerState, event: LiveEvent, priority: 5 | 10): AndroidAlert {
  return {
    token, priority, title: "", body: "",
    tag: `live:p:${ps.attributes.eventId}`, group: "live",
    info: { kind: "live.player", event_id: ps.attributes.eventId, event, live: JSON.stringify({ ...ps.attributes, state: ps.state }) },
  };
}

export function organizerMessage(token: string, o: OrgState, event: LiveEvent, priority: 5 | 10,
  alert?: { title: string; body: string }): AndroidAlert {
  return {
    token, priority, title: alert?.title ?? "", body: alert?.body ?? "",
    tag: `live:o:${o.attributes.eventId}`, group: "live",
    info: { kind: "live.organizer", event_id: o.attributes.eventId, event, live: JSON.stringify({ ...o.attributes, state: o.state }) },
  };
}

/** Which message a dispatch kind sends, and how urgently (the APNs mapping in index.ts). Null: nothing. */
export function playerPlan(kind: string): { event: LiveEvent; priority: 5 | 10 } | null {
  switch (kind) {
    case "round_started": return { event: "update", priority: 10 };
    case "match": case "clock": return { event: "update", priority: 10 };
    case "round_recorded": return { event: "update", priority: 5 };
    case "event_ended": case "dropped": return { event: "end", priority: 10 };
    default: return null;
  }
}

export function organizerPlan(kind: string): { event: LiveEvent; priority: 5 | 10 } | null {
  switch (kind) {
    case "round_started": case "match": case "round_recorded": case "clock": return { event: "update", priority: 10 };
    case "dropped": return { event: "update", priority: 5 };
    case "event_ended": return { event: "end", priority: 10 };
    default: return null;
  }
}
