import type { PostHog } from "posthog-js/dist/module.slim";
import type * as SentryNS from "./sentry";
import { redactPath, redactSearch, redactUrl, scrubProperties, stripQuery } from "./analytics";
import { layoutNow } from "./desktop";
import { supabase } from "./supabaseClient";

/**
 * Product analytics (PostHog) and error reporting (Sentry), per contract/telemetry-2026-10-15.md.
 * Properties are counts, enums and booleans only: never names, free text, join codes or row ids.
 * Off when VITE_POSTHOG_KEY / VITE_SENTRY_DSN are empty, in dev unless VITE_TELEMETRY=1, and when the person
 * turns off "Share usage and crash data" in Account (stored per browser). Both SDKs load as their own chunks,
 * only when they're on.
 */

export type Props = Record<string, string | number | boolean>;

const OPT_OUT_KEY = "table1.telemetry.optedOut";
/** The provider a sign-in redirect left for, so the return can be counted as signed_in / sign_in_failed. */
const PENDING_SIGN_IN_KEY = "table1.telemetry.signIn";

const env = import.meta.env;
const POSTHOG_KEY = env.VITE_POSTHOG_KEY ?? "";
const POSTHOG_HOST = env.VITE_POSTHOG_HOST || "https://us.i.posthog.com";
const SENTRY_DSN = env.VITE_SENTRY_DSN ?? "";
const ENVIRONMENT = env.PROD ? "production" : "dev";
const ALLOWED_IN_BUILD = env.PROD || env.VITE_TELEMETRY === "1";
const VERSION = __APP_VERSION__;
const BUILD = __APP_BUILD__;

let posthog: PostHog | null = null;
let sentry: typeof SentryNS | null = null;
/** Calls made while the SDKs load, replayed in order once they're in. */
let queue: (() => void)[] | null = null;
let started = false;
let userId: string | null = null;

/** `session` picks sessionStorage; outside a browser (tests) there's no storage. */
function storage(session = false): Storage | undefined {
  if (typeof window === "undefined") return undefined;
  try {
    return session ? window.sessionStorage : window.localStorage;
  } catch {
    return undefined;
  }
}

