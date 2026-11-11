# After the first real draft (2026-10-16)

Fixes and additions from the 15 Oct draft (8 players, 3 rounds). Server is live; iOS is built. Web and Android
still to do. Wire names are in `rpc.schema.json`.

## 1. Organizer who plays can open the life tracker
- Live phase, Round tab: when the organizer is seated in the active round, a **Your match · Table N** block sits
  under the clock: `vs <opponent>`, then **Open life tracker** (accent) and **Set result**.
- Home **Life** button opens the synced tracker for the match you're playing now (live snapshot), local only
  when you aren't playing.
- Guest-vs-guest matches: the organizer's phone keeps score. `tracker_state.keeper` is true and `my_side` is 0;
  `tracker_push` / `tracker_record_game` accept the organizer; report the result with `set_match_result`
  (reason "Life tracker"). The result panel's button reads **Life tracker** (was "Watch life tracker").
- Telemetry: `life_tracker_opened` gains `source`: `home_life` / `organizer_match` / `event`.

## 2. Life tracker taps
- A tap counts on touch-down. If the touch then moves more than 10 pt (a swipe), the change is taken back:
  dropped if it hasn't been sent, otherwise cancelled by an inverse op stamped like it (nets to 0, hidden in
  history). Hold repeats after 0.4 s, then every 0.1 s. Pressed fill shows at once (no fade).

## 3. Draft seating drawn like a real table
- One long table, upright: seats run clockwise from the right side's top, down the right, up the left.
- **Seat the ends** (organizer switch on the Seating tab; `set_seat_ends`, stored as `events.seat_ends`): seat 1
  at the head, then the right side, the foot, the left side. Needs 4+ players. Drawing only.
- No Pack 1/2/3 switch: the middle of the table reads "↻ 1·3 left" and "↺ 2 right".
- Telemetry: `seat_ends_changed` {on, players}.

## 4. Push notifications
- Apps register their token at sign-in and on launch when allowed: `register_device(p_platform, p_push_token,
  p_app_version, p_env)`; `unregister_device` on sign-out. iOS asks permission right after sign-in.
- Server: `notify-worker` sends within seconds of an enqueue (minute sweep as backup). Alerts older than 30
  minutes are dropped. New: **event.new** goes to the organizer's regulars (played in one of their events in the
  last 90 days) a minute after an event is created, unless it's private or demo. Mute per kind with
  `notification_prefs.muted_kinds`.
