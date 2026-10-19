// Sentry webhooks → bug reports (contract/bug-pipeline-2026-10-18.md). No network here; index.ts verifies and files.
// Two resources matter: `event_alert` (an alert rule fired, with the full event: exception, frames, breadcrumbs, tags)
// and `issue` (created: carries the issue's count and userCount). Failed requests to Supabase (the SDKs' HTTP client
// errors for 5xx) are the server's bug, grouped by path across all three apps.

export interface Report {
  fingerprint: string;
  source: "sentry";
  platform: "ios" | "android" | "web" | "server" | "unknown";
  title: string;
  culprit?: string;
  level?: string;
  link?: string;
  environment?: string;
  release?: string;
  events?: number;
  users?: number;
  spike?: boolean;
  seen_at?: string;
  detail?: Record<string, unknown>;
}

/** Sentry signs the raw body with the integration's client secret: hex HMAC-SHA256. */
export async function verify(body: string, signature: string | null, secret: string): Promise<boolean> {
  if (!signature || !secret) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)));
  const hex = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (hex.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

const PROJECTS: Record<string, Report["platform"]> = { "table1-ios": "ios", "table1-android": "android", "table1-web": "web" };

export function platformOf(p: { project?: string; platform?: string; sdk?: string }): Report["platform"] {
  if (p.project && PROJECTS[p.project]) return PROJECTS[p.project];
  const s = `${p.sdk ?? ""} ${p.platform ?? ""}`.toLowerCase();
  if (/cocoa|swift|ios/.test(s)) return "ios";
  if (/android|java|kotlin/.test(s)) return "android";
  if (/javascript|react|browser/.test(s)) return "web";
  return "unknown";
}

const stripQuery = (u: string) => u.split(/[?#]/)[0];
const clip = (s: unknown, n: number) => (typeof s === "string" ? s.slice(0, n) : undefined);

/** /rest/v1/rpc/<fn>, /functions/v1/<fn>, /rest/v1/<table>, /auth/v1/<x>, /storage/v1/object/<bucket>: ids folded. */
export function supabasePath(url: string): string | null {
  let u: URL;
  try { u = new URL(url); } catch { return null; }
  if (!u.hostname.endsWith(".supabase.co") && !u.hostname.endsWith(".supabase.in")) return null;
  const parts = u.pathname.split("/").filter(Boolean);
  const keep = parts[0] === "storage" ? 4 : parts[1] === "v1" && parts[2] === "rpc" ? 4 : 3;
  return "/" + parts.slice(0, keep).map((p) => (/^[0-9a-f-]{16,}$|^\d+$/i.test(p) ? "<id>" : p)).join("/");
}

const HTTP_5XX = /HTTP Client Error with status code: (5\d\d)/i;

interface SentryFrame { filename?: string; abs_path?: string; function?: string; module?: string; lineno?: number; colno?: number; in_app?: boolean; package?: string }
interface SentryEvent {
  event_id?: string; issue_id?: string | number; web_url?: string; issue_url?: string; title?: string; culprit?: string;
  level?: string; platform?: string; release?: string; environment?: string; datetime?: string; timestamp?: number;
  project?: string | number; transaction?: string;
  exception?: { values?: Array<{ type?: string; value?: string; mechanism?: { type?: string; handled?: boolean }; stacktrace?: { frames?: SentryFrame[] } }> };
  breadcrumbs?: { values?: Array<{ category?: string; message?: string; level?: string; type?: string; data?: Record<string, unknown> }> };
  tags?: Array<[string, string]> | Array<{ key: string; value: string }>;
  request?: { url?: string; method?: string };
  contexts?: Record<string, Record<string, unknown>>;
  sdk?: { name?: string };
}

const TAGS = new Set(["os", "os.name", "device", "device.family", "browser", "browser.name", "release", "environment", "dist",
  "handled", "mechanism", "level", "app.device", "runtime", "url", "transaction"]);

function tagMap(tags: SentryEvent["tags"]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const t of tags ?? []) {
    const [k, v] = Array.isArray(t) ? t : [t.key, t.value];
    if (TAGS.has(k)) out[k] = k === "url" ? stripQuery(String(v)) : String(v).slice(0, 120);
  }
  return out;
}

/** The latest sample kept on the bug: what a fixer needs, nothing that names a person. */
export function sample(e: SentryEvent): Record<string, unknown> {
  const exc = (e.exception?.values ?? []).slice(-3).map((x) => {
    const frames = x.stacktrace?.frames ?? [];
    const inApp = frames.filter((f) => f.in_app);
    return {
      type: clip(x.type, 200), value: clip(x.value, 500), mechanism: x.mechanism?.type, handled: x.mechanism?.handled,
      // Innermost last, as Sentry sends them. In-app frames when there are any, else the top of the stack.
      frames: (inApp.length ? inApp : frames).slice(-25).map((f) => ({
        file: clip(f.filename ?? f.abs_path, 200), fn: clip(f.function, 200), module: clip(f.module ?? f.package, 200),
        line: f.lineno, col: f.colno, in_app: f.in_app ?? false,
      })),
    };
  });
  const crumbs = (e.breadcrumbs?.values ?? []).slice(-20).map((b) => ({
    category: b.category, level: b.level, message: clip(b.message, 200),
    url: typeof b.data?.url === "string" ? stripQuery(b.data.url) : undefined,
    status: b.data?.status_code ?? b.data?.["http.response.status_code"],
  }));
  const app = e.contexts?.app ?? {};
  return {
    kind: "sentry", event_id: e.event_id, exception: exc, breadcrumbs: crumbs, tags: tagMap(e.tags),
    transaction: clip(e.transaction, 200), sdk: e.sdk?.name,
    request: e.request?.url ? { method: e.request.method, url: stripQuery(e.request.url) } : undefined,
    app: { version: app.app_version, build: app.app_build },
  };
}

/** One webhook → the report to file, or null for resources and actions that aren't occurrences. */
export function parse(resource: string | null, payload: Record<string, unknown>): Report | null {
  const data = (payload.data ?? {}) as Record<string, unknown>;
  if (resource === "event_alert") {
    const e = (data.event ?? {}) as SentryEvent;
    if (!e.issue_id && !e.title) return null;
    const tags = tagMap(e.tags);
    const environment = e.environment ?? tags.environment;
    const release = e.release ?? tags.release;
    const title = String(e.title ?? e.exception?.values?.at(-1)?.type ?? "Unknown error");
    const http = title.match(HTTP_5XX) ?? (e.exception?.values?.at(-1)?.value ?? "").match(HTTP_5XX);
    const path = http && e.request?.url ? supabasePath(e.request.url) : null;
    const rule = String(data.triggered_rule ?? "");
    const base = {
      source: "sentry" as const, level: e.level, link: e.web_url, environment, release, events: 1,
      spike: /spike/i.test(rule), seen_at: e.datetime ?? (e.timestamp ? new Date(e.timestamp * 1000).toISOString() : undefined),
      detail: { ...sample(e), rule: rule || undefined },
    };
    if (path) {
      // A 5xx from Supabase: one server bug per endpoint, whichever app saw it.
      return { ...base, fingerprint: `http:${[e.request?.method?.toUpperCase(), path].filter(Boolean).join(" ")}`,
        platform: "server", title: `HTTP ${http![1]} from ${path}`, culprit: path };
    }
    return { ...base, fingerprint: `sentry:${e.issue_id ?? e.event_id}`, title: title.slice(0, 300), culprit: clip(e.culprit, 300),
      platform: platformOf({ platform: e.platform, sdk: e.sdk?.name }) };
  }
  if (resource === "issue" && payload.action === "created") {
    const i = (data.issue ?? {}) as Record<string, unknown>;
    if (!i.id) return null;
    const project = (i.project ?? {}) as { slug?: string };
    const metadata = (i.metadata ?? {}) as Record<string, unknown>;
    const title = String(i.title ?? "Unknown error");
    // An issue for a 5xx carries no request URL; the event alert for it files the server bug. Count nothing here.
    if (HTTP_5XX.test(title)) return null;
    return {
      fingerprint: `sentry:${i.id}`, source: "sentry", title: title.slice(0, 300), culprit: clip(i.culprit, 300),
      level: clip(i.level, 20), link: clip(i.permalink ?? i.web_url, 300), events: 0,
      users: Number(i.userCount ?? 0) || 0, seen_at: clip(i.lastSeen, 40),
      platform: platformOf({ project: project.slug, platform: String(i.platform ?? "") }),
      detail: { kind: "sentry", issue: { type: metadata.type, value: clip(metadata.value, 500), filename: metadata.filename, function: metadata.function } },
    };
  }
  return null;
}
