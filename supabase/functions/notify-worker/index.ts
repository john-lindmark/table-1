// notify-worker: sends the push notifications queued in pgmq `notify` (see enqueue_notification).
//   POST {}   x-t1-secret: <db secret>   kicked by the database right after a message is queued, and by the
//             t1-notify-sweep cron job every minute as a fallback.
// Each message is one audience (kind, event_id, user_ids, data); this expands it to devices, writes the alert
// text per kind (per recipient where it differs, e.g. their table and opponent), and sends through APNs (iOS)
// and FCM (Android, FCM_SERVICE_ACCOUNT). A platform whose credentials aren't set is skipped and counted.
// Messages older than 30 minutes are dropped rather than sent late.
import { createClient } from "npm:@supabase/supabase-js@2";
import { apnsConfigured, sendAll, type Alert } from "./apns.ts";
import * as fcm from "./fcm.ts";
import { followCopy, tradeWantsCopy } from "./follow.ts";
import { wantPriceCopy } from "./want-price.ts";
import { insightsNewCopy } from "./insights-new.ts";
import { signUpCopy, type SignUpCount } from "./sign-up.ts";
import { deckFoundCopy } from "./deck-found.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const STALE_MS = 30 * 60 * 1000;

interface Message {
  kind: string;
  event_id: string | null;
  user_ids: string[];
  data: Record<string, unknown>;
}

interface Copy { title: string; body: string; priority?: 5 | 10 }

const score = (d: Record<string, unknown>) => {
  const s = `${d.side0 ?? 0}–${d.side1 ?? 0}`;
  return Number(d.draws ?? 0) > 0 ? `${s}–${d.draws}` : s;
};

