# Event links open in the app (2026-11-09)

John: "had a user open an event like they were not in and it opened as a websheet, it should open as native." Clients
only (iOS, Android), no server change. Cases: `testdata/event-links/cases.json` (`results`, `title`, `round_title`,
`score`); tests iOS `EventLinksTests`, Android `EventLinksTest`, web `eventFollows.test.ts`.

## Before
`/s/<id>` (the share and sign-up link) opened the event for its organizers and players and the in-app sign-up page
before round 1; anyone else after round 1, or once sign-ups closed, got the web standings page in an in-app Safari
view (iOS) or the browser (Android). `/e/<id>`, `/p/<id>` and event pushes opened the event screen even for someone
not in it, which it can't load.

## Rule
- **Signed in, `/s/<id>`:** organizers and players → the event screen, as before. Everyone else → the in-app **event
  page** (`EventPageView` / `EventPageScreen`), always. A private or unknown event says "That event isn't available"
  there. Signed out, standings still open on the web (they need no account); a sign-up link still signs in first.
- **`/e/<id>`, `/p/<id>`, and a tapped push carrying an event:** the event screen opens as before; if `event_public`
  says the viewer isn't its organizer, player or guest, the event page replaces it (`swapForEventPage` on iOS, the
  `WebLink.Screens` branch in Android's AppRoot). Offline (no answer) leaves the event screen.
- **The event page after round 1** (`showsResults`: `sign_up = closed`, except someone still waitlisted before round 1)
  draws what the web's `/s` page does: the bar's subtitle "Final standings" / "Round 2 of 4" / "Quarterfinals"
  (`resultsTitle`), "Sign-ups are closed: you didn't get in this time." for someone who waited, **Standings | Matchups**:
  Standings = events-engine `standings` (top 8 bracket first, teams, pods with their filter, the tiebreaker note);
  Matchups = `event_public.rounds` newest first ("Round 2 · now", "Semifinals"), rows `T3 · Ana 2–1 Bo` / `Bye · Ana`
  (an older server's `round` + `pairings` stand in for the current round). It reloads every 20 s while open; pull to
  refresh. An organizer or player who lands on it (from Following, say) gets **Open event**.
- `event_public` fields the apps now decode: `current_round`, `round {number, stage}`, `rounds`, `pairings`.
- Telemetry: `event_page_viewed` gains `state: results`.
