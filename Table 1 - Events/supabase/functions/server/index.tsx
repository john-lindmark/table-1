import { Hono } from "npm:hono";
import { cors } from "npm:hono/cors";
import { logger } from "npm:hono/logger";
import { createClient } from "jsr:@supabase/supabase-js@2.49.8";
import * as kv from "./kv_store.tsx";

const app = new Hono();
app.use("*", logger(console.log));
app.use(
  "/*",
  cors({
    origin: "*",
    allowHeaders: ["Content-Type", "Authorization"],
    allowMethods: ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    exposeHeaders: ["Content-Length"],
    maxAge: 600,
  }),
);

const PREFIX = "/make-server-a539856f";

const admin = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

// ---------- helpers ----------

type Role = "owner" | "organizer" | "viewer";

interface AuthedUser {
  id: string;
  email: string;
}

async function getUser(req: Request): Promise<AuthedUser | null> {
  const token = req.headers.get("Authorization")?.split(" ")[1];
  if (!token) return null;
  const { data, error } = await admin().auth.getUser(token);
  if (error || !data.user) return null;
  return { id: data.user.id, email: data.user.email ?? "" };
}

const eventKey = (id: string) => `event:${id}`;
const userEventsKey = (uid: string) => `user_events:${uid}`;
const profileKey = (uid: string) => `profile:${uid}`;

function nowIso() {
  return new Date().toISOString();
}

function uuid() {
  return crypto.randomUUID();
}

interface Pairing {
  id: string;
  formatId: string;
  teamAPlayerId: string;
  teamBPlayerId: string;
  // Per-player game wins (0, 1, or 2). Results are derived, never stored.
  teamAGameWins: number;
  teamBGameWins: number;
  // Organizer tie resolution when decisive format records are equal (team id).
  tieResolutionTeamId?: string | null;
  // Timer remaining seconds at the moment this pairing first became decisive.
  // Used to compute elapsed match duration for AI insights. Null until decisive.
  completedAtSeconds: number | null;
}

type MatchupStatus =
  | "not_started"
  | "decisive"
  | "draw"
  | "invalid";

interface PairingResolution {
  status: MatchupStatus;
  winner: "a" | "b" | null;
  method: "game_score" | null;
}

interface Round {
  roundNumber: number;
  status: "pending" | "active" | "paused" | "recorded";
  pairings: Pairing[];
  recordedAt: string | null;
  recordedBy: string | null;
}

interface EventDoc {
  id: string;
  ownerId: string;
  name: string;
  status: string;
  matchupMethod: "round_robin" | "swiss";
  numberOfRounds: number;
  currentRoundNumber: number;
  defaultTimerSeconds: number;
  drawsAllowed: boolean;
  teams: { id: string; name: string; color: string; displayOrder: number }[];
  formats: { id: string; name: string; displayOrder: number }[];
  players: {
    id: string;
    teamId: string;
    formatId: string;
    name: string;
    displayOrder: number;
  }[];
  rounds: Round[];
  timer: {
    durationSeconds: number;
    remainingSecondsAtChange: number;
    status: "paused" | "running" | "completed";
    lastStartedAt: number | null;
    roundNumber: number;
  };
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
  createdAt: string;
  updatedAt: string;
}

async function loadEvent(id: string): Promise<EventDoc | null> {
  return (await kv.get(eventKey(id))) ?? null;
}

async function saveEvent(doc: EventDoc): Promise<void> {
  doc.updatedAt = nowIso();
  await kv.set(eventKey(doc.id), doc);
}

function roleOf(doc: EventDoc, userId: string): Role | null {
  return doc.members.find((m) => m.userId === userId)?.role ?? null;
}

function canEdit(role: Role | null) {
  return role === "owner" || role === "organizer";
}

function pushActivity(doc: EventDoc, type: string, userId: string, meta: unknown = {}) {
  doc.activity.unshift({ id: uuid(), type, at: nowIso(), userId, meta });
  doc.activity = doc.activity.slice(0, 100);
}

// True when a pairing has a clear winner by game score (2-X or X-2, X≠2).
function isPairingDecisive(a: number, b: number): boolean {
  return (a === 2 || b === 2) && a !== b;
}

// Reconstruct current timer remaining from persisted state.
function timerRemainingSeconds(timer: EventDoc["timer"]): number {
  if (timer.status === "running" && timer.lastStartedAt) {
    const elapsed = Math.floor((Date.now() - timer.lastStartedAt) / 1000);
    return timer.remainingSecondsAtChange - elapsed;
  }
  return timer.remainingSecondsAtChange;
}

