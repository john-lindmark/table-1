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
`roto_grid`, `roto_cube`, `roto_picks`, `roto_list` (2026-10-16), `collection_import`, `collection_import_fix` (2026-10-17), `deck_stats`, `cube_stats`, `sample_hand`, `draw_odds`, `sample_pack` (2026-10-17), `binders`, `binder`, `wants`, `want_add` (2026-10-17, binders and wants), `friends`, `friend_add`, `profile`,
`profile_cards`, `sharing`, `trade_matches`, `trade_match` (2026-10-18, friends and sharing), `want_printing`, `binder_add`
(2026-10-18, `library-search-2026-10-18.md`), `item_printing`, `trade_printing` (2026-10-18, `change-printing-2026-10-18.md`), `rankings`, `ranking`, `ranking_screen`,
`ranking_lists`, `ranking_card`, `ranking_compare`, `ranking_pack`, `ranking_changes`, `ranking_image` (2026-10-21,
`cube-rankings-2026-10-21.md`), `insights_constructed`, `insights_limited`, `insights_archetype`, `insights_finish`,
`insights_card`, `insights_ban`, `insights_matchups`, `insights_pair`, `insights_limited_card`, `insights_review`
(2026-10-25, `insights-2026-10-24.md`), `deck_spice`, `discord`, `discord_link` (2026-10-29, `discord-2026-10-29.md`), `cube_spice` (2026-10-28, `spice-2026-10-28.md`: the Stats
screen's Spice section once drawn, or a shared list's Spice screen on iOS).

## Events