/** Alert text for one recipient. `mine` is that player's match this round, when the kind needs it. */
function copy(m: Message, eventName: string, mine?: { table: number | null; opponent: string | null; side: number },
              count?: SignUpCount | null): Copy | null {
  const d = m.data ?? {};
  const name = String(d.event_name ?? eventName ?? "Your event");
  switch (m.kind) {
    case "event.new": {
      const where = d.venue_name ? ` at ${d.venue_name}` : "";
      const who = d.organizer ? `${d.organizer} posted an event${where}.` : `New event${where}.`;
      return { title: name, body: `${who} Tap to join.` };
    }
    case "event.nearby":
      return { title: "Event nearby", body: `${name}${d.venue_name ? ` · ${d.venue_name}` : ""}. Tap to join.` };
    case "event.invite":
      return { title: "You're invited", body: `${name}${d.venue_name ? ` · ${d.venue_name}` : ""}` };
    case "event.cancelled":
      return { title: `${name} is cancelled`, body: d.reason ? String(d.reason) : "The organizer called it off." };
    case "event.waitlist_in":
      return { title: "You're in", body: `A place opened in ${name}${d.venue_name ? ` · ${d.venue_name}` : ""}.` };
    // contract/scheduled-events-2026-10-27.md § Organizer pushes: to the organizers; the app opens the event.
    case "event.signed_up":
    case "event.dropped":
      return { ...signUpCopy(m.kind, { ...d, event_name: name }, count ?? null), priority: 5 };
    case "round.paired": {
      const stage = ({ quarterfinal: "Quarterfinals", semifinal: "Semifinals", final: "The final" } as Record<string, string>)[String(d.stage)];
      const round = stage ?? (d.round ? `Round ${d.round}` : "Next round");
      if (mine && mine.opponent) {
        return { title: `${round} is up`, body: `Table ${mine.table ?? "–"} vs ${mine.opponent}` };
      }
      return { title: `${round} is up`, body: mine ? "You have the bye." : name };
    }
    case "result.reported": {
      if (!mine) return { title: "Result reported", body: name };
      // Score from this player's side first.
      const my = mine.side === 0 ? d.side0 : d.side1, their = mine.side === 0 ? d.side1 : d.side0;
      const draws = Number(d.draws ?? 0) > 0 ? `–${d.draws}` : "";
      return { title: "Confirm your result", body: `${mine.opponent ?? "Your opponent"} reported ${my}–${their}${draws}. Tap to confirm or dispute.` };
    }
    case "result.disputed":
      return { title: "Result disputed", body: `Table ${d.table ?? "–"} reported different scores. ${name}` };
    case "result.changed":
      return { title: "Result changed", body: `The organizer set your match to ${score(d)}.`, priority: 5 };
    // Friends (contract/friends-sharing-2026-10-18.md): no event; the app opens Account → Friends.
    case "friend.request":
      return { title: "Friend request", body: `${d.from_name ?? "Someone"} wants to be friends on Table 1.`, priority: 5 };
    case "friend.accepted":
      return { title: "New friend", body: `${d.from_name ?? "Someone"} accepted your friend request.`, priority: 5 };
    // contract/cube-rankings-2026-10-21.md: someone else started a ranking of your cube; the app opens it.
    case "ranking.started":
      return { title: d.cube_name ? String(d.cube_name) : "Your cube", body: `${d.from_name ?? "Someone"} is ranking your cube. Tap to watch.`, priority: 5 };
    // contract/follows-2026-10-25.md: a round of changes to a binder, deck or cube you follow; the app opens its Changes.
    case "follow.updated":
      return { ...followCopy(d), priority: 5 };
    // contract/follows-2026-10-25.md § Trade wants: a friend put cards you want up for trade; the app opens your match.
    case "trade.wants":
      return { ...tradeWantsCopy(d), priority: 5 };
    // contract/want-prices-2026-10-26.md: wants that got cheaper or fell to their max; the app opens Wants.
    case "want.price":
      return { ...wantPriceCopy(d), priority: 5 };
    // contract/insights-2026-10-24.md § New in Insights: a new format, set, cube version or set to rank; the app opens it.
    case "insights.new":
      return { ...insightsNewCopy(d), priority: 5 };
    // contract/deck-finder-2026-10-15.md § Jobs: a deck search finished; the app opens Find a deck on it.
    case "deck.found":
      return { ...deckFoundCopy(d), priority: 5 };
    // contract/moderation-2026-10-18.md: what changed, never why in the alert (the Notices screen says why).
    case "moderation.notice": {
      if (d.restricted_days) return { title: "Table 1", body: `You can't send friend requests for ${d.restricted_days} days. Tap for details.`, priority: 5 };
      if (d.appeal === "revert") return { title: "Appeal accepted", body: `${d.label ?? "Your content"} is back.`, priority: 5 };
      if (d.appeal === "uphold") return { title: "Appeal reviewed", body: `The change to ${String(d.label ?? "your content").toLowerCase()} stays.`, priority: 5 };
      const what = d.action === "unshare" ? `${d.label} is no longer shared` : d.action === "hide_photo" ? "Your deck photo was hidden"
        : d.action === "remove_avatar" ? "Your profile photo was removed" : `${d.label ?? "Something you posted"} was changed`;
      return { title: "From Table 1", body: `${what}. Tap to see why or appeal.`, priority: 5 };
    }
    case "moderation.review":
      if (d.urgent) return { title: "Urgent review", body: "A photo was taken down for child safety. Review it now.", priority: 10 };
      if (d.appeal) return { title: "New appeal", body: "Someone appealed a moderation decision.", priority: 5 };
      return { title: "To review", body: `${d.open ?? "Some"} item${d.open === 1 ? "" : "s"} waiting in Review.`, priority: 5 };
    // contract/bug-pipeline-2026-10-18.md: only the bug watchers (John) get these.
    case "ops.bug":
      return { title: `${d.regressed ? "S1 is back" : "New S1"} · ${platformName(d.platform)}`, body: String(d.title ?? "A severe bug came in."), priority: 10 };
    case "ops.build": {
      const server = d.server === true;
      const builds = (Array.isArray(d.platforms) ? d.platforms : []).filter((p) => p !== "server");
      const title = builds.length
        ? `${builds.map(platformName).join(" + ")} build needed${server ? " + server deploy" : ""}`
        : "Server deploy needed";
      return { title, body: `Fixes waiting: ${d.summary ?? ""}`, priority: 5 };
    }
    default:
      return null;
  }
}