function read(key: string, session = false): string | null {
  try {
    return storage(session)?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function write(key: string, value: string | null, session = false) {
  const store = storage(session);
  try {
    if (value === null) store?.removeItem(key);
    else store?.setItem(key, value);
  } catch {
    /* storage blocked: the setting lasts for this page only */
  }
}

let optedOut = read(OPT_OUT_KEY) === "1";

/** "Share usage and crash data" (on by default). */
export function sharing(): boolean {
  return !optedOut;
}

function run(fn: () => void) {
  if (queue) queue.push(fn);
  else if (started) fn();
}

/** Called once from main.tsx, before the app renders. */
export function startTelemetry() {
  if (started || !ALLOWED_IN_BUILD || optedOut || (!POSTHOG_KEY && !SENTRY_DSN)) return;
  started = true;
  queue = [];
  void Promise.all([
    SENTRY_DSN ? import("./sentry").then(startSentry) : null,
    POSTHOG_KEY ? import("posthog-js/dist/module.slim").then((m) => startPostHog(m.default)) : null,
  ])
    .catch(() => {
      /* blocked by an extension or offline: the app runs without telemetry */
    })
    .finally(() => {
      const pending = queue ?? [];
      queue = null;
      pending.forEach((fn) => fn());
    });
  watchAuth();
}

function startSentry(S: typeof SentryNS) {
  const origin = window.location.origin;
  const scrubPage = (url: string) => redactUrl(url, origin) || stripQuery(url);
  // Same-site URLs keep their (redacted) path; Supabase and other hosts lose the query, where PostgREST filters carry ids.
  const scrubAny = (url: string) =>
    url.startsWith("/") ? redactPath(stripQuery(url)) : url.startsWith(origin) ? scrubPage(url) : stripQuery(url);
  const scrubWords = (text: string) => text.split(" ").map((w) => (/^(https?:\/\/|\/)/.test(w) ? scrubAny(w) : w)).join(" ");
  S.init({
    dsn: SENTRY_DSN,
    environment: ENVIRONMENT,
    release: `site.table1.events@${VERSION}+${BUILD}`,
    // Sentry 11's replacement for sendDefaultPii: false. Its defaults collect all of these, so each is off.
    dataCollection: {
      userInfo: false,
      cookies: false,
      httpHeaders: false,
      httpBodies: [],
      urlQueryParams: false,
      stackFrameVariables: false,
    },
    integrations: [
      S.browserTracingIntegration(),
      // 4xx is how RLS and validation answer; only server failures are bugs.
      S.httpClientIntegration({ failedRequestStatusCodes: [[500, 599]] }),
    ],
    tracesSampleRate: ENVIRONMENT === "production" ? 0.1 : 1.0,
    beforeBreadcrumb(crumb) {
      const data = crumb.data as Record<string, unknown> | undefined;
      if (data) {
        if (typeof data.url === "string") data.url = scrubAny(data.url);
        // Navigation breadcrumbs: from/to are paths on this site.
        if (typeof data.from === "string") data.from = redactPath(stripQuery(data.from));
        if (typeof data.to === "string") data.to = redactPath(stripQuery(data.to));
      }
      return crumb;
    },
    beforeSend(event) {
      if (event.request) {
        if (event.request.url) event.request.url = scrubAny(event.request.url);
        delete event.request.query_string;
        delete event.request.cookies;
        if (event.request.headers) delete event.request.headers.Referer;
      }
      if (event.transaction) event.transaction = scrubWords(event.transaction);
      return event;
    },
    // Spans stream (Sentry 11's default), so page-load/navigation names and fetch URLs are cleaned here.
    beforeSendSpan(span) {
      span.name = scrubWords(span.name);
      const attrs = span.attributes as Record<string, unknown>;
      for (const [k, v] of Object.entries(attrs)) {
        if (/query|fragment/i.test(k)) delete attrs[k];
        else if (typeof v === "string" && /^(https?:\/\/|\/)/.test(v)) attrs[k] = scrubWords(v);
        else if (v && typeof v === "object" && typeof (v as { value?: unknown }).value === "string") {
          const a = v as { value: string };
          if (/^(https?:\/\/|\/)/.test(a.value)) a.value = scrubWords(a.value);
        }
      }
      return span;
    },
  });
  sentry = S;
  if (env.DEV) (window as unknown as { __t1Sentry?: typeof SentryNS }).__t1Sentry = S;
}

function startPostHog(ph: PostHog) {
  const origin = window.location.origin;
  ph.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    autocapture: false,
    rageclick: false,
    capture_dead_clicks: false,
    capture_heatmaps: false,
    capture_exceptions: false, // Sentry's job
    capture_performance: false,
    capture_pageview: false, // sent by hand from the router, with the path redacted
    capture_pageleave: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_product_tours: true,
    disable_conversations: true,
    disable_web_experiments: true,
    // No remote scripts (recorder, toolbar, surveys): what runs is what's in the bundle.
    disable_external_dependency_loading: true,
    advanced_disable_flags: true,
    mask_personal_data_properties: true,
    person_profiles: "identified_only",
    before_send: (e) => {
      if (!e) return e;
      scrubProperties(e.properties, origin);
      scrubProperties(e.$set, origin);
      scrubProperties(e.$set_once, origin);
      return e;
    },
  });
  if (ph.has_opted_out_capturing()) ph.opt_in_capturing(); // an earlier opt-out; this only runs while sharing is on
  ph.register({ platform: "web", app_version: VERSION, build: BUILD, environment: ENVIRONMENT });
  posthog = ph;
  // Dev only: lets the console watch what's sent (window.__t1PostHog.on("eventCaptured", console.log);
  // window.__t1Sentry.getClient().on("beforeEnvelope", console.log)).
  if (env.DEV) (window as unknown as { __t1PostHog?: PostHog }).__t1PostHog = ph;
}

/* ── identity ─────────────────────────────────────────────────────────── */

/** The Supabase user id only: no email or name, in either tool. */
function identify(id: string) {
  if (id === userId) return;
  userId = id;
  run(() => {
    posthog?.identify(id, { platform: "web" }, { first_seen_app_version: VERSION });
    sentry?.setUser({ id });
  });
}

function reset() {
  userId = null;
  run(() => {
    posthog?.reset();
    sentry?.setUser(null);
  });
}