### Auth
| event | properties |
|---|---|
| `signed_in` | `method`: apple / google / email |
| `sign_in_failed` | `method`, `reason`: cancelled / error (email sends also already_sent / too_many, contract/email-sign-in-2026-10-15.md § Already sent) |
| `join_prompt_viewed` | `event`: bool. Signed out on a scanned join QR, the Joining header showed (whether it could name the event); contract/qr-sign-up-2026-10-23.md |
| `app_handoff_shown` / `app_handoff_tapped` | `platform`: ios / android. Web player screen, Get the app after joining on a phone (contract/qr-sign-up-2026-10-23.md) |
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
| `event_cube_picked` | `source`: library / recent, `cards`: int (library only). Create event or Setup → Details (2026-10-18) |
| `event_location_set` | `visibility` |
| `players_invited` | `count`, `via`: account / email, `friends`: int (how many were friends; 2026-10-18) |
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
| `deck_finder_used` | `found`: bool, `from`: table1 / web / "" (2026-11-01: where the list came from), `resumed`: push / open / "" (the job was opened from its push, or picked up when the screen opened) |
| `list_imported` | `kind`, `from`: link / paste, `cards`: int |
| `scan_session_ended` | `context`: add / trade / deck / cube / binder / wants (2026-10-19), `cards`: int, `exact`: int (read from set + collector number), `cancelled`: bool |
| `trade_confirmed` | `gives`: int, `gets`: int, `list_conflict`: none / removed / kept, `wants_met`: int (copies), `from_trade_binder`: int (give copies from for-trade binders) |
| `trade_deleted` | `status`: draft / confirmed |
| `catalog_pack_installed` | `seconds`: int, `first`: bool |
| `card_layout_changed` | `layout`: list / grid / stacks, `screen`: all_cards / deck / cube / binder / profile_<section> (2026-10-16; binder 2026-10-19; profile 2026-10-20) |
| `card_grouping_changed` | `grouping`: none / type / color / manaValue, `screen`: as `card_layout_changed` (2026-10-20) |
| `list_exported` | `kind`, `format`, `cards`, `left`, `from`: own / profile, `how`: copy / download (from/how 2026-10-20) |
| `deck_image_shared` | `layout`: grid / stacks, `grouping`, `sideboard`, `cards`, `from`: own / profile, `how`: photos / share (web: download / share / copy) (2026-10-20) |
| `collection_import_previewed` | `format`: manabox / moxfield / archidekt / deckbox / dragonshield / tcgplayer / delverlens / other, `lines`: int, `matched`: int, `unmatched`: int (2026-10-17, `collection-import-2026-10-17.md`) |
| `collection_imported` | `format`, `mode`: add / replace, `cards`: int, `items`: int, `parts`: int (batches), `fixed`: int, `skipped`: int, `binders`: int, `binder_copies`: int, `wants`: int |
| `collection_exported` | `layout`: moxfield / manabox, `cards`: int |
| `sample_hand_used` | `hands`: int, `mulligans`: int, `draws`: int. Once when leaving the sample hand (2026-10-17, lists contract "Stats") |
| `draw_odds_used` | `group`: land / creature / instant / … / card, `turn`: int, `on_play`: bool, `at_least`: int. Once when leaving, if anything was changed |
| `sample_pack_used` | `packs`: int, `size`: int. Once when leaving the sample pack |
| `cube_asfan_changed` | `by`: color / type / mv, `pack`: int |
| `spice_viewed` | `kind`: deck / cube, `format`, `basis`: archetype / closest / format / colors / cubes, or the reason (empty / no_data / no_cubes), `word`: stock / tuned / spicy / brew / none. Once per list per screen open (2026-10-28, `spice-2026-10-28.md`) |
| `spice_card_opened` | `kind`: deck / cube, `section`: main / side / missing |
| `binder_created` | `for_trade`: bool (2026-10-17, `binders-wants-2026-10-17.md`) |
| `binder_updated` | `renamed`: bool, `for_trade`: bool |
| `binder_deleted` | `copies`: int |
| `binder_copies_moved` | `copies`: int, `from`: binder / unsorted, `to`: binder / unsorted |
| `want_added` | `any_printing`: bool, `finish`: bool (one finish picked; 2026-10-18), `has_max`: bool, `from`: search / card / missing |
| `want_changed` | `printing`: true, `any_printing`: bool, `finish`: bool when the want was pointed at another printing (2026-10-18); otherwise — |
| `want_removed` | — |
| `library_searched` | `screen`: cube / deck / wants / binder / binders. Once per visit, when that screen's search is first used; never the text (2026-10-18, `library-search-2026-10-18.md`) |
| `search_list_opened` | `kind`: deck / cube / binder; `whose`: mine / following / shared. A deck, cube or binder opened from Collection Search; never the text or ids (2026-11-02, `library-search-2026-10-18.md` § Collection search) |
| `list_card_removed` | `kind`: deck / cube. Remove in Add, remove or replace |
| `list_card_replaced` | `kind`. Replace swaps one copy for another card in one edit |
| `list_card_added` | `kind`, `from`: edit (picked, then Add) / quick (the + on a hit) (2026-10-19) |
| `ranking_created` | `depth`: half / full, `top`: 50 / 100, `sharing`: cube / private, `own_cube`: bool (2026-10-21, `cube-rankings-2026-10-21.md`), `subject`: cube / set (a Limited set or Arena cube version, 2026-10-30) |
| `ranking_job_done` | `job`: W U B R G M C L F, `screens`: int |
| `ranking_undo` / `ranking_redo` / `ranking_deleted` / `ranking_changes_opened` | — |
| `ranking_pick` | `disagreed`: int (pack cards the ranking put above the pick), `resolution`: none / keep / pick_wins, `removed`: screens taken out |
| `ranking_compared` | `list`: W … L / F |
| `ranking_brief_shown` / `ranking_brief_missing` | `list`, `cached`: bool (a brief, or the reason there isn't one) |
| `ranking_list_copied` | `list` |
| `ranking_rerank` | `list`: where Re-rank started (the cube changed; 2026-10-22) |
| `ranking_caught_up` | — (every new card placed, or removals dismissed) |
| `ranking_image` | `how`: photos / share (web: download / share) |
| `hero_added` / `hero_removed` | `scope`: collection / list / binder, `count`: heroes now in that scope (2026-10-19) |
| `printings_toggled` | `expanded`: bool, `all`: bool (Expand all vs one card), `screen`: all_cards / list / binder (2026-10-19) |
| `advanced_search_used` | `text`, `mv`, `set`: bool, `colors`, `rarity`: counts, `format` (the Advanced form's Search; never the query text) (2026-10-19) |
| `language_changed` | `where`: owned / collection / binder / trade, `copies`: int (2026-10-19) |
| `printing_changed` | `where`: list / collection / binder / trade, `copies`, `finish_only`: bool (2026-10-18, `change-printing-2026-10-18.md`) |
| `friend_request_sent` | `via`: search / played_with / email / profile (2026-10-18, `friends-sharing-2026-10-18.md`) |
| `friend_request_responded` | `accepted`: bool |
| `friend_request_cancelled` | — |
| `friend_removed` | — |
| `user_blocked` | `blocked`: bool |
| `sharing_changed` | `part`: profile / library / all_cards / for_trade / wants / binders / decks / cubes / record / binder / deck / cube, `visibility`: private / friends / public / inherit |
| `profile_viewed` | `relation`: self / friend / requested / incoming / blocked / none, `sections`: int |
| `profile_section_opened` | `section`: all_cards / for_trade / wants / binder / deck / cube |
| `trade_matches_viewed` | `people`: int, `have`: int, `want`: int (copies) |
| `trade_started_from_match` | `gives`: int, `gets`: int (copies) |

### Insights (2026-10-25; contract `insights-2026-10-24.md`)

| Event | Properties |
| --- | --- |
| `insights_section_changed` | `section`: constructed / limited |
| `insights_format_changed` | `format`: standard / pioneer / modern / pauper |
| `insights_tier_changed` | `tier`: big / all |
| `insights_window_changed` | `days`: 7 / 14 / 30 / 90 |
| `insights_set_changed` | `set`, `event` (a Limited set or event picked) |
| `insights_sort_changed` | `sort`: gih / oh / iwd / ata |
| `insights_copy_to_library` | `format`, `archetype` (a finish copied as a deck) |
| `insights_source_opened` | `source`: the credit or event source opened (MTGO, TopDeck.gg, 17Lands) |
| `insights_review_action` | `what`, `action` (moderators: approve / reject / confirm) |
| `insights_matchup_opened` | `format` (a square of the matchup grid tapped for its record) |
| `insights_part_opened` | `format`, `part`: meta / cards / new_set / changes / events (a format page row opened, 2026-10-28) |
| `insights_yours` | `format`, `decks` (yours with an archetype), `close` (archetypes your collection nearly builds): the matchup grid put your decks first (2026-10-30) |
| `deck_insight_shown` | `format`, `archetype`: a deck screen showed its archetype's win rate and matchups (2026-10-30) |
| `deck_insight_opened` | `format`, `archetype`: those rows opened the archetype in Insights |
| `insights_rank_opened` | `set` (FRA, PWR-2510), `kind`: set / cube, `from`: set / new_sets (a set's Rankings opened from Limited, 2026-10-30) |
| `insights_alerts_changed` | `on`: bool (the New in Insights switch, 2026-10-30) |
| `push_opened` | `kind`: insights.new (plus `what`: data / rank on iOS) |

### Discord bot (server-side, from the `discord-bot` function; contract/discord-2026-10-29.md §8)
`platform` is `discord`; `distinct_id` is the Table 1 user id once linked, else `discord:<salted hash>`. Never Discord,
guild, channel, message or event ids, never names (`telemetry.ts` refuses such keys).
| event | properties |
|---|---|
| `discord_interaction` | `kind`: command / button / autocomplete, `command` (e.g. `event create`, `button up`), `linked`, `outcome`: ok / refused / error, `duration_ms` |
| `discord_link_started`, `discord_unlinked` | `via`: link |
| `discord_event_created` | `format`, `scheduled`, `capped`, `top_cut`, `auto_rounds`, `named` |
| `discord_event_attached` | |
| `discord_event_signed_up` | `status`: joined / waitlisted, `via`: button / command |
| `discord_event_left` | `waitlist`, `via` |
| `discord_results_posted` | `final`, `players` |
| `discord_deck_shared` | `format`, `new_link` |
| `discord_part_posted` | `part`: wants / for_trade, `single`, `new_link`, `rows` |
| `discord_card_looked_up` | `found` |
| `discord_meta_posted` | `kind`: matchups / winrates / deck, `format`, `tier`: big / all, `days` (an Insights picture posted, 2026-10-30) |
| `discord_help_viewed` | |
Web: screens `discord`, `discord_link`; `discord_link_completed {via: link}`, `discord_unlinked {via: link}`.

### Push, Live Activities, widgets (iOS; Android/web where they have the surface)
| event | properties |
|---|---|
| `$push_notification_opened` | SDK-captured when a push is tapped. For pushes we send (not PostHog's), it carries no title or body |
| `live_activity_started` | `via`: push (push-to-start from the server) / app (the app's own fallback) |
| `live_activity_ended` | `reason`: ended (match or event over, or signed out) / dismissed (swiped away) |
| `surface_opened` | `source`: widget / live_activity / dynamic_island, `target`: event / home |
| `link_opened` | `to`: event / events / standings / join_code / join_qr / sign_in / tracker / collection / account / web. A tapped table-1.site link reached the app (contract/universal-links-2026-10-22.md); never the address or ids. Android adds `via: install_referrer` when the link came through a Play install (contract/qr-sign-up-2026-10-23.md) |
| `widgets_changed` | `count`: int, `families`: [systemSmall, accessoryCircular, …]. Sent when the installed set changes |

Super properties `live_activities_enabled` (bool) and `widgets` (count) are refreshed at launch and on each foreground.
Widget and Live Activity links carry `?src=<source>` so the app knows what was tapped. The widget extension itself sends nothing.
Android (2026-11-01, `Telemetry.syncSurfaces` on each MainActivity start): `widgets` counts its Glance widgets, `widgets_changed`
`families` are the widget kinds (next_event / value / match, one per installed widget), `live_activities_enabled` is notifications
on with the `live` channel not turned off, and `surface_opened` `source` is widget / widget_next / widget_value / live_activity /
tile / shortcut with `target` the address's host (event / events / home / collection / tracker / scan).
PostHog push subscriptions are on, so the device's push token goes to PostHog (only once the app registers for remote notifications,
when notify-worker ships). That's what PostHog needs to send pushes itself. Turn it off if notify-worker stays the only sender.

### App
`Application Opened`, `Application Backgrounded`, `Application Installed` and `Application Updated` come from the SDK's lifecycle capture.
`analytics_opted_out` is sent once, just before capture stops.
Web (2026-10-22, `web-desktop-2026-10-22.md`): `$pageview` carries `layout`: desktop / mobile; `desktop_nav_used` `{to}`: the sidebar item's key.

## Sentry
- One project per platform (`table-1-ios`, `table-1-android`, `table-1-web`; the bug pipeline maps these slugs). `release` = `site.table1.events@<version>+<build>`, `environment` as above.
- `sendDefaultPii` off. The user is set to `{ id }` only. Query strings are stripped from breadcrumbs and request URLs (PostgREST filters
  carry ids). Failed-request capture covers 5xx only, since 4xx is how RLS and validation reply.
- Traces sampled at 10% in production and 100% in TestFlight. Profiling and session replay are off. App-hang tracking is on (iOS, 2 s); ANR tracking is on (Android, the system's 5 s).
- Non-fatal errors: `Telemetry.error(error, area)` on every platform, tagged `area` (e.g. `sign_in`, `catalog_pack`); cancellations and offline errors are not reported.
- Android: no session replay module, no screenshots or view hierarchy. Release builds tag `environment` from `T1_ENVIRONMENT` in gradle.properties
  (`testflight` while every Play upload goes to internal testing; `production` for production-track bundles), since Play can't tell the app which track installed it.
- Upload dSYMs (iOS) and ProGuard mappings (Android, once release signing exists) on archive.

## Keys
Client keys are public by design, like the Supabase anon key. iOS reads `T1PostHogKey`, `T1PostHogHost` (default `https://us.i.posthog.com`)
and `T1SentryDSN` from Info.plist (set in `project.yml`); empty means telemetry is off. Android reads `BuildConfig` (`T1_SENTRY_DSN`, `T1_POSTHOG_KEY`, `T1_POSTHOG_HOST` in gradle.properties; Debug sends only when built with `-PT1_TELEMETRY=1`), web reads `VITE_POSTHOG_KEY`
and `VITE_SENTRY_DSN`. Web drops GA4 (`gtag`) for PostHog but keeps `redactPath` / `redactSearch` for `$current_url`.

## Rollout
iOS (2026-10-15) → web → Android, per the build order. Android Sentry (crashes, native crashes, ANRs, non-fatal errors, 5xx
from the Supabase client) built 2026-10-19 with the Account opt-out; DSN and the Table 1 Bugs alert rules (shared with iOS and web) set 2026-11-01; not yet run on a device; ProGuard mapping upload waits for release signing. Android DSN set 2026-11-01.
Android PostHog wired 2026-11-01 (posthog-android 3.72.3, same project as iOS/web): lifecycle events, hand-named screens,
push opens and the FCM push subscription on; screen autocapture, deep links (they can carry share tokens and join codes),
element interactions, rage/dead clicks, session replay and surveys off; identified-only person profiles; the Account opt-out
flushes and opts out. Not yet seen in PostHog from a device. Android sends the surface events too (2026-11-01; see § Push, Live Activities, widgets). Server-side capture from `events-engine` is not needed while business numbers come from Postgres.
