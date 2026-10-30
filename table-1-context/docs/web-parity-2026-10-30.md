# Web parity with the apps (2026-10-30)

John: "let's make sure all new functionality is in every platform" (before shipping iOS build 39 and Android
29889809). Found by diffing the server calls each client makes, the shared test cases each client reads, and the
"web to do" notes in `contract/`. iOS and Android already called every function the other did (apart from the
platform's own Live Activity / FCM tokens), and today's features (Sync with Cube Cobra, every archetype, Limited set
rankings, New in Insights) were on all three. The web was behind; built here:

- [x] **Sharing UX rules** (contract/friends-sharing-2026-10-18.md § UX rules): "Anyone" not "Public"; Who sees this
      atop every deck, cube and binder; widening asks first (Show / Cancel) on Sharing and Who sees this; View as
      (You · A friend · Anyone) on your profile; who-sees lines atop Sharing; Report and Block wherever a person
      appears (profile More, friend / request / sent rows, Add a friend results, trade-match rows and screen; long press
      or right-click); Accept · Ignore with events together; once-only offers (For trade on marking a binder, Trade
      matches, record on Account); the join notice on invitations, the join page and the QR guest join; "This isn't
      available" / "Nothing shared yet". Rules tested on `testdata/sharing/cases.json` (`friends.test.ts`).
- [x] **Moderation**: Account → From Table 1 with one appeal per change; Review for moderators.
- [x] **Seat the ends** and the long upright table (`lib/tableLayout.ts`, `tableLayout.test.ts`); players see the organizer's choice.
- [x] **Redraft pile** for finished set drafts (search instead of the scanner).
- [x] **Nearby**: open events within 150 m (`/nearby`, from the Events home), Create's Who can find it (Nearby + QR /
      QR only) with the venue pin for unscheduled events, Details' Who can find it (Nearby / Link only / Private).
- [x] **Demo data for testers**: the web asks for demo data like the apps (the server shows it to testers only), and
      Account has the testers-only Load / reset and Remove demo.

Not on the web, on purpose: pushes and everything they open first (the bug inbox stays an app screen for watchers),
the camera scanner, widgets, Live Activities and live notifications, the permissions step.
Not on the apps, on purpose: the Discord link page (`/discord`, `/discord/link`) stays in the browser.
