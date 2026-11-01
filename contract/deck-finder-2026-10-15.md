# Deck finder (2026-10-15)

New deck → **Find a deck online**: the player describes a deck in plain words ("latest Boros Energy from a big Modern event", "a good Pauper aggro deck"), picks a format, and an agent finds a real, recent tournament list. Built on iOS (`DeckFinderView`, CardLists.swift), web (`screens/DeckFinder.tsx`, `/library/find`) and Android (`library/DeckFinder.kt`, route `collection/find`).

## Server: `deck-finder` edge function

`POST { query, format?, answers?: [{question, answer}] }` with the user's JWT (verify_jwt on). Stateless: a follow-up resends the query plus every question and answer so far.

- Runs Claude (`claude-opus-5-5`, effort medium, server-side `web_search` / `web_fetch`, `fallbacks: "default"`) with a `report_result` tool (strict schema). Sources: mtgdecks.net, melee.gg, mtggoldfish.com, magic.gg MTGO decklists. Ranking: recency first (last 30 days, then 90; never an old list when a recent one of the archetype exists), then strong finishes at large events (Pro Tour, RCs, MagicCon/large opens, MTGO Challenges/Showcases).
- Answers (HTTP 200) one of:
  - `{status: "deck", deck: {name, archetype, format, event, date, placement, player, source_url, notes, main: [{qty, name}], side: [...]}}`
  - `{status: "question", question, options: [2-5 archetypes]}`: ambiguous request; the client shows the options plus a free-text answer and searches again with `answers`.
  - `{status: "not_found" | "error", message}`
- Refusals (4xx) are `{error}`: 401 sign in, 400 empty query, 429 daily allowance (20 searches per account per UTC day, `deck_finder_take` / `t1_private.deck_finder_usage`), 503 when `ANTHROPIC_API_KEY` isn't set.
- The response streams a space every 10 s while the agent works (leading whitespace is valid JSON), then the JSON. The agent is cut off at 140 s. Clients use a long request timeout (Android 170 s).
- Secret: `ANTHROPIC_API_KEY` (Edge Functions → Secrets). Deployed with `verify_jwt` off since 2026-11-01 (the database's job posts carry no JWT); the Bearer path checks the user itself.

## Jobs (2026-11-01)

A search used to be one HTTP request held open from the phone for up to two and a half minutes, which iOS cuts as soon as the phone is locked ("the requests time out when I lock my device"). Now a search is a **job** the server runs on its own:

- `deck_finder_start(p_query, p_format?, p_answers?)` → `{job_id, status: "queued"}` (authenticated). Takes one of the day's 20 searches (raises `P0001` "That's today's 20 searches. Try again tomorrow." when used up; `22023` for a request under 3 characters), cleans the answers like the function did (5 at most, 300 characters each), inserts the job and posts `{job_id}` to the `deck-finder` function through pg_net with the database secret. The same search already queued or running (a second tap, a retried call) is handed back with `again: true` and spends nothing.
- The function claims the job (`deck_finder_claim`, service role: queued → running, so two posts never run it twice), answers 202 at once and works on in the background (`EdgeRuntime.waitUntil`), then ends it with `deck_finder_finish(job_id, result)` (service role): status `done` (or `failed` for `{status: "error"}`), the result stored, and one **`deck.found` push** to the player with the headline only (`job_id`, `status`, `name`, `placement`, `event`, `date`, `question`, `message`; never the list). Alert text: "Deck found · Boros Energy · 1st · Modern Challenge 32 · 2026-10-30. Tap to create it." / "Which deck? · <question> Tap to answer." / "No list found" / "Deck finder · The deck finder couldn't finish that search. Try again." Priority 5, thread `decks`, collapsed per job. The push carries `job_id` and `status`; a tap opens Find a deck on that job (iOS `[.lists(.deck), .findDeck(jobId)]`, Android `collection/decks` → `collection/find?job=<id>`; Android channel Collection).
- `deck_finder_job(p_id?)` → the job (`job_id`, `status` queued | running | done | failed, `query`, `format`, `answers`, `result`, `created_at`, `finished_at`), null when it isn't yours; with no id, your newest job of the last 24 hours.
- Every minute `t1-deck-finder-sweep` (`t1_private.deck_finder_sweep`) posts again a job still queued after 45 s (a refused boot; three tries, then failed), fails a job running over 4 minutes, and forgets jobs older than 7 days. A failed job is finished the same way, so the player hears.
- Clients: **Find deck** calls `deck_finder_start`, then polls `deck_finder_job` every 3 s while the screen is open (the notice says the phone can be locked and a notification will come). Opening Find a deck with no job of its own shows the account's newest job when it is still running or finished in the last hour (`resume` in `testdata/deck-finder/cases.json`), so a search started before the phone was locked is there when the app is reopened; a tapped push opens that job. While the screen is on a job, its push is not shown as a banner (iOS `PushController.watchingDeckJob`, Android `Push.quietDeckJob`). A refused start (allowance, signed out) shows the server's message. Web polls the same way (no pushes on the web). Old builds keep the synchronous call. Telemetry: `deck_finder_used` gains `from` (`table1` | `web`) and `resumed` (`push` | `open` | null).

## Table 1 results (2026-11-01)

Lists from a day or two ago are often not on the web yet, while Table 1's own Insights tables hold every MTGO Challenge, Showcase, Qualifier and League, Melee.gg and TopDeck.gg event within the hour ("I'm having issues finding a list from oct 30"). The agent gets two tools it is told to use first for Standard, Pioneer, Modern, Legacy, Vintage, Pauper and Canadian Highlander (the web stays for Commander, Premodern, and anything the results lack):

- `table1_events {format, days?, archetype?, limit?}` → `deck_finder_events` (service role): recent events of the format, newest first (major tier and bigger fields first within a day), each with up to 16 best-placed decks (`deck_id`, `archetype`, `colors`, `rank`, `wins`/`losses`/`draws`, `top8`); an archetype substring narrows events and decks; `[]` for a format not covered.
- `table1_decklist {deck_id}` → `deck_finder_deck` (service role): the deck exactly as published (`main`/`side` as `{qty, name}` from the oracle names), the event, its date, page and the deck's finish.
- The report tool gains `table1_deck_id`; when it names a Table 1 deck the function copies that deck's exact list, event, date, page and placement (1st / 2nd / … / Top 8 / 5-0) over whatever the model transcribed. The wire deck gains `from: "table1" | "web"`. `player` is empty for Table 1 lists (names are never stored).

## Clients

- Card names resolve against the offline catalog: exact `name_norm`, else the front face of a split/double-faced card. Each card goes in as its original paper printing (catalog contract, `original`). Names that match nothing are listed ("Not in the card data, left out: …"), never dropped silently.
- **Create deck** calls `list_create` with the entries and the note `Found: <placement>, <event>, <date>`, then opens the deck. The deck format follows the found list when it is one of the checked formats.