// Round-robin: rotate team B for each round so pairings don't repeat until
// every A has faced every B in that format.
function generatePairings(doc: EventDoc, roundNumber: number): Pairing[] {
  const pairings: Pairing[] = [];
  for (const fmt of doc.formats) {
    const as = doc.players
      .filter((p) => p.teamId === doc.teams[0].id && p.formatId === fmt.id)
      .sort((a, b) => a.displayOrder - b.displayOrder);
    const bs = doc.players
      .filter((p) => p.teamId === doc.teams[1].id && p.formatId === fmt.id)
      .sort((a, b) => a.displayOrder - b.displayOrder);
    const n = Math.min(as.length, bs.length);
    let order = as.map((_, i) => i);
    if (doc.matchupMethod === "swiss") {
      // Randomize B assignment for Swiss and persist the result.
      order = order
        .map((v) => ({ v, k: Math.random() }))
        .sort((x, y) => x.k - y.k)
        .map((o) => o.v);
    } else {
      order = as.map((_, i) => (i + (roundNumber - 1)) % n);
    }
    for (let i = 0; i < n; i++) {
      pairings.push({
        id: uuid(),
        formatId: fmt.id,
        teamAPlayerId: as[i].id,
        teamBPlayerId: bs[order[i]].id,
        teamAGameWins: 0,
        teamBGameWins: 0,
        tieResolutionTeamId: null,
        completedAtSeconds: null,
      });
    }
  }
  return pairings;
}

function currentRound(doc: EventDoc): Round | undefined {
  return doc.rounds.find((r) => r.roundNumber === doc.currentRoundNumber);
}

// Resolve a single pairing purely from its game score:
//   0-0            → not_started (no result entered)
//   equal & > 0-0  → draw (e.g. 1-1) — counts as a draw, never a win
//   unequal valid  → decisive, winner by game score
//   2-2 or > 2     → invalid (blocks recording)
// Ties are NOT awarded to either team.
function resolvePairing(p: Pairing): PairingResolution {
  const a = p.teamAGameWins ?? 0;
  const b = p.teamBGameWins ?? 0;
  if (a > 2 || b > 2 || (a === 2 && b === 2)) {
    return { status: "invalid", winner: null, method: null };
  }
  if (a === 0 && b === 0) {
    return { status: "not_started", winner: null, method: null };
  }
  if (a === b) {
    return { status: "draw", winner: null, method: null };
  }
  return { status: "decisive", winner: a > b ? "a" : "b", method: "game_score" };
}

function playerTeamLookup(doc: EventDoc): (playerId: string) => string {
  const map = new Map(doc.players.map((p) => [p.id, p.teamId]));
  return (id: string) => map.get(id) ?? "";
}

function resolvePairings(_doc: EventDoc, pairings: Pairing[]): Record<string, PairingResolution> {
  const out: Record<string, PairingResolution> = {};
  for (const p of pairings) out[p.id] = resolvePairing(p);
  return out;
}

// Count matchup wins per team id for a set of pairings.
function winsByTeam(doc: EventDoc, pairings: Pairing[]): Record<string, number> {
  const playerTeam = playerTeamLookup(doc);
  const res = resolvePairings(doc, pairings);
  const counts: Record<string, number> = {};
  for (const p of pairings) {
    const w = res[p.id]?.winner;
    if (!w) continue;
    const team = playerTeam(w === "a" ? p.teamAPlayerId : p.teamBPlayerId);
    counts[team] = (counts[team] ?? 0) + 1;
  }
  return counts;
}

function computeScores(doc: EventDoc) {
  const result: Record<string, { recorded: number; pending: number; total: number }> = {};
  const cur = currentRound(doc);
  const recordedCounts: Record<string, number> = {};
  for (const r of doc.rounds.filter((r) => r.status === "recorded")) {
    const c = winsByTeam(doc, r.pairings);
    for (const [team, n] of Object.entries(c)) recordedCounts[team] = (recordedCounts[team] ?? 0) + n;
  }
  const pendingCounts =
    cur && cur.status !== "recorded" ? winsByTeam(doc, cur.pairings) : {};
  for (const team of doc.teams) {
    const recorded = recordedCounts[team.id] ?? 0;
    const pending = pendingCounts[team.id] ?? 0;
    result[team.id] = { recorded, pending, total: recorded + pending };
  }
  return result;
}

// A round is finalizable when every pairing has an entered result (decisive or
// draw) and none is invalid (2-2). Draws are legitimate final results.
function roundValidation(doc: EventDoc, round: Round) {
  const res = resolvePairings(doc, round.pairings);
  const invalid = round.pairings.filter((p) => res[p.id]?.status === "invalid");
  const notEntered = round.pairings.filter((p) => res[p.id]?.status === "not_started");
  return { res, invalid, notEntered };
}

// Shape returned to the client.
function bundle(doc: EventDoc, role: Role) {
  const cur = currentRound(doc);
  return {
    event: {
      id: doc.id,
      name: doc.name,
      status: doc.status,
      matchupMethod: doc.matchupMethod,
      numberOfRounds: doc.numberOfRounds,
      currentRoundNumber: doc.currentRoundNumber,
      drawsAllowed: doc.drawsAllowed,
      defaultTimerSeconds: doc.defaultTimerSeconds,
      updatedAt: doc.updatedAt,
    },
    teams: doc.teams,
    formats: doc.formats,
    players: doc.players,
    currentPairings: cur ? cur.pairings : [],
    recordedRounds: doc.rounds
      .filter((r) => r.status === "recorded")
      .map((r) => ({ roundNumber: r.roundNumber, pairings: r.pairings, recordedAt: r.recordedAt })),
    timer: doc.timer,
    members: doc.members,
    activity: doc.activity.slice(0, 20),
    audit: doc.audit,
    scores: computeScores(doc),
    role,
  };
}

