// Alert text for events you follow but aren't in (contract/event-follows-2026-11-09.md): `event.follow_round` when a
// round is paired (re-paired rounds too) and `event.follow_done` when it finishes. The event's name is the title,
// since a follower has no table or opponent to name. The app opens the event's page (standings and matchups).
const STAGES: Record<string, string> = { quarterfinal: "Quarterfinals", semifinal: "Semifinals", final: "The final" };

export function eventFollowCopy(kind: string, d: Record<string, unknown>): { title: string; body: string } {
  const name = typeof d.event_name === "string" && d.event_name.trim() ? d.event_name.trim() : "An event you follow";
  if (kind === "event.follow_done") return { title: name, body: "Final standings are up." };
  const stage = STAGES[String(d.stage)];
  const n = Number(d.round ?? 0), of = Number(d.of ?? 0);
  const round = stage ?? (n > 0 ? (of >= n ? `Round ${n} of ${of}` : `Round ${n}`) : "The next round");
  return { title: name, body: `${round} is up. Tap for the pairings and standings.` };
}
