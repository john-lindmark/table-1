import { useCallback, useEffect, useRef, useState } from "react";
import { fetchEngineStandings, fetchEventTeams, errorMessage } from "./api";
import type { EventTeam, Participant, SeatingPod } from "./types";
import type { Team } from "./teams";

/** A key that changes whenever seats, pods or teams of the participants change. */
export function participantsKey(participants: Participant[] | undefined): string {
  return (participants ?? [])
    .map((p) => `${p.id}:${p.podId ?? ""}:${p.seat ?? ""}:${p.teamId ?? ""}:${p.teamSlot ?? ""}:${p.status}`)
    .join("|");
}

export const toTeams = (rows: EventTeam[]): Team[] => rows.map((t) => ({ id: t.id, name: t.name, order: t.order }));

/** get_event_teams for a team event, refetched when the participants change. */
export function useEventTeams(eventId: string | null, enabled: boolean, refreshKey: string) {
  const [teams, setTeams] = useState<EventTeam[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    if (!eventId || !enabled) return;
    try {
      setTeams(await fetchEventTeams(eventId));
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
      setTeams((t) => t ?? []);
    }
  }, [eventId, enabled]);

  useEffect(() => {
    reload();
  }, [reload, refreshKey]);

  return { teams, setTeams, reload, error };
}

const seatsKey = (rows: [string, string, number][]) =>
  rows.sort((a, b) => a[0].localeCompare(b[0])).map((r) => r.join(":")).join("|");

function seatsKeyOfPods(pods: SeatingPod[]): string {
  return seatsKey(pods.flatMap((pod) => pod.seats.map((s): [string, string, number] => [s.participant_id, pod.pod_id, s.seat])));
}

function seatsKeyOfParticipants(participants: Participant[]): string {
  return seatsKey(
    participants
      .filter((p) => p.status === "active" && p.seat != null)
      .map((p): [string, string, number] => [p.id, p.podId ?? "", p.seat!]),
  );
}

/** Seating as the server reports it (pod names, team per seat); derived locally if that call fails. */
export function useSeating(
  eventId: string | null,
  enabled: boolean,
  participants: Participant[] | undefined,
  teams: EventTeam[] | null,
) {
  const key = participantsKey(participants);
  const [seating, setSeatingState] = useState<SeatingPod[] | null>(null);
  // Seats the server just returned (from seat_event). When the refetched participants show exactly
  // those seats, there's nothing new to ask the engine for.
  const fresh = useRef<string | null>(null);

  const setSeating = useCallback((pods: SeatingPod[] | null) => {
    fresh.current = pods ? seatsKeyOfPods(pods) : null;
    setSeatingState(pods);
  }, []);

  useEffect(() => {
    if (!eventId || !enabled) return;
    const justSeated = fresh.current !== null && fresh.current === seatsKeyOfParticipants(participants ?? []);
    fresh.current = null;
    if (justSeated) return;
    const setSeating = setSeatingState;
    let live = true;
    fetchEngineStandings(eventId)
      .then((r) => live && setSeating(r.seating ?? deriveSeating(participants ?? [], teams)))
      .catch(() => live && setSeating(deriveSeating(participants ?? [], teams)));
    return () => {
      live = false;
    };
    // participants are captured through `key` (it changes whenever seats, pods or teams do).
  }, [eventId, enabled, key, teams]);

  return { seating, setSeating };
}

export function deriveSeating(participants: Participant[], teams: EventTeam[] | null): SeatingPod[] {
  const teamName = new Map((teams ?? []).map((t) => [t.id, t.name]));
  const seated = participants
    .filter((p) => p.status === "active" && p.seat != null)
    .sort((a, b) => (a.seat ?? 0) - (b.seat ?? 0));
  const pods: SeatingPod[] = [];
  for (const p of seated) {
    const podId = p.podId ?? "pod";
    let pod = pods.find((x) => x.pod_id === podId);
    if (!pod) {
      pod = { pod_id: podId, name: `Pod ${pods.length + 1}`, seats: [] };
      pods.push(pod);
    }
    pod.seats.push({
      seat: p.seat!,
      participant_id: p.id,
      display_name: p.displayName,
      team: p.teamId ? teamName.get(p.teamId) ?? null : null,
    });
  }
  return pods;
}