- Tapping an alert opens its `event_id`. Telemetry: `push_permission` {granted}, `push_opened` {kind}.
- Android (2026-10-29): FCM through Firebase project `table-1-53243` (`apps/android/app/google-services.json`; the worker's
  service account key is the `FCM_SERVICE_ACCOUNT` secret). The app registers with `p_platform` android whenever someone is
  signed in (and on FCM's token rotation), and unregisters before sign-out; it never asks for permission outside the
  permissions step. The worker sends **data-only** v1 messages (`fcm.ts`; HIGH for priority 10, NORMAL for 5, TTL 1 h):
  `title`, `body`, `tag` (the APNs collapse id: a newer alert replaces the older one), `group` (the APNs thread-id) and
  the same routing keys as the APNs payload (nulls left out, values as strings). The app draws each one in a channel
  (Events, high importance: event./round./result.; Collection: follow./trade./want./ranking.; Friends; From Table 1:
  the rest) and a tap opens the same screen as on iOS (`PushRoutes.kt`; no Notices/Review/Bugs screens on Android, so
  moderation and ops pushes open Account). Tokens FCM answers UNREGISTERED (404) or SENDER_ID_MISMATCH are deleted;
  other failures are logged, never deleted. A platform without credentials is skipped and counted (`skipped`).

## 5. Game and match times
- `matches.result_at` (first result, never moves), `tracker_games.started_at` (previous game's end, or the round
  start/tracker open for game 1) and `tracker_games.first_change_at`. View `t1_private.match_times` per account
  and match, for a future pace-of-play Insights screen. Nothing for clients yet.

## 6. Redraft (set drafts, after the event)
- Event screen, finished set draft (not cube): **After the event → Redraft**. Anyone in the event scans cards
  (the Add cards scanner); the pile lists most valuable first with rank, set/number, finish, who added it and
  the market price; the bar shows count and total. Tap a card to remove it.
- `redraft_list`, `redraft_add` (≤200 per call), `redraft_remove`. Telemetry: `redraft_cards_added`
  {cards, exact}, `redraft_card_removed`. Screen `redraft`.

## 7. Deck photos
- During the event: player screen **Deck photo** button; organizer **More → Deck photos**. After: **After the
  event → Deck photos** for everyone.
- Add: organizer picks whose deck; then camera or photo library; then a note. JPEG, longest side 2048 px,
  quality 0.8, uploaded to `deck-photos/<event_id>/<photo_id>.jpg`, then `deck_photo_add`.
- Each player sees their own until the event ends; the organizer sees all; then everyone in the event sees all
  (`deck_photos.shared`). The player or whoever took it can edit the note or remove the photo.
- Telemetry: `deck_photo_added` {source, own, has_note, event_over}, `deck_photo_note_saved` {has_note},
  `deck_photo_removed`. Screen `deck_photos`.
- Web and Android (2026-10-23): until now only iOS had this screen, so players on the web (most of the 23 Oct team
  draft) had no way to add a photo; the server always allowed it (`supabase/tests/63_deck_photos_test.sql`). Web:
  `/e/<id>/photos` (organizer bar → Deck photos) and `/p/<id>/photos` (player screen **Deck photo** / after the event
  **Deck photos**, signed-in players only); camera or library through the file picker, scaled in a canvas. Android:
  organizer **More → Deck photos** (Results phase too), player screen button; camera through the FileProvider or the
  photo picker. Both scale to 2048 px JPEG 0.8 (`deckPhotoSize`, tested on both).
- After the event and orientation (2026-10-29): the 29 Oct team draft's photos all went in during the event and none
  after, because iOS's Results screen had no More menu (where Live kept **Deck photos**) and the "After the event" row
  read like viewing only. Results now has **More → Add a deck photo** (plus Redraft, Draft picks, Share link) and the
  row reads "Deck photos · Add yours · see everyone's · ADD". Adding after the event was always allowed (pinned in
  `63_deck_photos_test.sql`).
- **Rotate before saving**: the add panel shows the whole photo (fitted, 260 pt/dp/px tall, not cropped) with
  **↺ Rotate left | Rotate right ↻**; the file is drawn turned (quarter turns clockwise, 0–3) before the 2048 px JPEG is
  made, so it goes up upright. The preview is drawn small (900 px) per tap.
- **Rotate after upload**: the photo's menu (player or whoever took it, like the note) has Rotate right / Rotate left.
  The file is never rewritten (only its uploader may overwrite it, and a new file would skip moderation): the row keeps
  `turns` (0–3, `deck_photo_turn(p_id, p_turns)`, audited as `deck_photo.turned` only when it changes; `deck_photos`
  rows carry `turns`; migration `20261030060000_deck_photo_turns.sql`, applied to live 2026-10-30). Clients draw the photo turned, fitted into the
  4:3 box's swapped sides for odd turns, and show a tap at once (kept until the server answers). Photos in the list are
  shown whole (fit) rather than cropped. Older servers send no `turns`: read as 0.
- Rule (cases `testdata/deck-photos/cases.json`, tests `DeckPhotoTests` / `deckPhotos.test.ts` / `DeckPhotosTest`):
  turn = (turns + by) mod 4; the uploaded size is the 2048 px size with the sides swapped for odd turns.
- Telemetry: `deck_photo_added` gains `turns`; `deck_photo_turned` {turns}.
- Demo: iOS `-T1EventsDemo results|photo`, web `/dev/events` → Photos.
- **On your account** (2026-11-06; John: "Users should be able to see their past deck photos from their
  account/profile view"): until now a photo could only be found inside its event. Account → **Deck photos** (row under
  the lifetime record, "12 photos · 5 events" or "None yet") opens every photo of a deck you played, whoever took it,
  across events: headed by event ("TEAM DRAFT · 29 OCT 2026", the format added only when the name doesn't already say
  it), newest event first, each photo whole and turned. A photo's menu: **Open event**, **Everyone's photos from this
  event** (only once it's over, since before that you'd see only your own), then Rotate, note and Remove as on the
  event's screen. Server: `my_deck_photos(p_limit default 200, max 500)` → `{total, events, photos}`, each photo the
  `deck_photos` row plus `event_id`, `event_name`, `event_status`, `format_label`, `event_at` (starts_at, else
  created_at); `total`/`events` count everything, so the row asks for one photo. Visibility as `deck_photo_visible`
  for the player (a photo moderation hid shows only to whoever took it), demo events only for demo testers, signed out
  28000, anon no execute; migration `20261106170000_my_deck_photos.sql` (+ index on `participant_id`), tests
  `63b_my_deck_photos_test.sql`, budget in `perf_20_event_reads.sql` (600 of 10,500 photos, ~3–5 ms). Rules shared via
  `testdata/deck-photos/cases.json` `summary` / `groups` (iOS `MyDeckPhotoRules` in `MyDeckPhotoTests`, web
  `myDeckPhoto*` in `deckPhotos.test.ts`, Android `MyDeckPhotoRules` in `DeckPhotosTest`). Routes: iOS
  `LibraryRoute.myDeckPhotos` / `.eventDeckPhotos(id)` on the Account stack (Open event switches to Events), web
  `/me/deck-photos`, Android `mydeckphotos`. Not shared on your public profile (photos stay with the people in their
  event). Telemetry: screen `my_deck_photos`, `my_deck_photo_opened` {to: event | event_photos}; `deck_photo_turned`,
  `deck_photo_note_saved` and `deck_photo_removed` gain `from` (event | account). Demo: iOS `-T1EventsDemo account
  [-T1Open deckphotos]`, web `/me/deck-photos?demo`.
- **Long press** (2026-11-11; John: "if I access photos from the organizer view in events, long press doesn't do
  anything"): every deck photo, on the event's Deck photos screen (organizer and players) and on Account → Deck photos,
  answers a long press with **Copy**, **Save to Photos** and **Share**, like the Deck image (contract/deck-image-2026-10-20.md
  § Long press). What's handed over is the photo upright as shown (its saved turns drawn in, at most 2048 px on the long
  side); the stored file is never rewritten. A tap still opens the photo's own menu (Rotate, note, Remove) for whoever
  may edit it. iOS: the system context menu once the photo has loaded (`DeckPhotoCard` loads it itself now, not with
  AsyncImage), Copy/Save answered in place of Edit for 3 s, VoiceOver actions; Save uses `MadeImageActions.save`
  (add-only Photos access). Android: the photo is read again on the long press, then the `MadeImageMenu` (Copy as a
  FileProvider image, Save to Pictures/Table 1, Share). Web: the browser's own image menu; the picture is no longer
  inside a button, and a turned photo is drawn upright into a blob URL so Copy and Save get what's on screen. Shared
  files are named "Deck photo - <player>.jpg" (`DeckPhotoTurns.fileName` / `deckPhotoFileName`). Telemetry
  `image_menu` {screen: deck_photo, how}.

- **Once your last match is in** (2026-11-11; John: "once a user's final match for the event has been recorded, make it
  easier for users to upload their deck picture, right now I think it's kinda tough for people to find"): until now a
  player found deck photos as a small **Deck photo** button under the life tracker switch, or a row under After the
  event. Now, once a signed-in player is done playing, their event screen opens on a block at the very top: a label
  (**Last match in** / **Event over** / **Dropped**) over the screen's one big action, **Add a deck photo**, which opens
  Deck photos with Take a photo / Choose from photos already up for your own deck (organizers who play still pick from
  More). Once you have a photo of your deck in the event the block is a row, **Deck photo · Added** (or "Added · 2
  photos") → View, and the old button is gone while done (after the event the Deck photos button stays for everyone's).
  Done means (`DeckPhotoPrompt.done` iOS/Android, `deckPhotoDone` web; reference `testdata/deck-photos/make_prompt.py` →
  `prompt.json`): not cancelled; the event completed or archived (`over`); or you dropped (`dropped`); or your latest
  match has its result in (a bye, reported by either side, or confirmed) and it was your last: a playoff match you lost
  or the final, the last Swiss round (number ≥ the event's rounds) with no top cut, or the last Swiss round once the
  playoffs have started without you (`last`). With a top cut, players who may make it see nothing until the cut is paired.
  Your photo count is `deck_photos` filtered to your seat, read once you're done (again on coming back); a failed read
  shows Add. No server change. Telemetry `deck_photo_prompt_shown` {why} (once, with no photo yet),
  `deck_photo_prompt_tapped` {why}; `deck_photo_added` gains `from` (prompt | screen). Routes: iOS `Route.addDeckPhoto(id)`,
  web `/p/<id>/photos?add=1` (the menu opens on arrival; its tap is the gesture the file input needs), Android
  `photos/<id>?add=true`. Demo: iOS `-T1EventsDemo playerdone`.

## Web (2026-10-30)

§ 3 and § 6 on the web: the long upright table with the organizer's **Seat the ends** switch on Setup → Seating
(`TableLayout` in `lib/tableLayout.ts`, tested like Android's `TableLayoutTest`), and the redraft pile at
`/e/<id>/redraft` / `/p/<id>/redraft` (organizer header and the player's After the event buttons), where cards are added
by search since the web has no scanner (the drafted set's English printing when the card is in it; Foil switch).
