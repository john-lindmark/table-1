# Telemetry: event plan (2026-10-15)

**PostHog** is for product analytics: events, funnels, retention, screens. **Sentry** is for crashes, hangs, non-fatal
errors and performance. Both run on iOS, Android and web. This file is the source of truth for event names and
properties. Every client sends the same names, so one PostHog insight covers all three platforms.

## What answers what
- **Business numbers come from Postgres, not PostHog.** Events run, matches played, cards tracked and trades confirmed
  are already in the database. Count them there; the server is the authority. PostHog answers *behaviour*: how people
  get to those outcomes, where they drop off, and which features they use.
- Questions this plan is built to answer:
  1. Activation: sign in → join or create a first event → report a first result.
  2. Organizer funnel: create → add players → seat/pair round 1 → record final round (and where people give up).
  3. Player flow: how people join (QR / link / nearby / invite), whether they report in the tracker or in results,
     and how often results are disputed.
  4. Library adoption: who opens Collection, adds cards (manual / scan / import), builds decks and cubes, and trades.
  5. Scanning quality: cards per session, exact vs. name-only matches, sessions cancelled with nothing added.
  6. Retention by role: weekly players vs. organizers.

## Identity and privacy (must hold on every platform)
- `distinct_id` is the Supabase user id (UUID): call `identify(user_id)` on sign-in and `reset()` on sign-out and account deletion.
  Before sign-in the SDK's anonymous id is used, and `identify` merges it.
- **No personal data in any property or person profile:** no email, display name, guest names, partner names, event names,
  list names, notes, search text or free-text reasons. Person properties are only `platform` and `first_seen_app_version`.