/** Call just before the OAuth redirect leaves the page. */
export function signInStarted(method: "apple" | "google" | "email") {
  write(PENDING_SIGN_IN_KEY, JSON.stringify({ method, at: Date.now() }), true);
}

function pendingSignIn(): string | null {
  const raw = read(PENDING_SIGN_IN_KEY, true);
  if (!raw) return null;
  write(PENDING_SIGN_IN_KEY, null, true);
  try {
    const p = JSON.parse(raw) as { method: string; at: number };
    return Date.now() - p.at < 30 * 60_000 ? p.method : null;
  } catch {
    return null;
  }
}

function watchAuth() {
  supabase.auth.onAuthStateChange((event, session) => {
    // Supabase calls listeners while holding its auth lock; anything that touches auth waits a tick.
    setTimeout(() => {
      const id = session?.user.id ?? null;
      if (id) identify(id);
      if (event === "SIGNED_OUT") return reset();
      if (event !== "INITIAL_SESSION" && event !== "SIGNED_IN") return;
      if (id && event === "SIGNED_IN") {
        const method = pendingSignIn();
        if (method) capture("signed_in", { method });
      } else if (!id && event === "INITIAL_SESSION") {
        // Back from the provider without a session: cancelled at Apple/Google, or an error.
        const method = pendingSignIn();
        if (method) {
          const q = new URLSearchParams(window.location.search + "&" + window.location.hash.slice(1));
          const err = q.get("error");
          capture("sign_in_failed", { method, reason: !err || err === "access_denied" ? "cancelled" : "error" });
        }
      }
    }, 0);
  });
}

/* ── events ───────────────────────────────────────────────────────────── */

export function capture(event: string, properties?: Props) {
  run(() => posthog?.capture(event, properties));
}

/** Runs a server call and records `event` only once the server has accepted it. */
export async function after<T>(event: string, properties: Props | ((value: T) => Props) | undefined, work: () => Promise<T>): Promise<T> {
  const value = await work();
  capture(event, typeof properties === "function" ? properties(value) : properties);
  return value;
}

/** A screen inside a route (a tab or segment): `$screen` with the contract's screen name. */
export function screen(name: string) {
  run(() => posthog?.capture("$screen", { $screen_name: name }));
}

export interface Span {
  finish: (ok?: boolean) => void;
}

/** A Sentry performance span (e.g. roto.state); a no-op while Sentry is off. Finish it once. */
export function span(name: string, op: string): Span {
  let s: ReturnType<typeof SentryNS.startInactiveSpan> | undefined;
  let done = false;
  run(() => {
    if (!done) s = sentry?.startInactiveSpan({ name, op, forceTransaction: true });
  });
  return {
    finish(ok = true) {
      if (done) return;
      done = true;
      if (!ok) s?.setStatus({ code: 2, message: "internal_error" });
      s?.end();
    },
  };
}

/** One redacted page view per navigation; `screen` is the contract's screen name when the route has one, `layout`
 *  whether the desktop layout was showing. */
export function pageView(pathname: string, search: string, screen: string | undefined) {
  const path = redactPath(pathname);
  const props: Props = { $current_url: `${window.location.origin}${path}${redactSearch(search)}`, $pathname: path, layout: layoutNow() };
  if (screen) props.$screen_name = screen;
  run(() => posthog?.capture("$pageview", props));
}

/** A failure the app recovered from but that shouldn't happen. */
export function reportError(error: unknown, area: string) {
  run(() => sentry?.captureException(error, { tags: { area } }));
}

/* ── opt-out ──────────────────────────────────────────────────────────── */

export function setSharing(on: boolean) {
  if (on === sharing()) return;
  if (on) {
    optedOut = false;
    write(OPT_OUT_KEY, null);
    if (!started) startTelemetry();
    else
      run(() => {
        if (posthog?.has_opted_out_capturing()) posthog.opt_in_capturing();
        if (sentry) startSentry(sentry); // close() ended the client; a new one starts clean
      });
    const id = userId;
    userId = null;
    if (id) identify(id);
  } else {
    capture("analytics_opted_out");
    run(() => {
      posthog?.opt_out_capturing();
      void sentry?.close(2000);
    });
    optedOut = true;
    write(OPT_OUT_KEY, "1");
  }
}
