// Nearby events and the venue pin (contract/features-2026-10-13.md, contract/privacy-lockdown-2026-10-18.md): open
// events within 150 m, nearest first; the organizer pins the event where they stand. Coordinates are sent once per
// lookup and never stored (presence keeps only a ~1 km area cell). Same calls as iOS / Android Repo. The browser asks
// for location only when one of these is used.
import { supabase } from "./supabaseClient";

export interface Fix { lat: number; lng: number; accuracyM: number }
export interface NearbyEvent {
  event_id: string; name: string; venue_name: string | null; format: string; status: string; players: number;
  capacity: number | null; distance_m: number;
  /** Already an active player here, or its organizer: open the event instead of joining. */
  joined: boolean;
}
export type EventVisibility = "nearby" | "link_only" | "private";
export const VISIBILITY_LABEL: Record<EventVisibility, string> = { nearby: "Nearby", link_only: "Link only", private: "Private" };

/** One location reading, or null when the browser can't or won't give one. */
export function currentFix(timeoutMs = 10000): Promise<Fix | null> {
  if (typeof navigator === "undefined" || !navigator.geolocation) return Promise.resolve(null);
  return new Promise((resolve) => {
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, accuracyM: Math.max(5, Math.round(p.coords.accuracy)) }),
      () => resolve(null),
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 30000 },
    );
  });
}

/** "45 m · draft · 6/8 players · Denver Card Shop". */
export const nearbyDetail = (e: NearbyEvent) =>
  `${e.distance_m} m · ${e.format} · ${e.players}${e.capacity ? `/${e.capacity}` : ""} players${e.venue_name ? ` · ${e.venue_name}` : ""}`;

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export const nearbyEvents = (f: Fix) => rpc<NearbyEvent[]>("nearby_events", { p_lat: f.lat, p_lng: f.lng, p_accuracy_m: f.accuracyM });
export const joinNearby = (eventId: string, f: Fix) =>
  rpc<{ event_id: string }>("join_event_nearby", { p_event_id: eventId, p_lat: f.lat, p_lng: f.lng, p_accuracy_m: f.accuracyM });
/** Keeps this account's ~1 km area cell fresh for nearby alerts. */
export const updatePresence = (f: Fix) => rpc<void>("update_presence", { p_lat: f.lat, p_lng: f.lng });
/** Pins the event where the organizer stands and sets who can find it; for nearby events this alerts opted-in players. */
export const setEventLocation = (eventId: string, f: Fix, venue: string | null, visibility: EventVisibility) =>
  rpc<void>("set_event_location", {
    p_event_id: eventId, p_lat: f.lat, p_lng: f.lng, p_venue_name: venue ?? "", p_join_radius_m: 150, p_visibility: visibility,
  });