function fail(c: any, status: number, message: string) {
  console.log(`Error ${status}: ${message}`);
  return c.json({ error: message }, status);
}

// ---------- routes ----------

app.get(`${PREFIX}/health`, (c) => c.json({ status: "ok" }));

// Sign up with email + password (email auto-confirmed since no mail server).
app.post(`${PREFIX}/signup`, async (c) => {
  try {
    const { email, password, name } = await c.req.json();
    if (!email || !password) return fail(c, 400, "Email and password are required for signup.");
    const { data, error } = await admin().auth.admin.createUser({
      email,
      password,
      user_metadata: { name: name ?? email },
      // Automatically confirm the user's email since an email server hasn't been configured.
      email_confirm: true,
    });
    if (error) return fail(c, 400, `Signup failed: ${error.message}`);
    await kv.set(profileKey(data.user!.id), {
      id: data.user!.id,
      email,
      displayName: name ?? email,
    });
    return c.json({ ok: true });
  } catch (e) {
    return fail(c, 500, `Unexpected error during signup: ${e}`);
  }
});

// List events the current user is a member of.
app.get(`${PREFIX}/events`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized: sign in to list events.");
  try {
    const ids: string[] = (await kv.get(userEventsKey(user.id))) ?? [];
    const docs: EventDoc[] = ids.length ? await kv.mget(ids.map(eventKey)) : [];
    const list = docs
      .filter(Boolean)
      .map((doc) => ({
        id: doc.id,
        name: doc.name,
        status: doc.status,
        teams: doc.teams,
        formats: doc.formats.length,
        numberOfRounds: doc.numberOfRounds,
        scores: computeScores(doc),
        role: roleOf(doc, user.id),
        updatedAt: doc.updatedAt,
        createdAt: doc.createdAt,
      }));
    return c.json({ events: list });
  } catch (e) {
    return fail(c, 500, `Failed to list events: ${e}`);
  }
});

// Create a full event atomically from a configuration payload.
app.post(`${PREFIX}/events`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized: sign in to create an event.");
  try {
    const cfg = await c.req.json();
    if (!cfg.name?.trim()) return fail(c, 400, "Event name cannot be blank.");
    if (!cfg.numberOfRounds || cfg.numberOfRounds < 1)
      return fail(c, 400, "Number of rounds must be at least 1.");
    if (!cfg.defaultTimerSeconds || cfg.defaultTimerSeconds <= 0)
      return fail(c, 400, "Default timer must be greater than 0.");
    if (!cfg.formats?.length || cfg.formats.length > 6)
      return fail(c, 400, "An event must have between 1 and 6 formats.");

    const id = uuid();
    const teams = (cfg.teams ?? []).map((t: any, i: number) => ({
      id: uuid(),
      name: t.name,
      color: t.color ?? (i === 0 ? "#00ffd9" : "#7c7cff"),
      displayOrder: i,
    }));
    const formats = cfg.formats.map((f: any, i: number) => ({
      id: uuid(),
      name: f.name,
      displayOrder: i,
    }));
    const players: EventDoc["players"] = [];
    for (const f of cfg.formats) {
      const fmt = formats.find((x: any) => x.name === f.name)!;
      (f.players ?? []).forEach((pl: any) => {
        const team = teams.find((t: any) => t.name === pl.teamName);
        if (!team) return;
        players.push({
          id: uuid(),
          teamId: team.id,
          formatId: fmt.id,
          name: pl.name,
          displayOrder: pl.displayOrder ?? 0,
        });
      });
    }

    const doc: EventDoc = {
      id,
      ownerId: user.id,
      name: cfg.name.trim(),
      status: "in_progress",
      matchupMethod: cfg.matchupMethod === "swiss" ? "swiss" : "round_robin",
      numberOfRounds: cfg.numberOfRounds,
      currentRoundNumber: 1,
      defaultTimerSeconds: cfg.defaultTimerSeconds,
      drawsAllowed: !!cfg.drawsAllowed,
      teams,
      formats,
      players,
      rounds: [],
      timer: {
        durationSeconds: cfg.defaultTimerSeconds,
        remainingSecondsAtChange: cfg.defaultTimerSeconds,
        status: "paused",
        lastStartedAt: null,
        roundNumber: 1,
      },
      members: [{ userId: user.id, email: user.email, role: "owner" }],
      activity: [],
      audit: [],
      createdAt: nowIso(),
      updatedAt: nowIso(),
    };
    // Create all rounds; generate pairings for round 1.
    for (let r = 1; r <= doc.numberOfRounds; r++) {
      doc.rounds.push({
        roundNumber: r,
        status: r === 1 ? "active" : "pending",
        pairings: r === 1 ? generatePairings(doc, 1) : [],
        recordedAt: null,
        recordedBy: null,
      });
    }
    pushActivity(doc, "event_created", user.id, { name: doc.name });
    pushActivity(doc, "pairings_generated", user.id, { roundNumber: 1 });

    await saveEvent(doc);
    const ids: string[] = (await kv.get(userEventsKey(user.id))) ?? [];
    await kv.set(userEventsKey(user.id), [...ids, id]);
    return c.json({ eventId: id });
  } catch (e) {
    return fail(c, 500, `Failed to create event: ${e}`);
  }
});

