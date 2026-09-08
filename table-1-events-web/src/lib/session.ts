/** A guest's identity for one event, kept only on their own device. */
const KEY = "table1.participant";

export interface LocalParticipant {
  eventId: string;
  shortCode: string;
  participantId: string;
  token: string;
  displayName: string;
}

export function saveLocalParticipant(p: LocalParticipant) {
  try {
    const all = readAll();
    all[p.eventId] = p;
    localStorage.setItem(KEY, JSON.stringify(all));
  } catch {
    /* private browsing, storage disabled — the app still works, just not sticky */
  }
}

export function getLocalParticipant(eventId: string): LocalParticipant | null {
  try {
    return readAll()[eventId] ?? null;
  } catch {
    return null;
  }
}

function readAll(): Record<string, LocalParticipant> {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as Record<string, LocalParticipant>) : {};
  } catch {
    return {};
  }
}
