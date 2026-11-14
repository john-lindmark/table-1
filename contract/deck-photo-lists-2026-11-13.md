# Decklists from deck photos (2026-11-13)

John: "start processing the deck photos and develop decklists from the photographs. It should make it easier that we
know the format of each event so we can narrow down the potential cardpool lists. use the posted images as references
for testing. add the ability to correct the list and add the list to your decks in collection." Then, while it was
being built: "avoid the cards that are sideways as they are not likely in the deck" and "users will use dice to
represent how many basic lands were used".

Every deck photo (contract/event-night-2026-10-16.md § 7) gets a decklist, kept beside the photo. Whoever sees the
photo sees the list; whoever may edit it corrects it; anyone who sees it can add it to their own decks.

## Reading

- **When.** Adding a photo queues a read (not in demo events). A photo from before this existed is read when
  someone who sees it taps **Read decklist**. The photo's player, whoever took it and the organizer can have it
  **read again**; a photo is read at most five times.
- **How.** A server job (`deck-photo-read` edge function, one request to `claude-opus-5-5` per photo, the photo as
  stored at 2048 px, a structured answer). It is a job like the deck finder's: `queued → reading → done | failed`,
  steps on the row ("Looking at the photo", "Reading against Reality Fracture: 285 cards", "Read 40 cards: 2 to
  check"), a sweep every minute that re-sends an unclaimed read (three tries) and fails one running over four
  minutes. A phone never waits on the read: it polls `deck_photo_list` every 3 s while the status is queued or reading.
- **The pool.** The event narrows what the cards can be (`t1_private.deck_photo_pool`):
  - a set event (`events.set_code`): the set's cards, one English printing each;
  - a cube event (`events.cube_name`): a cube of that name owned by the event's creator, an organizer or a player
    (the creator's first, then the fullest), main board;
  - anything else (constructed, an event that recorded neither): no pool, every title is read as printed.
  The pool is a hint, never a filter: packs hold cards filed under other sets (Mystery Booster 2's reprints are The
  List's), and a cube changes between the event and the read. A whole title outside the pool is kept as read.
- **What the reader is told** (`read.ts` `SYSTEM`): name every card in English with the pool's spelling; a title bar
  is a copy; **a die on a pile of basic lands is that land's count**; a squared pile without a die is counted by its
  edges, marked unsure; **cards lying sideways to the rest, strays off the mat or cut off at the edge, and another
  player's cards are `out`** (in the photo, not in the deck); `side` only for a clearly separate upright sideboard;
  no tokens, dice, sleeves or face-down cards; never a card it can't see; with a known deck size (40 limited, 60
  constructed, 100 Commander and Canadian Highlander) doubtful basic-land piles lean to the size.
- **Names to cards** (`read.ts` `entries`): the pool's exact name (a split card by either the whole name or its first
  half) → the pool's printing; else a whole title the catalog knows (`deck_photo_read_names`: the card's usual
  printing) → kept as read; else the one pool card clearly closest (trigram Dice ≥ 0.72, 0.08 clear of the next) or
  the catalog's closest (trigram ≥ 0.6) → that card, **to check**, with what was read; else a line with no card,
  to check. The same card on the same board is one line.
- **An entry**: `{card_id | null, name, qty, board: main | side | out, sure, read?}`. To check = no card, or
  `sure: false`. `out` lines are shown for correcting and never counted, saved to a deck, or pushed.
- **The push**: `deck.read` to the photo's player, once per photo, when a read first yields cards: "Your decklist is
  ready" / "40 cards read from your deck photo from Friday draft, 2 to check. Tap to correct it and add it to your
  decks." (notify-worker `deck-read.ts`; info `photo_id`; not for guests, demo events or hidden photos; muted like
  any kind). A tap opens the photo's decklist (iOS `PushRoutes`, Android `PushRoutes.link`; older builds open the event).

## Server

Migration `20261113150000_deck_photo_lists.sql`; table `t1_private.deck_photo_lists` (one row per photo: status,
steps, `read` = what the reader made of it and never edited, `entries` = the list as it stands, who corrected it,
reads, push stamp; goes with the photo).

| RPC | Who | What |
|---|---|---|
| `deck_photo_list(p_photo_id)` | anyone who sees the photo | `{photo_id, event_id, participant_id, player, path, turns, note, status (none, queued, reading, done, failed), steps, entries, message, notes, pool {kind, label, size}, checked, editable, mine, reads_left, finished_at, event {name, format, event_type, format_label}}`; P0002 for a photo you can't see |
| `deck_photo_read_start(p_photo_id)` | no list or a failed one: anyone who sees it; again: editors | queues a read; the list while one is under way; 42501 again by a non-editor; P0001 after five reads; 22023 demo |
| `deck_photo_list_save(p_photo_id, p_entries)` | the player, whoever took it, the organizer | replaces the list (≤ 250 lines, qty 1–99, names from the catalog for known cards), marks it checked, audited `deck_photo.list_saved` with the counts |
| `deck_photos`, `my_deck_photos` | as before | each photo gains `list: {status, cards, check, checked}` (absent when never queued) |
| `deck_photo_read_claim / _peek / _progress / _finish / _names` | service role | the function's side |

A done read replaces the list and clears "checked" (a read asked again starts over); a failed read keeps the list
there was and says why in `message`. Corrections never touch `read`, so read vs corrected list is the record of how
well the reader did (`score` in `read.ts`).

Adding to your decks needs no new call: `list_create` (kind deck) with the entries.

## Clients

**Photo rows.** Under each photo (event Deck photos and Account → Deck photos) one row, by `row(list)`:
"Read decklist" (no list), "Reading the decklist…", "Decklist · couldn't read · try again", "Decklist · no cards
read", "Decklist · 40 cards", "… · 3 to check", "… · checked". A tap opens the decklist (asking for the read first
when there is none or it failed).