// Fetch the full event bundle for the current user.
app.get(`${PREFIX}/events/:id`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  const role = roleOf(doc, user.id);
  if (!role) return fail(c, 403, "You do not have access to this event.");
  return c.json(bundle(doc, role));
});

// Public share endpoint — no auth required, completed events only.
app.get(`${PREFIX}/events/:id/share`, async (c) => {
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  if (doc.status !== "completed") return fail(c, 403, "Only completed events can be shared publicly.");
  // Return a stripped bundle without sensitive member/audit data.
  const cur = currentRound(doc);
  return c.json({
    event: {
      id: doc.id,
      name: doc.name,
      status: doc.status,
      matchupMethod: doc.matchupMethod,
      numberOfRounds: doc.numberOfRounds,
      currentRoundNumber: doc.currentRoundNumber,
      drawsAllowed: doc.drawsAllowed,
      defaultTimerSeconds: doc.defaultTimerSeconds,
      updatedAt: doc.updatedAt,
    },
    teams: doc.teams,
    formats: doc.formats,
    players: doc.players,
    currentPairings: cur ? cur.pairings : [],
    recordedRounds: doc.rounds
      .filter((r) => r.status === "recorded")
      .map((r) => ({ roundNumber: r.roundNumber, pairings: r.pairings, recordedAt: r.recordedAt })),
    timer: doc.timer,
    members: [],
    activity: [],
    audit: [],
    scores: computeScores(doc),
    role: "viewer" as Role,
  });
});

// Set a pending pairing result on the current round.
app.post(`${PREFIX}/events/:id/result`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  const role = roleOf(doc, user.id);
  if (!canEdit(role)) return fail(c, 403, "Viewers cannot record results.");
  try {
    const { pairingId, teamAGameWins, teamBGameWins, tieResolutionTeamId, clockSecondsRemaining } = await c.req.json();
    const round = currentRound(doc);
    if (!round) return fail(c, 400, "No active round.");
    const pairing = round.pairings.find((p) => p.id === pairingId);
    if (!pairing) return fail(c, 404, "Pairing not found in current round.");
    const a = Number(teamAGameWins);
    const b = Number(teamBGameWins);
    if (![0, 1, 2].includes(a) || ![0, 1, 2].includes(b))
      return fail(c, 400, `Game wins must be 0, 1, or 2. Received ${a}-${b}.`);
    const wasDecisive = isPairingDecisive(pairing.teamAGameWins ?? 0, pairing.teamBGameWins ?? 0);
    pairing.teamAGameWins = a;
    pairing.teamBGameWins = b;
    // Any game-score change clears a prior manual tie resolution unless one is
    // explicitly supplied in this request.
    pairing.tieResolutionTeamId =
      tieResolutionTeamId !== undefined ? tieResolutionTeamId : null;
    // Stamp the timer's remaining seconds the first time this pairing becomes decisive.
    // Prefer the client's displayed clock value (sent at click time) over the server's
    // recomputed value, which arrives slightly later due to network latency.
    const nowDecisive = isPairingDecisive(a, b);
    if (!wasDecisive && nowDecisive) {
      pairing.completedAtSeconds =
        typeof clockSecondsRemaining === "number"
          ? clockSecondsRemaining
          : timerRemainingSeconds(doc.timer);
    } else if (wasDecisive && !nowDecisive) {
      pairing.completedAtSeconds = null;
    }
    await saveEvent(doc);
    return c.json(bundle(doc, role!));
  } catch (e) {
    return fail(c, 500, `Failed to set result: ${e}`);
  }
});

// Atomically record the current round and advance (idempotent per round).
app.post(`${PREFIX}/events/:id/record`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  const role = roleOf(doc, user.id);
  if (!canEdit(role)) return fail(c, 403, "Viewers cannot record rounds.");
  try {
    const { roundNumber } = await c.req.json();
    if (roundNumber !== doc.currentRoundNumber)
      return fail(c, 409, "That round is no longer the current round. Reload the event.");
    const round = currentRound(doc);
    if (!round) return fail(c, 400, "No active round.");
    if (round.status === "recorded") return c.json(bundle(doc, role!)); // idempotent
    const { invalid, notEntered } = roundValidation(doc, round);
    if (invalid.length)
      return fail(c, 400, `${invalid.length} pairing(s) have an invalid 2–2 score.`);
    if (notEntered.length)
      return fail(c, 400, `${notEntered.length} pairing(s) still need a result.`);

    round.status = "recorded";
    round.recordedAt = nowIso();
    round.recordedBy = user.id;
    pushActivity(doc, "round_recorded", user.id, { roundNumber });

    if (doc.currentRoundNumber >= doc.numberOfRounds) {
      doc.status = "completed";
      doc.timer.status = "completed";
      pushActivity(doc, "event_completed", user.id, {});
    } else {
      doc.currentRoundNumber += 1;
      const next = doc.rounds.find((r) => r.roundNumber === doc.currentRoundNumber)!;
      next.status = "active";
      if (!next.pairings.length) {
        next.pairings = generatePairings(doc, next.roundNumber);
        pushActivity(doc, "pairings_generated", user.id, { roundNumber: next.roundNumber });
      }
      doc.timer = {
        durationSeconds: doc.defaultTimerSeconds,
        remainingSecondsAtChange: doc.defaultTimerSeconds,
        status: "paused",
        lastStartedAt: null,
        roundNumber: doc.currentRoundNumber,
      };
    }
    await saveEvent(doc);
    return c.json(bundle(doc, role!));
  } catch (e) {
    return fail(c, 500, `Failed to record round: ${e}`);
  }
});