- **No credentials or identifying ids:** no join codes, QR secrets or tokens, and no event, match, round, participant, list or trade ids
  (the same rule as web's `redactPath`). Use counts, enums and booleans.
- No IDFA/AAID, so no App Tracking Transparency prompt. No session replay. No autocapture of taps or text (rage clicks off too: they
  record the tapped element's text). Screens are named by hand.
- **Opt-out:** Account → "Share usage and crash data" (on by default). Off stops PostHog capture and Sentry sending on that device.
- **Environments:** each event carries `environment`, which is `debug`, `testflight` or `production` (web: `dev` or `production`).
  Debug/dev builds send nothing unless launched with `-T1Telemetry` (iOS) or `VITE_TELEMETRY=1` (web). Insights filter to `production`.
- Account deletion (follow-up, server): `delete-account` also deletes the PostHog person (personal API key secret). Sentry keeps
  events for 90 days with only the user id.
- App Store privacy label: Usage Data (Product Interaction) and Diagnostics (Crash, Performance), linked to the user and not
  used for tracking. Play Store Data safety: the same.

## Conventions
- Names are `object_action`, snake_case, past tense (`event_created`). Properties are snake_case.
- Super properties on every event: `platform` (`ios`/`android`/`web`), `app_version`, `build`, `environment`.
  PostHog adds the OS and device.
- Fire after the server accepts the change, never optimistically. Failures go to Sentry, not PostHog.
- Screens: `$screen` with `$screen_name` from the list below. Never put ids in screen names. Tab roots count when shown, not when built.
- Not tracked on purpose: event-detail autosaves (every edit saves), trade draft autosaves, life-tracker taps.

## Screens
`sign_in`, `events_home`, `event`, `create_event`, `nearby`, `scan_qr`, `add_players`, `life_tracker`,
`library_home`, `all_cards`, `card_detail`, `add_cards`, `card_scanner`, `decks`, `cubes`, `deck`, `cube`,
`list_versions`, `list_add`, `list_printing`, `deck_finder`, `list_import`, `trades`, `trade`, `account`,
`roto_grid`, `roto_cube`, `roto_picks`, `roto_list` (2026-10-16), `collection_import`, `collection_import_fix` (2026-10-17), `deck_stats`, `cube_stats`, `sample_hand`, `draw_odds`, `sample_pack` (2026-10-17).

## Events

### Auth
| event | properties |
|---|---|
| `signed_in` | `method`: apple / google / email |
| `sign_in_failed` | `method`, `reason`: cancelled / error |
| `signed_out` | `reason`: user / apple_revoked |
| `account_deleted` | — |

### Play: players
| event | properties |
|---|---|
| `event_joined` | `via`: qr / link / nearby |
| `invite_responded` | `accepted`: bool |
| `match_reported` | `status` (server: recorded / confirmed / disputed …), `games`: int, `draws`: int |
| `result_responded` | `accepted`: bool (false = disputed) |
| `life_tracker_opened` | `mode`: match / local |
| `tracker_game_recorded` | `draw`: bool, `game_no`: int |
| `tracker_mode_changed` | `mode`: tracker / elsewhere |
| `nearby_alerts_changed` | `enabled`: bool |

### Play: organizers
| event | properties |
|---|---|
| `event_created` | `format`, `kind`: constructed / limited / cube, `rounds`, `round_timer`: bool, `team_size`: int or 0, `organizer_plays`: bool, `guests`: int, `pairing`: swiss / round_robin |
| `event_location_set` | `visibility` |
| `players_invited` | `count`, `via`: account / email |
| `guest_added` | — |
| `player_removed` | — |
| `teams_set` | `teams`: int, `random`: bool |
| `seating_drawn` | `pods`: int |
| `round_paired` | `round`: int, `pairing`: swiss / round_robin |
| `round_clock_changed` | `action`: pause / resume / add |
| `result_overridden` | — |
| `player_dropped` | `status`: dropped / active |
| `round_recorded` | `final`: bool |
| `event_cancelled` | — |

### Play: roto (2026-10-16; contract `roto-2026-10-16.md`)
| event | properties |
|---|---|
| `roto_cube_set` | `pool`: int, `from`: library / cube_cobra |
| `roto_started` | `players`: int, `picks_per_player`: int, `pool`: int, `order`: snake / fixed, `clock`: bool, `clock_ranges`: int |
| `roto_picked` | `how`: player / organizer, `from`: cube / grid / list / detail, `round`: int, `seconds_on_clock`: int, `auto_followed`: int (auto-picks the server ran after it) |
| `roto_list_changed` | `cards`: int, `auto_pick`: bool. Once per accepted save, not per drag |
| `roto_clock_changed` | `action`: set / clear / pause / resume, `ranges`: int |
| `roto_pick_undone` | `picks_removed`: int |
| `roto_deck_opened` | `from`: event / picks / library |

Timeouts and auto-picks happen on the server; count them in Postgres (`roto_picks.how`), not PostHog.

### Library
| event | properties |
|---|---|
| `collection_changed` | `source`: manual / scan / import / trade, `ops`: int, `copies`: int (net) |
| `collection_undone` | — |
| `list_created` | `kind`: deck / cube, `format`, `from`: new / duplicate / import / finder |
| `list_deleted` | `kind` |
| `list_version_restored` | `kind` |
| `deck_finder_used` | `found`: bool |
| `list_imported` | `kind`, `from`: link / paste, `cards`: int |
| `scan_session_ended` | `context`: add / trade, `cards`: int, `exact`: int (read from set + collector number), `cancelled`: bool |
| `trade_confirmed` | `gives`: int, `gets`: int, `list_conflict`: none / removed / kept |
| `trade_deleted` | `status`: draft / confirmed |
| `catalog_pack_installed` | `seconds`: int, `first`: bool |
| `card_layout_changed` | `layout`: list / grid / stacks, `screen`: all_cards / deck / cube (2026-10-16) |
| `collection_import_previewed` | `format`: manabox / moxfield / archidekt / deckbox / dragonshield / tcgplayer / delverlens / other, `lines`: int, `matched`: int, `unmatched`: int (2026-10-17, `collection-import-2026-10-17.md`) |
| `collection_imported` | `format`, `mode`: add / replace, `cards`: int, `items`: int, `parts`: int (batches), `fixed`: int, `skipped`: int |
| `collection_exported` | `layout`: moxfield / manabox, `cards`: int |
| `sample_hand_used` | `hands`: int, `mulligans`: int, `draws`: int. Once when leaving the sample hand (2026-10-17, lists contract "Stats") |
| `draw_odds_used` | `group`: land / creature / instant / … / card, `turn`: int, `on_play`: bool, `at_least`: int. Once when leaving, if anything was changed |
| `sample_pack_used` | `packs`: int, `size`: int. Once when leaving the sample pack |
| `cube_asfan_changed` | `by`: color / type / mv, `pack`: int |

### Push, Live Activities, widgets (iOS; Android/web where they have the surface)
| event | properties |
|---|---|
| `$push_notification_opened` | SDK-captured when a push is tapped. For pushes we send (not PostHog's), it carries no title or body |
| `live_activity_started` | `via`: push (push-to-start from the server) / app (the app's own fallback) |
| `live_activity_ended` | `reason`: ended (match or event over, or signed out) / dismissed (swiped away) |
| `surface_opened` | `source`: widget / live_activity / dynamic_island, `target`: event / home |
| `widgets_changed` | `count`: int, `families`: [systemSmall, accessoryCircular, …]. Sent when the installed set changes |

Super properties `live_activities_enabled` (bool) and `widgets` (count) are refreshed at launch and on each foreground.
Widget and Live Activity links carry `?src=<source>` so the app knows what was tapped. The widget extension itself sends nothing.
PostHog push subscriptions are on, so the device's push token goes to PostHog (only once the app registers for remote notifications,
when notify-worker ships). That's what PostHog needs to send pushes itself. Turn it off if notify-worker stays the only sender.

### App
`Application Opened`, `Application Backgrounded`, `Application Installed` and `Application Updated` come from the SDK's lifecycle capture.
`analytics_opted_out` is sent once, just before capture stops.

## Sentry
- One project per platform (`table1-ios`, `table1-android`, `table1-web`). `release` = `site.table1.events@<version>+<build>`, `environment` as above.
- `sendDefaultPii` off. The user is set to `{ id }` only. Query strings are stripped from breadcrumbs and request URLs (PostgREST filters
  carry ids). Failed-request capture covers 5xx only, since 4xx is how RLS and validation reply.
- Traces sampled at 10% in production and 100% in TestFlight. Profiling and session replay are off. App-hang tracking is on (iOS, 2 s).
- Upload dSYMs (iOS) and ProGuard mappings (Android, once release signing exists) on archive.

## Keys
Client keys are public by design, like the Supabase anon key. iOS reads `T1PostHogKey`, `T1PostHogHost` (default `https://us.i.posthog.com`)
and `T1SentryDSN` from Info.plist (set in `project.yml`); empty means telemetry is off. Android reads `BuildConfig`, web reads `VITE_POSTHOG_KEY`
and `VITE_SENTRY_DSN`. Web drops GA4 (`gtag`) for PostHog but keeps `redactPath` / `redactSearch` for `$current_url`.

## Rollout
iOS (2026-10-15) → web → Android, per the build order. Server-side capture from `events-engine` is not needed while business numbers come from Postgres.
