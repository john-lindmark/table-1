// live-activity: keeps a player's Live Activity and widgets in step with their event.
//   POST { action: "state", include_demo? }        Authorization: Bearer <user JWT>  (demo: listed testers only)
//        -> { snapshots: [{ eventId, eventName, participantId, state }],
//             organizer: [{ eventId, eventName, state }] }  (widgets + app refresh; organizer: events you run)
//   POST { action: "dispatch", kind, event_id, ... }  x-t1-secret: <db secret>   (database triggers only)
//        kinds: round_started | match | round_recorded | clock | event_ended | dropped
// Push policy (battery): nothing is sent on a timer. The countdown renders on-device from endsAt, so a
// push only goes out when what the player sees changes, and only to the players it changes for.
// Rank-only changes ride at priority 5 (delivered opportunistically); match changes at 10.
import { createClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendAll, type Push } from "./apns.ts";
import { organizerMessage, organizerPlan, playerMessage, playerPlan } from "./android.ts";
import { deadToken, fcmConfigured, sendAll as fcmSendAll, type AndroidAlert } from "../notify-worker/fcm.ts";
import { buildOrganizerState, organizerAlert, type OrgState } from "./organizer.ts";
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
  // Demo events only for accounts on the tester list, whatever the build asks for.
  if (includeDemo) includeDemo = (await asCaller.rpc("demo_tester")).data === true;
  const [{ data: seats }, { data: runs }] = await Promise.all([
    admin.from("participants").select("id, event_id").eq("user_id", u.user.id),
    admin.from("event_members").select("event_id").eq("user_id", u.user.id),
  ]);
  const liveEvents = async (ids: string[]) => {
    if (!ids.length) return [];
    let q = admin.from("events").select("id").in("id", ids).in("status", ["seated", "in_progress"]);
    if (!includeDemo) q = q.eq("is_demo", false);
    const { data } = await q.order("updated_at", { ascending: false }).limit(3);
    return (data ?? []).map((e) => e.id as string);
  };
  const [playing, running] = await Promise.all([
    liveEvents([...new Set((seats ?? []).map((s) => s.event_id as string))]),
    liveEvents([...new Set((runs ?? []).map((r) => r.event_id as string))]),
  ]);
  const mine = new Set((seats ?? []).map((s) => s.id));
  const snapshots = [];
  const organizer = [];
  for (const id of new Set([...playing, ...running])) {
    const { event, participants, rounds } = await loadEvent(id);
    if (!event) continue;
    if (playing.includes(id)) {
      for (const s of buildStates(event, participants, rounds, mine)) snapshots.push({ ...s.attributes, state: s.state });
    }
    if (running.includes(id)) {
      const o = buildOrganizerState(event, participants, rounds);
      organizer.push({ ...o.attributes, state: o.state });
    }
  }
  return json({ snapshots, organizer });
}

// ---------------------------------------------------------------- dispatch (database → APNs, FCM)

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

// deno-lint-ignore no-explicit-any
function orgAps(event: "start" | "update" | "end", o: OrgState, alert?: { title: string; body: string }): any {
  const s = o.state;
  // deno-lint-ignore no-explicit-any
  const a: any = { timestamp: now(), event, "content-state": s,
    "stale-date": s.endsAt ? s.endsAt + 15 * 60 : now() + 3 * 3600, "relevance-score": s.phase === "live" ? 90 : 40 };
  if (event === "start") { a["attributes-type"] = "OrganizerActivityAttributes"; a.attributes = o.attributes; }
  if (event === "end") { a["dismissal-date"] = now() + 30 * 60; delete a["stale-date"]; }
  if (alert) a.alert = { ...alert, sound: "default" };
  return { aps: a };
}

function roundAlert(ps: PlayerState) {
  const s = ps.state;
  if (s.phase === "bye") return { title: `${ps.attributes.eventName} · Round ${s.round}`, body: "You have the bye this round." };
  return { title: `${ps.attributes.eventName} · Round ${s.round}`, body: `Table ${s.table ?? "–"} vs ${s.oppName ?? "your opponent"}` };
}