// Correct a previously recorded result, writing to the audit log.
app.post(`${PREFIX}/events/:id/correct`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  const role = roleOf(doc, user.id);
  if (!canEdit(role)) return fail(c, 403, "Viewers cannot correct results.");
  try {
    const { roundNumber, pairingId, teamAGameWins, teamBGameWins, tieResolutionTeamId, reason } =
      await c.req.json();
    const round = doc.rounds.find((r) => r.roundNumber === roundNumber);
    if (!round) return fail(c, 404, "Round not found.");
    if (round.status === "recorded" && !reason?.trim())
      return fail(c, 400, "A correction reason is required for recorded rounds.");
    const pairing = round.pairings.find((p) => p.id === pairingId);
    if (!pairing) return fail(c, 404, "Pairing not found.");
    if (doc.status === "archived") return fail(c, 400, "Archived events cannot be edited.");
    const a = Number(teamAGameWins);
    const b = Number(teamBGameWins);
    if (![0, 1, 2].includes(a) || ![0, 1, 2].includes(b))
      return fail(c, 400, `Game wins must be 0, 1, or 2. Received ${a}-${b}.`);
    if (a === 2 && b === 2) return fail(c, 400, "2–2 is not a valid result.");

    const prev = `${pairing.teamAGameWins ?? 0}-${pairing.teamBGameWins ?? 0}`;
    doc.audit.unshift({
      id: uuid(),
      roundNumber,
      pairingId,
      changedBy: user.id,
      previousResult: prev,
      newResult: `${a}-${b}`,
      reason: reason ?? "",
      at: nowIso(),
    });
    pairing.teamAGameWins = a;
    pairing.teamBGameWins = b;
    pairing.tieResolutionTeamId = tieResolutionTeamId ?? null;
    pushActivity(doc, "result_corrected", user.id, { roundNumber, pairingId, score: `${a}-${b}` });
    await saveEvent(doc);
    return c.json(bundle(doc, role!));
  } catch (e) {
    return fail(c, 500, `Failed to correct result: ${e}`);
  }
});

// Timer actions: start / pause / resume / set / reset. Uses server time.
app.post(`${PREFIX}/events/:id/timer`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  const role = roleOf(doc, user.id);
  if (!canEdit(role)) return fail(c, 403, "Viewers cannot change the timer.");
  try {
    const { action, seconds } = await c.req.json();
    const t = doc.timer;
    const now = Date.now();
    const remainingNow = () =>
      t.status === "running" && t.lastStartedAt
        ? t.remainingSecondsAtChange - Math.floor((now - t.lastStartedAt) / 1000)
        : t.remainingSecondsAtChange;
    switch (action) {
      case "start":
      case "resume":
        t.status = "running";
        t.lastStartedAt = now;
        break;
      case "pause":
        t.remainingSecondsAtChange = remainingNow();
        t.status = "paused";
        t.lastStartedAt = null;
        break;
      case "set":
        t.remainingSecondsAtChange = seconds ?? t.durationSeconds;
        t.status = "paused";
        t.lastStartedAt = null;
        break;
      case "reset":
        t.durationSeconds = seconds ?? doc.defaultTimerSeconds;
        t.remainingSecondsAtChange = t.durationSeconds;
        t.status = "paused";
        t.lastStartedAt = null;
        break;
      default:
        return fail(c, 400, `Unknown timer action: ${action}`);
    }
    pushActivity(doc, "timer_changed", user.id, { action });
    await saveEvent(doc);
    return c.json(bundle(doc, role!));
  } catch (e) {
    return fail(c, 500, `Failed to update timer: ${e}`);
  }
});

// Rename / update teams.
app.post(`${PREFIX}/events/:id/update`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  const role = roleOf(doc, user.id);
  if (!canEdit(role)) return fail(c, 403, "Viewers cannot edit the event.");
  try {
    const { name, teams } = await c.req.json();
    if (typeof name === "string" && name.trim()) doc.name = name.trim();
    if (Array.isArray(teams)) {
      for (const upd of teams) {
        const team = doc.teams.find((t) => t.id === upd.id);
        if (team) {
          if (upd.name?.trim()) team.name = upd.name.trim();
          if (upd.color) team.color = upd.color;
        }
      }
    }
    await saveEvent(doc);
    return c.json(bundle(doc, role!));
  } catch (e) {
    return fail(c, 500, `Failed to update event: ${e}`);
  }
});

