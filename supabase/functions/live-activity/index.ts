// live-activity: keeps a player's Live Activity and widgets in step with their event.
//   POST { action: "state", include_demo? }        Authorization: Bearer <user JWT>  (demo: TestFlight builds only)
//        -> { snapshots: [{ eventId, eventName, participantId, state }] }  (widgets + app refresh)
//   POST { action: "dispatch", kind, event_id, ... }  x-t1-secret: <db secret>   (database triggers only)
//        kinds: round_started | match | round_recorded | clock | event_ended | dropped
// Push policy (battery): nothing is sent on a timer. The countdown renders on-device from endsAt, so a
// push only goes out when what the player sees changes, and only to the players it changes for.
// Rank-only changes ride at priority 5 (delivered opportunistically); match changes at 10.
import { createClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendAll, type Push } from "./apns.ts";
import { buildStates, toParticipant, toRound, type PlayerState } from "./state.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function loadEvent(eventId: string) {
  const [ev, parts, rounds] = await Promise.all([
    admin.from("events").select("id, name, status, current_round, number_of_rounds, round_length_seconds, allow_player_reporting, show_clock").eq("id", eventId).maybeSingle(),
    admin.from("participants").select("id, event_id, pod_id, user_id, display_name, seat, status, dropped_in_round").eq("event_id", eventId),
    admin.from("rounds").select("*, matches(*, match_sides(*))").eq("event_id", eventId).order("number"),
  ]);
  if (ev.error) throw ev.error;
  if (parts.error) throw parts.error;
  if (rounds.error) throw rounds.error;
  return { event: ev.data, participants: (parts.data ?? []).map(toParticipant), rounds: (rounds.data ?? []).map(toRound) };
}

// ---------------------------------------------------------------- state (widgets, app)

async function stateFor(authHeader: string, includeDemo: boolean) {
  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
  const { data: u, error } = await asCaller.auth.getUser(authHeader.slice(7));
  if (error || !u.user) return json({ error: "Sign in required" }, 401);
  const { data: seats } = await admin.from("participants").select("id, event_id").eq("user_id", u.user.id);
  const eventIds = [...new Set((seats ?? []).map((s) => s.event_id))];
  if (!eventIds.length) return json({ snapshots: [] });
  let liveQuery = admin.from("events").select("id").in("id", eventIds).in("status", ["seated", "in_progress"]);
  if (!includeDemo) liveQuery = liveQuery.eq("is_demo", false);
  const { data: live } = await liveQuery.order("updated_at", { ascending: false }).limit(3);
  const mine = new Set((seats ?? []).map((s) => s.id));
  const snapshots = [];
  for (const e of live ?? []) {
    const { event, participants, rounds } = await loadEvent(e.id);
    if (!event) continue;
    for (const s of buildStates(event, participants, rounds, mine)) {
      snapshots.push({ ...s.attributes, state: s.state });
    }
  }
  return json({ snapshots });
}

// ---------------------------------------------------------------- dispatch (database → APNs)

type Kind = "round_started" | "match" | "round_recorded" | "clock" | "event_ended" | "dropped";
const now = () => Math.floor(Date.now() / 1000);

function aps(event: "start" | "update" | "end", ps: PlayerState, alert?: { title: string; body: string }) {
  const s = ps.state;
  const stale = s.endsAt ? s.endsAt + 15 * 60 : now() + 3 * 3600;
  // deno-lint-ignore no-explicit-any
  const a: any = { timestamp: now(), event, "content-state": s, "stale-date": stale,
    "relevance-score": s.phase === "playing" ? 100 : 50 };
  if (event === "start") { a["attributes-type"] = "PlayerActivityAttributes"; a.attributes = ps.attributes; }
  if (event === "end") { a["dismissal-date"] = s.phase === "dropped" ? now() : now() + 30 * 60; delete a["stale-date"]; }
  if (alert) a.alert = { ...alert, sound: "default" };
  return { aps: a };
}

function roundAlert(ps: PlayerState) {
  const s = ps.state;
  if (s.phase === "bye") return { title: `${ps.attributes.eventName} · Round ${s.round}`, body: "You have the bye this round." };
  return { title: `${ps.attributes.eventName} · Round ${s.round}`, body: `Table ${s.table ?? "–"} vs ${s.oppName ?? "your opponent"}` };
}