async function dispatch(body: Record<string, unknown>) {
  const apns = apnsConfigured(), fcm = fcmConfigured();
  if (!apns && !fcm) return json({ ok: true, skipped: "no push credentials" });
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
  const { data: members } = await admin.from("event_members").select("user_id").eq("event_id", eventId);
  const organizers = new Set((members ?? []).map((m) => m.user_id as string));
  const users = new Set([...states.map((s) => s.userId), ...organizers]);
  if (!users.size) return json({ ok: true, sent: 0 });

  const android = fcm ? await androidLive(kind, body, event, participants, rounds, states, organizers) : { sent: 0, failed: 0 };
  if (!apns) return json({ ok: true, sent: android.sent, failed: android.failed });

  const { data: tokens, error } = await admin.from("live_activity_tokens")
    .select("token, kind, env, event_id, user_id").in("user_id", [...users]).is("revoked_at", null);
  if (error) throw error;

  const pushes: Push[] = [];
  // Organizers: one state for the event, to each organizer's own tokens (org_start / org_update).
  const orgTokens = (tokens ?? []).filter((t) => organizers.has(t.user_id) &&
    (t.kind === "org_start" || (t.kind === "org_update" && t.event_id === eventId)));
  if (orgTokens.length) {
    const o = buildOrganizerState(event, participants, rounds);
    const update = orgTokens.filter((t) => t.kind === "org_update");
    const to = (list: typeof orgTokens, priority: 5 | 10, payload: unknown) =>
      list.forEach((t) => pushes.push({ token: t.token, env: t.env, priority, payload }));
    switch (kind) {
      case "round_started":
        for (const uid of organizers) {
          const theirs = orgTokens.filter((t) => t.user_id === uid);
          const upd = theirs.filter((t) => t.kind === "org_update");
          if (upd.length) to(upd, 10, orgAps("update", o));
          else if (o.state.phase === "live") to(theirs.filter((t) => t.kind === "org_start"), 10, orgAps("start", o));
        }
        break;
      case "match": {
        const ids = new Set((body.match_ids as string[]) ?? []);
        const table = rounds.flatMap((r) => r.matches).find((m) => ids.has(m.id) && m.disputed)?.tableNumber;
        to(update, 10, orgAps("update", o, organizerAlert(o, { disputed: body.disputed === true, settled: body.settled === true }, table)));
        break;
      }
      case "round_recorded": case "clock": to(update, 10, orgAps("update", o)); break;
      case "dropped": to(update, 5, orgAps("update", o)); break;
      case "event_ended": to(update, 10, orgAps("end", o)); break;
    }
  }

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
  if (!pushes.length) return json({ ok: true, sent: android.sent, failed: android.failed });

  const results = await sendAll(pushes);
  const dead = results.filter((r) => r.status === 410 || ["BadDeviceToken", "Unregistered", "ExpiredToken"].includes(r.reason ?? ""))
    .map((r) => r.token);
  if (dead.length) {
    await admin.from("live_activity_tokens").update({ revoked_at: new Date().toISOString() }).in("token", dead);
  }
  const failed = results.filter((r) => r.status !== 200);
  console.log(JSON.stringify({ kind, event: eventId, sent: results.length - failed.length, failed: failed.length,
    reasons: [...new Set(failed.map((f) => f.reason))] }));
  return json({ ok: true, sent: results.length - failed.length + android.sent, failed: failed.length + android.failed });
}

/** Android devices (devices.platform = android) of the players whose state changed and of the organizers: the state
 *  itself in a data-only FCM message, drawn by the app as its live notification (android.ts). */
async function androidLive(kind: Kind, body: Record<string, unknown>, event: Awaited<ReturnType<typeof loadEvent>>["event"],
  participants: Awaited<ReturnType<typeof loadEvent>>["participants"], rounds: Awaited<ReturnType<typeof loadEvent>>["rounds"],
  states: PlayerState[], organizers: Set<string>) {
  const users = [...new Set([...states.map((s) => s.userId), ...organizers])];
  if (!users.length) return { sent: 0, failed: 0 };
  const { data: devices, error } = await admin.from("devices").select("user_id, push_token").eq("platform", "android").in("user_id", users);
  if (error) throw error;
  if (!devices?.length) return { sent: 0, failed: 0 };
  const alerts: AndroidAlert[] = [];
  const op = organizerPlan(kind);
  if (op && organizers.size) {
    const o = buildOrganizerState(event!, participants, rounds);
    let alert: { title: string; body: string } | undefined;
    if (kind === "match") {
      const ids = new Set((body.match_ids as string[]) ?? []);
      const table = rounds.flatMap((r) => r.matches).find((m) => ids.has(m.id) && m.disputed)?.tableNumber;
      alert = organizerAlert(o, { disputed: body.disputed === true, settled: body.settled === true }, table);
    }
    for (const d of devices) if (organizers.has(d.user_id)) alerts.push(organizerMessage(d.push_token, o, op.event, op.priority, alert));
  }
  const pp = playerPlan(kind);
  if (pp) for (const ps of states) {
    for (const d of devices) if (d.user_id === ps.userId) alerts.push(playerMessage(d.push_token, ps, pp.event, pp.priority));
  }
  if (!alerts.length) return { sent: 0, failed: 0 };
  const results = await fcmSendAll(alerts);
  const dead = results.filter(deadToken).map((r) => r.token);
  if (dead.length) await admin.from("devices").delete().in("push_token", dead);
  const failed = results.filter((r) => r.status !== 200).length;
  console.log(JSON.stringify({ kind, event: event!.id, android_sent: results.length - failed, android_failed: failed }));
  return { sent: results.length - failed, failed };
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