// Archive (owner only).
app.post(`${PREFIX}/events/:id/archive`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  if (roleOf(doc, user.id) !== "owner") return fail(c, 403, "Only the owner can archive an event.");
  doc.status = "archived";
  pushActivity(doc, "event_archived", user.id, {});
  await saveEvent(doc);
  return c.json({ ok: true });
});

// Member management (owner only for role changes).
app.post(`${PREFIX}/events/:id/members`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  if (roleOf(doc, user.id) !== "owner") return fail(c, 403, "Only the owner can manage members.");
  try {
    const { op, email, role: newRole } = await c.req.json();
    if (op === "add") {
      if (doc.members.some((m) => m.email === email))
        return fail(c, 400, "That user is already a member.");
      // Look up the profile for this email if it exists.
      const profiles: any[] = await kv.getByPrefix("profile:");
      const profile = profiles.find((p) => p.email === email);
      doc.members.push({
        userId: profile?.id ?? `pending:${email}`,
        email,
        role: newRole === "viewer" ? "viewer" : "organizer",
      });
      if (profile?.id) {
        const ids: string[] = (await kv.get(userEventsKey(profile.id))) ?? [];
        if (!ids.includes(doc.id)) await kv.set(userEventsKey(profile.id), [...ids, doc.id]);
      }
    } else if (op === "update") {
      const m = doc.members.find((x) => x.email === email);
      if (m && m.role !== "owner") m.role = newRole;
    } else if (op === "remove") {
      const m = doc.members.find((x) => x.email === email);
      if (m?.role === "owner") return fail(c, 400, "An event must keep its owner.");
      doc.members = doc.members.filter((x) => x.email !== email);
    }
    await saveEvent(doc);
    return c.json(bundle(doc, "owner"));
  } catch (e) {
    return fail(c, 500, `Failed to manage members: ${e}`);
  }
});

// Seed a development event for the current user.
app.post(`${PREFIX}/events/seed`, async (c) => {
  const user = await getUser(c.req.raw);
  if (!user) return fail(c, 401, "Unauthorized.");
  try {
    const cfg = {
      name: "Denver Team League (Seed)",
      numberOfRounds: 5,
      defaultTimerSeconds: 3000,
      matchupMethod: "round_robin",
      drawsAllowed: false,
      teams: [
        { name: "Denver Games", color: "#00ffd9" },
        { name: "Denver Drafters", color: "#7c7cff" },
      ],
      formats: [
        {
          name: "Mystery Booster 2",
          players: [
            { teamName: "Denver Games", name: "Alex", displayOrder: 0 },
            { teamName: "Denver Games", name: "Jordan", displayOrder: 1 },
            { teamName: "Denver Games", name: "Sam", displayOrder: 2 },
            { teamName: "Denver Drafters", name: "Blake", displayOrder: 0 },
            { teamName: "Denver Drafters", name: "Drew", displayOrder: 1 },
            { teamName: "Denver Drafters", name: "Reese", displayOrder: 2 },
          ],
        },
        {
          name: "Final Fantasy",
          players: [
            { teamName: "Denver Games", name: "Riley", displayOrder: 0 },
            { teamName: "Denver Games", name: "Casey", displayOrder: 1 },
            { teamName: "Denver Games", name: "Morgan", displayOrder: 2 },
            { teamName: "Denver Drafters", name: "Skyler", displayOrder: 0 },
            { teamName: "Denver Drafters", name: "Parker", displayOrder: 1 },
            { teamName: "Denver Drafters", name: "Rowan", displayOrder: 2 },
          ],
        },
        {
          name: "Vintage cube",
          players: [
            { teamName: "Denver Games", name: "Taylor", displayOrder: 0 },
            { teamName: "Denver Games", name: "Quinn", displayOrder: 1 },
            { teamName: "Denver Games", name: "Avery", displayOrder: 2 },
            { teamName: "Denver Drafters", name: "Emerson", displayOrder: 0 },
            { teamName: "Denver Drafters", name: "Finley", displayOrder: 1 },
            { teamName: "Denver Drafters", name: "Hayden", displayOrder: 2 },
          ],
        },
      ],
    };
    // Reuse creation logic via an internal request.
    const res = await app.request(
      new Request(`http://internal${PREFIX}/events`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: c.req.header("Authorization") ?? "",
        },
        body: JSON.stringify(cfg),
      }),
    );
    const json = await res.json();
    const eventId = json.eventId;
    // Seed a recorded round + a few pending results + running timer.
    const doc = await loadEvent(eventId);
    if (doc) {
      const r1 = doc.rounds[0];
      r1.pairings.forEach((p, i) => {
        const aWins = i % 2 === 0;
        p.teamAGameWins = aWins ? 2 : 1;
        p.teamBGameWins = aWins ? 1 : 2;
      });
      r1.status = "recorded";
      r1.recordedAt = nowIso();
      r1.recordedBy = user.id;
      doc.currentRoundNumber = 2;
      const r2 = doc.rounds[1];
      r2.status = "active";
      r2.pairings = generatePairings(doc, 2);
      r2.pairings[0].teamAGameWins = 2;
      r2.pairings[0].teamBGameWins = 0;
      r2.pairings[3].teamAGameWins = 1;
      r2.pairings[3].teamBGameWins = 2;
      // One corrected historical result with an audit record.
      doc.audit.unshift({
        id: uuid(),
        roundNumber: 1,
        pairingId: r1.pairings[0].id,
        changedBy: user.id,
        previousResult: "1-2",
        newResult: `${r1.pairings[0].teamAGameWins}-${r1.pairings[0].teamBGameWins}`,
        reason: "Scorekeeper entry corrected",
        at: nowIso(),
      });
      doc.timer = {
        durationSeconds: 3000,
        remainingSecondsAtChange: 2400,
        status: "running",
        lastStartedAt: Date.now(),
        roundNumber: 2,
      };
      await saveEvent(doc);
    }
    return c.json({ eventId });
  } catch (e) {
    return fail(c, 500, `Failed to seed event: ${e}`);
  }
});