async function dispatch(body: Record<string, unknown>) {
  if (!apnsConfigured()) return json({ ok: true, skipped: "APNs key not configured" });
  const kind = body.kind as Kind;
  const eventId = String(body.event_id ?? "");
  const { event, participants, rounds } = await loadEvent(eventId);
  if (!event) return json({ ok: true, skipped: "event not found" });

  let only: Set<string> | undefined;
  if (kind === "match") {
    const ids = new Set((body.match_ids as string[]) ?? []);
    only = new Set(rounds.flatMap((r) => r.matches).filter((m) => ids.has(m.id))
      .flatMap((m) => m.sides.map((s) => s.participantId)).filter(Boolean) as string[]);
  } else if (kind === "dropped") {
    only = new Set([String(body.participant_id)]);
  }
  const states = buildStates(event, participants, rounds, only);
  if (!states.length) return json({ ok: true, sent: 0 });

  const { data: tokens, error } = await admin.from("live_activity_tokens")
    .select("token, kind, env, event_id, user_id").in("user_id", [...new Set(states.map((s) => s.userId))]).is("revoked_at", null);
  if (error) throw error;

  const pushes: Push[] = [];
  for (const ps of states) {
    const mine = (tokens ?? []).filter((t) => t.user_id === ps.userId);
    const update = mine.filter((t) => t.kind === "update" && t.event_id === eventId);
    const start = mine.filter((t) => t.kind === "start");
    const to = (list: typeof mine, priority: 5 | 10, payload: unknown) =>
      list.forEach((t) => pushes.push({ token: t.token, env: t.env, priority, payload }));
    switch (kind) {
      case "round_started":
        if (update.length) to(update, 10, aps("update", ps, roundAlert(ps)));
        else if (ps.state.phase === "playing" || ps.state.phase === "bye") to(start, 10, aps("start", ps, roundAlert(ps)));
        break;
      case "match": {
        const s = ps.state;
        const alert = s.status === "reported_them"
          ? { title: `${s.oppName} reported ${s.myWins}–${s.theirWins}`, body: "Confirm or dispute from here." } : undefined;
        to(update, 10, aps("update", ps, alert));
        break;
      }
      case "round_recorded": to(update, 5, aps("update", ps)); break;
      case "clock": to(update, 10, aps("update", ps)); break;
      case "event_ended":
        to(update, 10, aps("end", ps, ps.state.phase === "cancelled"
          ? { title: ps.attributes.eventName, body: "This event was cancelled by the organizer." } : undefined));
        break;
      case "dropped": to(update, 10, aps("end", ps)); break;
    }
  }
  if (!pushes.length) return json({ ok: true, sent: 0 });

  const results = await sendAll(pushes);
  const dead = results.filter((r) => r.status === 410 || ["BadDeviceToken", "Unregistered", "ExpiredToken"].includes(r.reason ?? ""))
    .map((r) => r.token);
  if (dead.length) {
    await admin.from("live_activity_tokens").update({ revoked_at: new Date().toISOString() }).in("token", dead);
  }
  const failed = results.filter((r) => r.status !== 200);
  console.log(JSON.stringify({ kind, event: eventId, sent: results.length - failed.length, failed: failed.length,
    reasons: [...new Set(failed.map((f) => f.reason))] }));
  return json({ ok: true, sent: results.length - failed.length, failed: failed.length });
}

// ---------------------------------------------------------------- entry

let secretOk: string | null = null;
async function internal(req: Request) {
  const s = req.headers.get("x-t1-secret") ?? "";
  if (!s) return false;
  if (secretOk === s) return true;
  const { data } = await admin.rpc("live_push_secret_ok", { p_secret: s });
  if (data === true) secretOk = s;
  return data === true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    if (body.action === "state") {
      const auth = req.headers.get("Authorization") ?? "";
      if (!auth.startsWith("Bearer ")) return json({ error: "Sign in required" }, 401);
      return await stateFor(auth, body.include_demo === true);
    }
    if (body.action === "dispatch") {
      if (!(await internal(req))) return json({ error: "Forbidden" }, 403);
      if (!/^[0-9a-f-]{36}$/i.test(String(body.event_id ?? ""))) return json({ error: "event_id is required" }, 400);
      return await dispatch(body);
    }
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
