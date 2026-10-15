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
- Secret: `ANTHROPIC_API_KEY` (Edge Functions → Secrets).

## Clients

- Card names resolve against the offline catalog: exact `name_norm`, else the front face of a split/double-faced card. Each card goes in as its original paper printing (catalog contract, `original`). Names that match nothing are listed ("Not in the card data, left out: …"), never dropped silently.
- **Create deck** calls `list_create` with the entries and the note `Found: <placement>, <event>, <date>`, then opens the deck. The deck format follows the found list when it is one of the checked formats.