// Generate (or return cached) AI insights for a completed event.
// Completed events are publicly accessible (shared pages) — no auth required for those.
app.get(`${PREFIX}/events/:id/insights`, async (c) => {
  const user = await getUser(c.req.raw);
  const doc = await loadEvent(c.req.param("id"));
  if (!doc) return fail(c, 404, "Event not found.");
  // Allow unauthenticated access for completed events (public share links).
  // Authenticated members can access any event they belong to.
  const role = user ? roleOf(doc, user.id) : null;
  if (!role && doc.status !== "completed") return fail(c, 403, "Access denied.");

  const force = c.req.query("force") === "true";
  const cacheKey = `insights:${doc.id}`;

  if (!force) {
    const cached = await kv.get(cacheKey);
    if (cached) return c.json(cached);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) return fail(c, 503, "OpenAI API key not configured. Add OPENAI_API_KEY to edge function secrets.");

  // Build a structured data summary for the model.
  const playerMap = new Map(doc.players.map((p) => [p.id, p]));
  const formatMap = new Map(doc.formats.map((f) => [f.id, f]));
  const teamA = doc.teams[0];
  const teamB = doc.teams[1];
  const durationMinutes = Math.round(doc.timer.durationSeconds / 60);

  const recordedRounds = doc.rounds
    .filter((r) => r.status === "recorded")
    .sort((a, b) => a.roundNumber - b.roundNumber);

  // Aggregate tallies computed authoritatively here so the model never has to
  // (mis)count. Every recorded matchup is included exactly once.
  const teamTotals: Record<string, { matchWins: number; draws: number }> = {
    [teamA.name]: { matchWins: 0, draws: 0 },
    [teamB.name]: { matchWins: 0, draws: 0 },
  };
  // Per-player running record across the whole event.
  const playerRecords = new Map<
    string,
    { name: string; team: string; format: string; wins: number; losses: number; draws: number; gameWins: number; gameLosses: number }
  >();
  const ensureRecord = (pl: any) => {
    let rec = playerRecords.get(pl.id);
    if (!rec) {
      rec = {
        name: pl.name,
        team: doc.teams.find((t) => t.id === pl.teamId)?.name ?? "?",
        format: formatMap.get(pl.formatId)?.name ?? "?",
        wins: 0,
        losses: 0,
        draws: 0,
        gameWins: 0,
        gameLosses: 0,
      };
      playerRecords.set(pl.id, rec);
    }
    return rec;
  };
  const formatTotals = new Map<string, { format: string; teamAWins: number; teamBWins: number; draws: number }>();

  let totalMatchups = 0;
  let totalDraws = 0;

  const roundSummaries = recordedRounds.map((round) => {
    const res = resolvePairings(doc, round.pairings);
    let roundAWins = 0;
    let roundBWins = 0;
    let roundDraws = 0;

    const matchups = round.pairings.map((p) => {
      const pa = playerMap.get(p.teamAPlayerId);
      const pb = playerMap.get(p.teamBPlayerId);
      const fmt = formatMap.get(p.formatId);
      const resolution = res[p.id];
      const aGames = p.teamAGameWins ?? 0;
      const bGames = p.teamBGameWins ?? 0;
      const isDraw = resolution?.status === "draw";
      const winnerName =
        resolution?.winner === "a"
          ? pa?.name ?? "?"
          : resolution?.winner === "b"
            ? pb?.name ?? "?"
            : null;
      const minutesElapsed =
        p.completedAtSeconds != null
          ? +((doc.timer.durationSeconds - p.completedAtSeconds) / 60).toFixed(1)
          : null;

      totalMatchups++;
      const ft =
        formatTotals.get(p.formatId) ??
        formatTotals.set(p.formatId, {
          format: fmt?.name ?? "Unknown",
          teamAWins: 0,
          teamBWins: 0,
          draws: 0,
        }).get(p.formatId)!;

      // Update per-player records + team/format tallies.
      if (pa && pb) {
        const ra = ensureRecord(pa);
        const rb = ensureRecord(pb);
        ra.gameWins += aGames;
        ra.gameLosses += bGames;
        rb.gameWins += bGames;
        rb.gameLosses += aGames;
        if (isDraw) {
          ra.draws++;
          rb.draws++;
          ft.draws++;
          roundDraws++;
          totalDraws++;
          teamTotals[teamA.name].draws++;
          teamTotals[teamB.name].draws++;
        } else if (resolution?.winner === "a") {
          ra.wins++;
          rb.losses++;
          ft.teamAWins++;
          roundAWins++;
          teamTotals[teamA.name].matchWins++;
        } else if (resolution?.winner === "b") {
          rb.wins++;
          ra.losses++;
          ft.teamBWins++;
          roundBWins++;
          teamTotals[teamB.name].matchWins++;
        }
      }

      return {
        format: fmt?.name ?? "Unknown",
        playerA: pa?.name ?? "?",
        playerATeam: teamA.name,
        playerB: pb?.name ?? "?",
        playerBTeam: teamB.name,
        gameScore: `${aGames}-${bGames}`,
        result: isDraw ? "draw" : winnerName ? "decisive" : "no_result",
        matchupWinner: winnerName,
        isDraw,
        minutesElapsed,
      };
    });

    return {
      roundNumber: round.roundNumber,
      teamAMatchWins: roundAWins,
      teamBMatchWins: roundBWins,
      draws: roundDraws,
      matchups,
    };
  });

  const eventSummary = {
    eventName: doc.name,
    teamA: teamA.name,
    teamB: teamB.name,
    formats: doc.formats.map((f) => f.name),
    totalRounds: doc.numberOfRounds,
    timerDurationMinutes: durationMinutes,
    // Authoritative aggregate totals — trust these over any recount.
    totals: {
      totalMatchups,
      totalDraws,
      finalScore: {
        [teamA.name]: teamTotals[teamA.name].matchWins,
        [teamB.name]: teamTotals[teamB.name].matchWins,
      },
      drawsPerTeam: {
        [teamA.name]: teamTotals[teamA.name].draws,
        [teamB.name]: teamTotals[teamB.name].draws,
      },
    },
    formatTotals: Array.from(formatTotals.values()),
    playerRecords: Array.from(playerRecords.values()),
    rounds: roundSummaries,
  };

  const systemPrompt =
    "You are an expert Magic: The Gathering tournament analyst. Generate concise, specific, data-driven insights from tournament data. Always respond with valid JSON only.";

  const userPrompt = `Analyze this Magic: The Gathering team event and generate 5-6 specific insights:

${JSON.stringify(eventSummary, null, 2)}

CRITICAL DATA RULES — follow exactly:
- The "totals" object is the authoritative source of truth. The final score is
  totals.finalScore and the number of drawn matchups is totals.totalDraws. Never
  contradict these numbers or invent different ones.
- A draw (isDraw: true / result: "draw") is NOT a win for anyone. Never say a
  player or team "won" a drawn matchup. Draws count toward neither team's score.
- Only matchups with result: "decisive" have a matchupWinner. Use "playerRecords"
  for per-player win/loss/draw and game-win totals rather than recounting yourself.
- Every claim must be traceable to the data provided. Do not fabricate players,
  scores, streaks, or timings that are not present.

Return a JSON object with this exact structure (no other keys):
{
  "insights": [
    {
      "headline": "5-8 word headline",
      "body": "1-2 sentences using specific player names and numbers.",
      "type": "player" | "format" | "timing" | "trend" | "standout"
    }
  ]
}

Use these types:
- "player": individual win rates, player rankings, head-to-head records (from playerRecords)
- "format": which team dominated each format (from formatTotals), including draws
- "timing": how quickly matches concluded (only when minutesElapsed data is present)
- "trend": player or team form improving or declining across rounds
- "standout": sweeps, dominant records, upsets, clutch performances, notable draws

Use actual names and numbers. Do not write generic observations.`;

  try {
    const oaRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        response_format: { type: "json_object" },
        temperature: 0.7,
        max_tokens: 1400,
      }),
    });

    if (!oaRes.ok) {
      const errText = await oaRes.text();
      return fail(c, 502, `OpenAI error: ${errText.slice(0, 300)}`);
    }

    const oaJson = await oaRes.json();
    const content = oaJson.choices?.[0]?.message?.content;
    if (!content) return fail(c, 502, "OpenAI returned an empty response.");

    const parsed = JSON.parse(content);
    const result = {
      insights: Array.isArray(parsed.insights) ? parsed.insights : [],
      generatedAt: nowIso(),
    };

    // Cache so repeated views don't re-call OpenAI.
    await kv.set(cacheKey, result);
    return c.json(result);
  } catch (e) {
    return fail(c, 500, `Insights generation failed: ${e}`);
  }
});

Deno.serve(app.fetch);