const platformName = (p: unknown) => ({ ios: "iOS", android: "Android", web: "Web", server: "Server" } as Record<string, string>)[String(p)] ?? "App";

/** For kinds about "your match": each recipient's match (table, opponent, side). */
async function matchesFor(m: Message): Promise<Map<string, { table: number | null; opponent: string | null; side: number }>> {
  const out = new Map<string, { table: number | null; opponent: string | null; side: number }>();
  let matchIds: string[] = [];
  if (m.kind === "round.paired") {
    const { data: round } = await admin.from("rounds").select("id").eq("event_id", m.event_id)
      .eq("number", Number(m.data?.round ?? 0)).maybeSingle();
    if (!round) return out;
    const { data } = await admin.from("matches").select("id").eq("round_id", round.id);
    matchIds = (data ?? []).map((r) => r.id);
  } else if (m.kind === "result.reported" && m.data?.match_id) {
    matchIds = [String(m.data.match_id)];
  } else {
    return out;
  }
  if (!matchIds.length) return out;
  const { data: matches } = await admin.from("matches")
    .select("id, table_number, match_sides(side, user_id, participant_id, participants(display_name))").in("id", matchIds);
  for (const match of matches ?? []) {
    const sides = (match.match_sides ?? []) as Array<{ side: number; user_id: string | null; participants: { display_name: string } | null }>;
    for (const s of sides) {
      if (!s.user_id) continue;
      const other = sides.find((o) => o.side !== s.side);
      out.set(s.user_id, { table: match.table_number, opponent: other?.participants?.display_name ?? null, side: s.side });
    }
  }
  return out;
}

/** For sign-up and drop pushes: the player count now, read when sending so a waitlist move-up is counted. */
async function signUpCount(m: Message): Promise<SignUpCount | null> {
  if ((m.kind !== "event.signed_up" && m.kind !== "event.dropped") || !m.event_id) return null;
  const [{ data: event }, { count: players, error: perr }, { count: waiting, error: werr }] = await Promise.all([
    admin.from("events").select("capacity").eq("id", m.event_id).maybeSingle(),
    admin.from("participants").select("id", { count: "exact", head: true }).eq("event_id", m.event_id).eq("status", "active"),
    admin.from("event_waitlist").select("user_id", { count: "exact", head: true }).eq("event_id", m.event_id),
  ]);
  if (perr || werr || players == null) return null;
  return { players, capacity: (event?.capacity as number | null) ?? null, waiting: waiting ?? 0 };
}

