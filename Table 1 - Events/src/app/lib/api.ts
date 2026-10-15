import { API_BASE, getSupabase, publicAnonKey } from "./supabaseClient";
import type { Format, Pairing, Player, Role, Team, TimerState } from "./types";

export interface TeamScore {
  recorded: number;
  pending: number;
  total: number;
}

export interface EventBundle {
  event: {
    id: string;
    name: string;
    status: string;
    matchupMethod: "round_robin" | "swiss";
    numberOfRounds: number;
    currentRoundNumber: number;
    drawsAllowed: boolean;
    defaultTimerSeconds: number;
    updatedAt: string;
  };
  teams: Team[];
  formats: Format[];
  players: Player[];
  currentPairings: Pairing[];
  recordedRounds: { roundNumber: number; pairings: Pairing[]; recordedAt: string }[];
  timer: TimerState & { roundNumber: number };
  members: { userId: string; email: string; role: Role }[];
  activity: { id: string; type: string; at: string; userId: string; meta: unknown }[];
  audit: {
    id: string;
    roundNumber: number;
    pairingId: string;
    changedBy: string;
    previousResult: string;
    newResult: string;
    reason: string;
    at: string;
  }[];
  scores: Record<string, TeamScore>;
  role: Role;
}

async function authHeader(): Promise<string> {
  const {
    data: { session },
  } = await getSupabase().auth.getSession();
  return `Bearer ${session?.access_token ?? publicAnonKey}`;
}

async function request<T>(path: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      Authorization: await authHeader(),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json: any = {};
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { error: text };
  }
  if (!res.ok) {
    const message = json.error ?? `Request failed (${res.status})`;
    console.error(`API ${method} ${path} failed:`, message);
    throw new Error(message);
  }
  return json as T;
}

// Public request — uses anon key only, no user session required.
async function requestPublic<T>(path: string): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    method: "GET",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${publicAnonKey}`,
    },
  });
  const text = await res.text();
  let json: any = {};
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { error: text };
  }
  if (!res.ok) {
    const message = json.error ?? `Request failed (${res.status})`;
    throw new Error(message);
  }
  return json as T;
}

export const api = {
  signup: (email: string, password: string, name: string) =>
    request<{ ok: boolean }>("/signup", "POST", { email, password, name }),
  listEvents: () => request<{ events: any[] }>("/events", "GET"),
  createEvent: (cfg: unknown) => request<{ eventId: string }>("/events", "POST", cfg),
  getEvent: (id: string) => request<EventBundle>(`/events/${id}`, "GET"),
  seed: () => request<{ eventId: string }>("/events/seed", "POST", {}),
  setResult: (
    id: string,
    pairingId: string,
    teamAGameWins: number,
    teamBGameWins: number,
    tieResolutionTeamId?: string | null,
    clockSecondsRemaining?: number,
  ) =>
    request<EventBundle>(`/events/${id}/result`, "POST", {
      pairingId,
      teamAGameWins,
      teamBGameWins,
      tieResolutionTeamId,
      clockSecondsRemaining,
    }),
  record: (id: string, roundNumber: number) =>
    request<EventBundle>(`/events/${id}/record`, "POST", { roundNumber }),
  correct: (
    id: string,
    roundNumber: number,
    pairingId: string,
    teamAGameWins: number,
    teamBGameWins: number,
    reason: string,
    tieResolutionTeamId?: string | null,
  ) =>
    request<EventBundle>(`/events/${id}/correct`, "POST", {
      roundNumber,
      pairingId,
      teamAGameWins,
      teamBGameWins,
      tieResolutionTeamId,
      reason,
    }),
  timer: (id: string, action: string, seconds?: number) =>
    request<EventBundle>(`/events/${id}/timer`, "POST", { action, seconds }),
  update: (id: string, payload: { name?: string; teams?: unknown[] }) =>
    request<EventBundle>(`/events/${id}/update`, "POST", payload),
  archive: (id: string) => request<{ ok: boolean }>(`/events/${id}/archive`, "POST", {}),
  members: (id: string, op: string, email: string, role?: string) =>
    request<EventBundle>(`/events/${id}/members`, "POST", { op, email, role }),
  getInsights: (id: string, force = false) =>
    request<{ insights: AIInsight[]; generatedAt: string }>(
      `/events/${id}/insights${force ? "?force=true" : ""}`,
      "GET",
    ),
  // Public endpoints — no auth required.
  getSharedEvent: (id: string) => requestPublic<EventBundle>(`/events/${id}/share`),
  getSharedInsights: (id: string, force = false) =>
    requestPublic<{ insights: AIInsight[]; generatedAt: string }>(
      `/events/${id}/insights${force ? "?force=true" : ""}`,
    ),
};

export interface AIInsight {
  headline: string;
  body: string;
  type: "player" | "format" | "timing" | "trend" | "standout";
}
