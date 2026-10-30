# Android parity with iOS (2026-10-29)

John asked that every iOS feature be built on Android. Found by diffing the server calls each app makes
(`rpc(...)`/`invoke(...)`), the unit-test suites, the screens/routes and the "Android to do" notes in `contract/`.
Library routes, Insights, events, scheduled events, decklists, spice, follows, want prices, rankings, card detail,
trades, imports/exports, deck image, tracker options and push were already at parity.

Fixed first (from John's reports on his Android phone):
- [x] Error flash at launch (cancelled loads shown as errors), same fix as iOS 7ffff3e. 14517fc.
- [x] Scanner laid out like iOS (camera fills the screen, guide with tips, short list, TextureView preview, card gate). 14517fc.
- [x] Limited Insights slow to load (packs one at a time, main-thread decode, chain stopped on leaving the tab). 14517fc.
- [x] Collection home: wrong hero art and binders late for 5-10 s (stores started one after another; iOS too). 9bf8e2c.

Gaps, in build order:
1. [x] **Report** wherever a person appears (`user_report`, contract/friends-sharing-2026-10-18.md § UX rules 6) and the
       other sharing UX rules: Who sees this on decks/cubes/binders (2), widening asks first (4), View as (5),
       Accept · Ignore (7), one-time offers (8), join notice (9), "This isn't available" (10). Built 2026-10-29
       (`PersonActions.kt`, `SharingRules.widening/seesLine/viewAs`, `SharingRulesTest` on testdata/sharing/cases.json).
       The in-app QR scan has no screen of its own on Android (Google's code scanner), so the notice shows on
       Invitations and Nearby only.
2. [x] **Moderation notices and appeal** (Account → From Table 1; contract/moderation-2026-10-18.md), and the moderator
       Review queue (restrict, mode). Built 2026-10-29 (`Moderation.kt`, `ModerationScreens.kt`, routes `notices` /
       `review`, pushes open them; `ModerationTest`).
3. [x] **Seat the ends** switch (`set_seat_ends`, contract/event-night-2026-10-16.md § 3). Android also still drew the
       old round table with a Pack 1/2/3 switch: now the long upright table (`TableLayout`, `TableLayoutTest`).
4. [x] **Redraft pile** for finished set drafts (`redraft_*`, § 6). `ui/screens/Redraft.kt`, `RedraftTest`.
5. [x] **Roto cube events** (contract/roto-2026-10-16.md): setup, draft room, pick lists, clock, undo. Built 2026-10-29
       (`roto/`: RotoModel, RotoStore, RotoScreens; Create format Roto + Pairing, Details cube/picks/order/clock, Pick
       order, Start draft, the Draft gate with Pair round 1, Draft picks and the round robin Schedule over Live;
       `RotoTest` on the iOS/web cases).
6. [x] **Demo data** switch for demo testers (`demo_tester`, `demo_seed`, `demo_remove`). Android also never asked for
       demo data (`p_include_demo` false); it now always asks, since the server shows it to testers only in any build
       (so the store review account sees its sample events).
7. [x] **Unsaved lists** kept and resent (iOS `ListsStore.unsaved`): not needed. Android saves a new list to the server
       before it shows it (`ListsStore.create` → `list_create`), so it can't strand a phone-only list as iOS did.
8. [x] **Quick actions and widgets** (John, 2026-10-29: "build the same functionality for the widgets and live
       activities in iOS into the similar technology for Android"): Life tracker / Scan cards shortcuts and Quick Settings tiles, Next event and
       Collection value widgets (Glance), live event status (iOS Live Activities → an ongoing notification).
       Built 2026-10-29 (contract/widgets-2026-10-22.md § Android): live notification for players and organizers (Live
       Update on Android 16), Glance Next event / Collection value / Current match, Quick Settings tiles and launcher
       shortcuts. Server half (live-activity FCM, dispatch guard migration) live 2026-10-30 with John's OK.
9. [x] **Bug inbox** for watchers (Account → Bugs, `bugs_*`). `library/Bugs.kt`, routes `bugs` / `bug/{id}`, ops pushes open them; `BugsTest`.
10. [x] **Insights picks follow the account** (John, 2026-10-29: "Settings for insights format views should be maintained
       across platforms"): hidden formats/sets and the picked section, format, tier, window, set, event and group now
       live in `user_settings.insights` (migration `20261030050000_insights_picks.sql`), read and written by all three
       clients (3e2571d). Migration live and web deployed 2026-10-30; iOS/Android with their next builds.