async function run() {
  const apns = apnsConfigured(), android = fcm.fcmConfigured();
  if (!apns && !android) return json({ ok: false, reason: "Neither APNs nor FCM is configured" });
  const { data: claimed, error } = await admin.rpc("notify_claim", { p_n: 100 });
  if (error) throw error;
  const rows = (claimed ?? []) as Array<{ msg_id: number; enqueued_at: string; message: Message }>;
  if (!rows.length) return json({ ok: true, messages: 0 });

  const done: number[] = [];
  let sent = 0, failed = 0, skipped = 0, stale = 0;
  const dead: string[] = [];
  for (const row of rows) {
    done.push(row.msg_id);
    const m = row.message;
    if (Date.now() - new Date(row.enqueued_at).getTime() > STALE_MS) { stale++; continue; }
    let users = [...new Set(m.user_ids ?? [])];
    // Ops pushes (bugs, builds) reach the bug watchers only, whoever queued them.
    if (m.kind.startsWith("ops.") && users.length) {
      const { data: watchers, error: werr } = await admin.rpc("notify_ops_recipients", { p_user_ids: users });
      if (werr) console.error("ops recipients", werr.message);   // fail closed: nobody, and the rest still go out
      users = werr ? [] : (watchers ?? []) as string[];
    }
    if (!users.length) continue;
    const [{ data: devices }, { data: prefs }, { data: event }] = await Promise.all([
      admin.from("devices").select("user_id, platform, push_token, env").in("user_id", users),
      admin.from("notification_prefs").select("user_id, muted_kinds").in("user_id", users),
      m.event_id
        ? admin.from("events").select("name, is_demo").eq("id", m.event_id).maybeSingle()
        : Promise.resolve({ data: null }),
    ]);
    if (!devices?.length) continue;
    const muted = new Set((prefs ?? []).filter((p) => (p.muted_kinds ?? []).includes(m.kind)).map((p) => p.user_id));
    const mine = await matchesFor(m);
    const count = await signUpCount(m);
    // The same for every recipient: what a tap opens (the apps route by these keys), the collapse key and the group.
    const collapseId = `${m.kind}:${m.event_id ?? m.data?.ranking_id ?? m.data?.item_id ?? m.data?.user_id ?? m.data?.bug_id ?? m.data?.insights_key ?? m.data?.job_id ?? ""}`.slice(0, 64);
    const thread = m.event_id ?? (m.kind.startsWith("ops.") ? "ops" : m.kind.startsWith("ranking.") ? "rankings"
      : m.kind.startsWith("follow.") ? "following" : m.kind.startsWith("trade.") ? "trades"
      : m.kind.startsWith("want.") ? "wants" : m.kind.startsWith("insights.") ? "insights" : m.kind.startsWith("deck.") ? "decks" : "friends");
    const info = {
      kind: m.kind, event_id: m.event_id, match_id: m.data?.match_id ?? null, ranking_id: m.data?.ranking_id ?? null, bug_id: m.data?.bug_id ?? null,
      ...(m.kind === "follow.updated" ? { follow_kind: m.data?.kind ?? null, item_id: m.data?.item_id ?? null } : {}),
      ...(m.kind === "trade.wants" ? { user_id: m.data?.user_id ?? null } : {}),
      ...(m.kind === "insights.new"
        ? { insights_section: m.data?.insights_section ?? null, insights_key: m.data?.insights_key ?? null, what: m.data?.what ?? null } : {}),
      ...(m.kind === "deck.found" ? { job_id: m.data?.job_id ?? null, status: m.data?.status ?? null } : {}),
    };
    const alerts: Alert[] = [];
    const androidAlerts: fcm.AndroidAlert[] = [];
    for (const d of devices) {
      if (muted.has(d.user_id)) continue;
      const ios = d.platform === "ios";
      if (!(ios ? apns : d.platform === "android" && android)) { skipped++; continue; }
      const c = copy(m, event?.name ?? "", mine.get(d.user_id), count);
      if (!c) continue;
      if (!ios) {
        androidAlerts.push({ token: d.push_token, title: c.title, body: c.body, priority: c.priority ?? 10, tag: collapseId, group: thread, info });
        continue;
      }
      alerts.push({
        token: d.push_token, env: d.env === "development" ? "development" : "production", priority: c.priority ?? 10,
        collapseId,
        payload: { aps: { alert: { title: c.title, body: c.body }, sound: "default", "thread-id": thread }, ...info },
      });
    }
    const [results, androidResults] = await Promise.all([sendAll(alerts), fcm.sendAll(androidAlerts)]);
    for (const r of results) {
      if (r.status === 200) sent++;
      else {
        failed++;
        if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered") dead.push(r.token);
      }
    }
    for (const r of androidResults) {
      if (r.status === 200) sent++;
      else {
        failed++;
        if (fcm.deadToken(r)) dead.push(r.token);
        else console.error("fcm", r.status, r.reason);
      }
    }
  }
  await admin.rpc("notify_done", { p_ids: done });
  if (dead.length) await admin.from("devices").delete().in("push_token", dead);
  console.log(JSON.stringify({ messages: rows.length, sent, failed, dead: dead.length, stale, skipped }));
  // More waiting: go again (the next kick or the minute sweep would also pick it up).
  if (rows.length === 100) queueMicrotask(() => run().catch(console.error));
  return json({ ok: true, messages: rows.length, sent, failed, stale, skipped });
}

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
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!(await internal(req))) return json({ error: "Forbidden" }, 403);
  try {
    return await run();
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
