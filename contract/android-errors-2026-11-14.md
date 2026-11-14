# Android: errors that leaked the request, the launch flash, events you're not in (2026-11-14)

John, 2026-11-14: "Android users are seeing these types of errors for events. I've also noticed that when I open the
android app it will show an error momentarily and then clear it which is annoying and gives the impression of
instability." The screenshot showed an event screen whose error was supabase-kt's whole exception: "That event isn't
available", the URL, and the request headers, the person's access token and the anon key among them.

Android only. iOS and the web show the server's message alone already. No server change.

## Error text

supabase-kt builds a refused call's message as the server's message, then `URL: …`, `Headers: [Authorization=[Bearer
<token>], apikey=[…], …]`, `Http Method: …`. One rule, `util/ErrorText.kt`:

- `ErrorText.of(e)`: what a screen says. A failure to reach the server reads "Couldn't reach Table 1. Check your
  connection."; a server refusal reads the server's own message (`RestException.error`); anything else its first line.
  Never a token. `userMessage(e)` is this.
- `Notice` passes its text through `ErrorText.safe`, so a screen that still hands it `e.message` shows only the first
  line (a raw message is one carrying `URL:`, `Headers: [`, `Http Method:` or a JWT). `Offline.notice` does the same.
- Sentry: `Telemetry.scrub` removes the headers and any JWT from exception values, event messages and breadcrumb
  messages before sending (`ErrorText.redacted`; the URL and method stay). Every Android report before this carried the
  reporter's access token.

Tests `ErrorTextTest`, `TelemetryTest.reportedExceptionsLoseTheHeaders`.

## The launch flash

Live API logs on 2026-11-14 showed Android calls answered 401 on returns to the app (`events_home`,
`events_followed`, `people`, `friends_list`, `library_summary_get`, `event_follow_get`). supabase-kt resets the session to
Initializing on every trip to the background and reloads it on the way back, refreshing an expired token in the
background; `SessionView` keeps the signed-in screens up meanwhile (2026-10-30), and their loads went out with the anon
key (no session yet) or the expired token. The screen showed the error until its next load.

`util/FreshToken.kt`, an OkHttp interceptor on the Supabase client, holds such a call:

- a call carrying the anon key while the session is still loading waits for it (then a spent token is refreshed);
- a call whose token expires within 15 s waits for a fresh one: supabase-kt's own refresh first (3 s), else a refresh
  of its own (one at a time);
- a 401 "JWT expired" (a phone clock running behind) is refreshed and sent once more (PostgREST refuses before running
  anything, so it's safe to repeat); other refusals are never retried;
- waits are bounded at 10 s, after which the call goes as it was; Auth's own calls (`/auth/v1/`) and Realtime's socket
  pass untouched.

OkHttp allows 5 calls per host by default and every call goes to one host, so the client's dispatcher allows 32 per host
(64 in all): held calls can't keep the refresh itself waiting.

Tests `FreshTokenTest` (expiry, plans, waiting on the session, refresh before the call, retry on "JWT expired", no retry
on other refusals, a failed refresh, Auth calls untouched).

## Not in the event

The 403 in the screenshot (17:57 UTC) was an account opening the event screen of an event it never joined, straight on
resume with no `event_public` call before it: a screen kept from earlier (or a widget, push or old link that bypassed
the link swap). `event_bundle` refuses anyone who doesn't run or play in an event (42501), and the screen showed the
refusal. Now when `event_bundle` refuses a signed-in account (`EventRules.refusedEvent`), the event screen asks
`event_public`; when the event is there and the account isn't in it (`EventRules.opensPage`: access link / invited),
the event page (sign-up, standings and matchups, Follow) replaces the event screen in the back stack; otherwise it reads
"That event isn't available." with Try again. Telemetry `event_opened_as_page` {from: event_screen}.
