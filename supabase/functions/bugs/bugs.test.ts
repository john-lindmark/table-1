import { assert, assertEquals } from "jsr:@std/assert@1";
import { parse as parseSentry, platformOf, supabasePath, verify } from "./sentry.ts";
import { fallback, parse, prompt, rule } from "./triage.ts";

const fixture = async (name: string) =>
  JSON.parse(await Deno.readTextFile(new URL(`../../../testdata/bugs/${name}`, import.meta.url)));

async function sign(body: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)))]
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.test("webhook signatures: right secret only", async () => {
  const body = '{"action":"triggered"}';
  const sig = await sign(body, "client-secret-123456");
  assert(await verify(body, sig, "client-secret-123456"));
  assert(!(await verify(body, sig, "another-secret-1234")));
  assert(!(await verify(body + " ", sig, "client-secret-123456")));
  assert(!(await verify(body, null, "client-secret-123456")));
  assert(!(await verify(body, sig, "")));
});

Deno.test("an iOS crash alert becomes an iOS bug with frames and no personal data", async () => {
  const r = parseSentry("event_alert", await fixture("event-alert-ios-crash.json"))!;
  assertEquals([r.fingerprint, r.platform, r.level, r.environment, r.release, r.events, r.spike],
    ["sentry:6012345678", "ios", "fatal", "testflight", "site.table1.events@1.0+8", 1, false]);
  const d = r.detail as { exception: Array<{ frames: Array<{ file: string; line: number }> }>; breadcrumbs: Array<{ url?: string }>; tags: Record<string, string> };
  assertEquals(d.exception[0].frames.map((f) => `${f.file}:${f.line}`), ["Table1App.swift:12", "OrganizerPhases.swift:841"]);
  assertEquals(d.breadcrumbs[1].url, "https://aaozhfcbvqrgkkrihkrd.supabase.co/rest/v1/rpc/event_bundle");
  const all = JSON.stringify(r);
  for (const leak of ["ana@example.com", "203.0.113.9", "0000000000a1", "event_id=eq"]) assert(!all.includes(leak), `leaked ${leak}`);
  assertEquals(d.tags.user, undefined);
});

Deno.test("a 5xx from Supabase is one server bug per endpoint, whichever app saw it", async () => {
  const r = parseSentry("event_alert", await fixture("event-alert-http-500.json"))!;
  assertEquals([r.fingerprint, r.platform, r.title, r.spike], ["http:POST /rest/v1/rpc/report_result", "server", "HTTP 500 from /rest/v1/rpc/report_result", true]);
  assert(!JSON.stringify(r).includes("XYZW"), "join codes in page URLs are stripped");
  assertEquals(supabasePath("https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/events-engine?x=1"), "/functions/v1/events-engine");
  assertEquals(supabasePath("https://aaozhfcbvqrgkkrihkrd.supabase.co/rest/v1/events?id=eq.1"), "/rest/v1/events");
  assertEquals(supabasePath("https://aaozhfcbvqrgkkrihkrd.supabase.co/storage/v1/object/avatars/0f9e8d7c-aaaa-bbbb-cccc-000000000001/a.jpg"), "/storage/v1/object/avatars");
  assertEquals(supabasePath("https://table-1.site/rest/v1/rpc/x"), null);
});

Deno.test("issue created carries the user count; other actions and resources file nothing", async () => {
  const issue = await fixture("issue-created-android.json");
  const r = parseSentry("issue", issue)!;
  assertEquals([r.fingerprint, r.platform, r.users, r.events], ["sentry:6012340001", "android", 1, 0]);
  assertEquals(parseSentry("issue", { ...issue, action: "resolved" }), null);
  assertEquals(parseSentry("installation", { action: "created", data: {} }), null);
  assertEquals(parseSentry("issue", { action: "created", data: { issue: { id: "1", title: "HTTP Client Error with status code: 502" } } }), null);
});

Deno.test("platform from project slug, else SDK", () => {
  assertEquals(platformOf({ project: "table1-web" }), "web");
  assertEquals(platformOf({ sdk: "sentry.java.android" }), "android");
  assertEquals(platformOf({ platform: "cocoa" }), "ios");
  assertEquals(platformOf({ platform: "python" }), "unknown");
});

const bug = (title: string, level = "error") => ({ id: 1, source: "sentry", platform: "ios", title, level });

Deno.test("rules: network noise is S4 without asking the model; crashes never are", () => {
  for (const t of ["NSURLErrorDomain Code=-1009", "The Internet connection appears to be offline.", "AbortError: The user aborted a request.",
    "java.net.UnknownHostException: Unable to resolve host", "ResizeObserver loop limit exceeded", "ChunkLoadError: Loading chunk 12 failed"]) {
    assertEquals(rule(bug(t))?.severity, "S4", t);
  }
  assertEquals(rule(bug("The network connection was lost", "fatal")), null);
  assertEquals(rule(bug("Fatal error: Index out of range")), null);
});

Deno.test("model answers by index; anything missing falls back (crash S2, error S3)", () => {
  const bugs = [bug("a", "fatal"), { ...bug("b"), id: 2 }, { ...bug("c", "fatal"), id: 3 }];
  const v = parse({ results: [{ i: 1, severity: "S1", reason: "Blocks results" }, { i: 0, severity: "S9", reason: "" }] }, bugs);
  assertEquals(v.map((x) => [x.id, x.severity, x.by]), [[1, "S2", "rules"], [2, "S1", "claude"], [3, "S2", "rules"]]);
  assertEquals(parse(null, [bug("x")])[0].severity, "S3");
  assertEquals(fallback(bug("x", "fatal")).severity, "S2");
});

Deno.test("the prompt carries what severity depends on, and no fix details", async () => {
  const r = parseSentry("event_alert", await fixture("event-alert-ios-crash.json"))!;
  const p = prompt([{ id: 7, source: "sentry", platform: r.platform, title: r.title, level: r.level, detail: r.detail, events: 3, users: 2 }]);
  assert(p.includes("OrganizerPhases.swift:841"));
  assert(p.includes('"users": 2'));
  assert(!p.includes('"id": 7'), "bug ids stay out of the prompt (answers come back by index)");
});