**The decklist screen** (iOS `Route.deckPhotoList(photoId)` / `LibraryRoute.deckPhotoList`, web
`/photo/<id>/list`, Android `photolist/<id>`), the thing itself first:
- the photo, whole and upright, a tap zooms (the photo is what you correct against);
- the size line large: `sizeLine(main, target)` "40 cards", "38 cards · 2 short of 40", "101 cards · 1 over 100",
  the pool under it as data ("Reality Fracture · 285 cards" or the reader's note);
- while reading: the steps, then the list replaces them;
- **Main deck**, **Sideboard** (when it has lines), **Left out · N** (sideways and stray cards; collapsed) sections;
  a line is the count, the name, and for a line to check a second line in muted with what was read ("pile of about
  7, no die") and the tag CHECK;
- editors: − count + on every line; a tap on a line opens Change card (a search of every card), Looks right (a line to check with a card), Move to main deck / sideboard / left
  out, Remove; **Add a card** at the end of the list; changes save 0.8 s after the last one
  (`deck_photo_list_save`), "Saved" in the bar; a **Read the photo again** row under the list while reads are left,
  asking first ("Reading again replaces this list.");
- everyone: the bottom bar's one action **ADD TO MY DECKS** → `list_create` a private deck named `deckName` (the
  event's name; "<player> · <event>" for someone else's), format `deckFormat` (the event's constructed format, else
  Other), entries `deckEntries` (main and sideboard lines with a card; lines without a card are left out and
  counted: "2 lines without a card were left out"), then **Open deck**. Someone who can't edit still gets the count
  steppers and Change card locally: their changes go into their deck, not the photo's list.

**Rules** (reference `testdata/deck-photo-lists/make_cases.py` → `cases.json`; iOS `DeckPhotoList` in
`DeckPhotoListTests`, web `deckPhotoList.ts` in `deckPhotoList.test.ts`, Android `DeckPhotoList` in
`DeckPhotoListTest`): `row`, `target`, `counts`, `sizeLine`, the edits (`setQty` 0 removes, 99 at most; `move`,
`replace`, `add` merge the same card on a board and keep main, side, out order; `confirm`), `deckEntries`,
`deckName` (60 characters), `deckFormat`.

**Telemetry**: screen `deck_photo_list`; `deck_list_opened` {status, mine, editable}, `deck_list_read_asked`
{again}, `deck_list_edited` {op}, `deck_list_saved` {lines, cards, check}, `deck_list_to_deck` {cards, skipped,
mine, checked}.

## Testing with the posted photos

The 24 deck photos posted up to 2026-11-13 (five events: Reality Fracture and Mystery Booster 2 drafts, a draft that
recorded no set, two Lindmark Cube team drafts) are the reference set. The photos stay in the private bucket and out
of the repository; `tools/deck-photo-lists/fetch.sh` pulls them into a scratch folder with the Supabase CLI.
`testdata/deck-photo-lists/` holds what is safe to keep: the three pools by card name (`pools.json`), what a reader
reported for each photo (`reads/<photo>.json`: a first pass by Claude given each photo and its pool, before the dice
and sideways rules, not yet checked by a person), and the out-of-pool names the live catalog knows (`catalog.json`).
On that pass 694 of 697 lines named a real card, 17 of 24 photos came to exactly 40 cards in the main deck and the
rest to 32–41 (cut off at the frame, squared piles, a photo taken from across the table); the function's tests run
the matching rules over all of it. Measuring the deployed reader: POST `{"eval": [photo ids]}` to `deck-photo-read`
with the database secret (as `moderate`'s eval) answers with the lists and writes nothing;
`tools/deck-photo-lists/score.py` compares them with the reference reads. Once players correct their lists, read vs
corrected is the better measure.

## Not yet

A list across several photos of one deck; picking the event's pool by hand when the event recorded no set; the
decklist on Discord's results post; sideboard guides from a photo.

## Where it stands (2026-11-13)

Built on branch `deck-photo-lists`; nothing is live. The migration is not applied and `deck-photo-read` and
notify-worker are not deployed, so no photo has been read by the deployed reader yet: its first real measure is the
eval over the 24 posted photos once it is up.

- Server: `63d_deck_photo_lists_test.sql` (48 checks), Deno `deck-photo-read/read.test.ts` (the matching rules over
  all 24 photos' reads), `notify-worker/deck-read.test.ts`.
- iOS: `UI/DeckPhotoList.swift`, `DeckPhotoListTests`; the screen seen in the Simulator on a made-up read
  (`-T1EventsDemo account -T1Open decklist`), not tapped there.
- Web: `lib/deckPhotoList.ts`, `screens/DeckPhotoList.tsx` (its own lazy chunk), `deckPhotoList.test.ts`; route
  `/photo/<id>/list` (not claimed by the apps: the link stays in the browser); clicked through at phone width on
  `/me/deck-photos?demo` (the row, a count, the line menu, Add to my decks → Open deck).
- Android: `ui/screens/DeckPhotoList.kt`, `DeckPhotoListScreen.kt`, `DeckPhotoListTest`; route `photolist/<id>`;
  compiled and unit-tested, not run on a device. Its line menu has no second line for what was read (the row shows it).
- Going live, in order: apply the migration; deploy `deck-photo-read` (`--no-verify-jwt`) and notify-worker; run the
  eval on the 24 photos and read the score; then queue reads for the photos already posted (they have no list row
  until someone taps Read decklist, or `select t1_private.deck_photo_read_queue(id, null)` per photo); then the web
  deploy and the next phone builds.
