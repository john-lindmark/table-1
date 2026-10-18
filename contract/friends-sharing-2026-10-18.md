# Friends, profiles, sharing and trade matches: client contract (2026-10-18)

Server: migration `20261018150000_friends_sharing.sql`. Tests: `supabase/tests/80_friends_sharing_test.sql`; budget
in `perf_10_library.sql` (`trade_matches`). Builds on `contract/binders-wants-2026-10-17.md` (binders, for trade,
wants), `contract/trades-2026-10-16.md` (`trade_save`) and `contract/create-event-2026-10-14.md` (Add players).

## Decisions (John's request, 2026-10-18)

- **Friends are mutual.** One asks, the other accepts. Either can unfriend at any time; both lose the friend view.
- **Declining is quiet.** The asker keeps seeing "Requested" (no "declined" to see); a declined request just sits
  until the asker cancels it. If the person who declined later asks the asker, they become friends.
- **Block** (optional, built): removes the friendship and any request, stops requests from that account, and hides
  everything about you from them (even what's public). They aren't told.
- **Everything starts private.** The Library and every part of it is private until the owner shares it. The profile
  itself (name, avatar, and only what's shared) opens for friends by default.
- **Public means any signed-in Table 1 account.** There is no signed-out web view yet (a follow-up).
- **Profile caps everything.** A part shows to someone only if both the profile and that part reach them: a public
  deck on a friends-only profile shows to friends only.
- **"Trades" means "For trade":** the cards in your for-trade binders, as one list. Confirmed trade history stays
  private (it names partners).
- **Your max price is never shown** to anyone else; it only flags matches "over your max" for you.
- **Matches look at** your friends and the people you've shared an event with in the last 90 days, for whatever
  each has made visible to you (for those you've only played with, that means public). Nobody else's Library is
  scanned. Demo accounts, deleted accounts and blocks (either way) never match.
- **Finding people:** by email (existing accounts only, the same answer whether one exists or not), from people
  you've played with, or by name or handle among public profiles (2+ characters). Nobody can browse all accounts.

## Visibility

Values: `private` · `friends` · `public`; `null` = "Same as …" (the level above). Levels:

```
Profile              friends (default)       who can open your profile at all
Library              private (default)       the default for every part below
├── All cards        null → Library          your whole collection (counts + every printing you own)
├── For trade        null → Library          copies in your for-trade binders, as one list (what matching reads)
├── Wants            null → Library          your wishlist, without max prices
├── Binders          null → Library          default for each binder
│   └── each binder  null → Binders
├── Decks            null → Library          default for each deck
│   └── each deck    null → Decks
└── Cubes            null → Library          default for each cube
    └── each cube    null → Cubes
Record               private (default)       lifetime match record (wins / losses / draws, events)
```

Someone sees a part when they're you, or it's `friends` and they're your friend, or it's `public`, and the profile
reaches them too. Blocked either way = nothing. A for-trade binder's copies count as visible "for trade" when either
For trade or that binder reaches the viewer.

## RPCs (authenticated; anon is refused)

Errors are readable messages. Wrong account / not visible / doesn't exist all read the same: "That's private"
(42501), so nothing tells a stranger what exists. Every write is audited in `account_audit`.

### Friends

| Call | Does |
|---|---|
| `friend_request(p_user_id)` | Asks them. If they already asked you, you're friends now. Already friends / already asked = same answer. Returns `{status: 'requested' \| 'friends'}`. Refused: yourself, a deleted or demo account (P0002 "That account isn't on Table 1"), more than 30 requests an hour (53400), more than 1000 friends. If they blocked you it answers `requested` and writes nothing. |
| `friend_request_by_email(p_email)` | Same, by email. Always `{ok: true}`, whether or not the address has an account. 20 lookups an hour. |
| `friend_respond(p_user_id, p_accept)` | Accept → `{status: 'friends'}`; decline → `{status: 'declined'}`. No request from them: P0002 "That request is gone". Accepting again is the same answer. |
| `friend_remove(p_user_id)` | Cancels your request or unfriends. Returns `{removed: bool}` (false = nothing to remove). |
| `user_block(p_user_id, p_blocked)` | Blocks (removing the friendship and requests both ways) or unblocks. Returns `{blocked}`. |
| `friends_list()` | `{friends: [Person + since], incoming: [Person + at], outgoing: [Person + at], blocked: [Person]}`, friends by name, requests newest first. Declined requests show in `outgoing` for the asker only. |
| `friend_search(p_query?, p_limit=30)` | Empty query: people you've played with, most shared events first. A query (2+ characters) narrows those and adds public profiles whose name or handle starts a word with it. Rows: Person + `shared_events`, `relation`. You and blocked accounts are left out. |

Person: `{user_id, display_name, handle, avatar_url}`. `relation`: `self` · `friend` · `requested` (you asked) ·
`incoming` (they asked) · `none`.

Push (`notify-worker`): `friend.request` to the person asked ("<name> wants to be friends"), `friend.accepted` to the
asker. Not sent for an email lookup that found nothing, a blocked asker or demo accounts.

### Sharing (yours)

| Call | Does |
|---|---|
| `sharing_get()` | `{profile, library, all_cards, for_trade, wants, binders, decks, cubes, record, items: [{kind: 'binder' \| 'deck' \| 'cube', id, name, for_trade (binders), visibility}]}`. |
| `sharing_set(p_settings)` | `p_settings`: any of the keys above (`profile`, `library`, `record` take a value; the rest also take `null`), plus `items: [{kind, id, visibility}]` (up to 500). A wrong value or key: 22023. An item that isn't yours: 42501. Same values = no change (no audit row). Returns `sharing_get()`. |

### Seeing someone

| Call | Does |
|---|---|
| `profile_view(p_user_id)` | `{user_id, display_name, handle, avatar_url, relation, friends_since, visible, sections}`. `visible` false = only the name and avatar (the profile doesn't reach you). `sections` has only what reaches you: `all_cards: {cards, printings, value_usd}`, `for_trade: {cards}`, `wants: {cards}`, `binders: [{id, name, for_trade, cards}]`, `decks` / `cubes: [{id, name, format, cards}]`, `record: {match_wins, match_losses, match_draws, events_played}`. Works on yourself (relation `self`, everything). A deleted account: P0002. |
| `profile_cards(p_user_id, p_section, p_id?, p_after=0, p_limit=5000)` | The cards behind one section, paged by offset: `{rows, more}`. `all_cards`: `[card_id, finish, qty]`. `for_trade` and `binder` (`p_id`): `[card_id, finish, condition, lang, qty]`. `deck` / `cube` (`p_id`): `[card_id, board, qty]`. `wants`: `[oracle_id, card_id, finish, qty]`. Not visible: 42501. Names, images and prices come from the catalog pack and `card_prices_get`. |

### Trade matches

`trade_matches(p_user_id?)` → `{people: [Match], generated_at}`. Without `p_user_id`: everyone in the matching scope
(above) with at least one match, most matched copies first, at most 50 people. With it: that one person (any account
whose For trade or Wants reach you, e.g. a public profile).

```
Match: {user_id, display_name, handle, avatar_url, friend,
        they_have: [{card_id, finish, condition, lang, qty, want: {oracle_id, card_id, finish}, usd, over_max}],
        they_want: [{card_id, finish, condition, lang, binder_id, qty, want: {oracle_id, card_id, finish}, usd}],
        have_copies, want_copies, have_usd, want_usd}
```

- **They have** = your wants (qty > 0) against their visible for-trade copies. **They want** = their visible wants
  against your for-trade copies (`binder_id` = your binder the copies are in).
- **Order** (the same as `BinderRules.wantFor` / `trade_confirm`): a want for that printing and finish takes copies
  first, then a want for that printing in any finish, then a want for any printing. A copy is used once per person;
  a want is met at most up to its qty. Among copies for one want: NM first, then the cheaper printing, then English.
- `usd` is the market price of one copy in that finish (null = none). `over_max` (they have only): your want has a
  max and the price is above it. Lines over your max still show, after the others.
- At most 200 lines a side per person.

`trade_match_start(p_user_id, p_idempotency_key?)` makes a trade draft from the current match with that person:
gives = they want (from your for-trade binders), gets = they have; `partner` = their display name and the new
`partner_id`. The same key returns the same draft (`duplicate: true`). Nothing to trade: 22023. The 50-draft limit
applies. Returns the trade (`trade_save`'s shape plus `partner_id`); open it in the trade editor.

`trades` rows gain `partner_id` (nullable): set only by `trade_match_start`. `trade_save` leaves it as it is.

## Add players (Create event → Add players, Setup → Add players)

`suggested_players` rows gain `friend` (bool) and list **friends first** (by name, `shared_events` may be 0), then the
people you've played with, as before; the search filters both. Clients show a "Friends" section above "Played with
you" and one tap selects a friend, as for any suggestion. `players_invited` gains `friends` (how many of the invited
were friends).

## Clients

- **Account tab:** a **Friends** row (friends · requests waiting) and a **Sharing** row (what your profile shows,
  e.g. "Friends · 3 parts shared"), and "View your profile".
- **Friends screen:** Requests (Accept / Decline), Friends (tap → profile), Sent (Cancel), Add a friend (search with
  the played-with suggestions, email), Blocked at the end (Unblock). Unfriend and Block are in a friend's profile menu
  (native confirm alert).
- **Profile screen:** avatar, name, handle, relation action (Add friend / Requested · Cancel / Accept · Decline /
  Friends), Record, then each shared section (All cards, For trade, Wants, Binders, Decks, Cubes) → a read-only card
  list (decks and cubes by board; tap → that card's detail, i.e. your own copies of it). "Trade matches with <name>" when there are any → their match.
  "Nothing shared yet" when nothing reaches you.
- **Sharing screen (Account → Sharing):** the tree above, each with a Table 1 segmented control (Private / Friends /
  Public, plus "Same as …" for children); per-binder, -deck and -cube rows one level deeper; a note when the profile
  caps a part. Changes save on tap.
- **Library home:** a **Trade matches** row (people · copies) above Trades. Trade matches screen: one block per
  person (avatar, name, "Has 3 · wants 2", value), tap → their match: They have, then They want (card rows with the
  printing and which want it meets), "Over your max" flags, **Start a trade** → `trade_match_start` → the trade editor
  (gives from your for-trade binders, gets marked "Want").
- **Telemetry** (no names, ids or search text): `friend_request_sent` (`via`: search / played_with / email / profile),
  `friend_request_responded` (`accepted`), `friend_request_cancelled`, `friend_removed`, `user_blocked` (`blocked`:
  bool), `sharing_changed` (`part`: profile / library / all_cards / for_trade / wants / binders / decks / cubes /
  record / binder / deck / cube, `visibility`: private / friends / public / inherit), `profile_viewed` (`relation`,
  `sections`: int), `profile_section_opened` (`section`), `trade_matches_viewed` (`people`, `have`, `want`: copies),
  `trade_started_from_match` (`gives`, `gets`: copies). `players_invited` gains `friends`. Screens: `friends`,
  `friend_add`, `profile`, `profile_cards`, `sharing`, `trade_matches`, `trade_match`.
- **Demo:** iOS Debug `-T1LibraryDemo friends|profile|sharing|matches|match` (two demo friends with trade binders and
  wants that match the fixture's, one public player from an event); web dev `/friends?demo`, `/library/matches?demo`,
  `/sharing?demo`, `/u/d0000000-0000-0000-0000-0000000f0001?demo`. Both demos match with `TradeMatcher` / `matchLines`
  (the server's rules on the device). Android has no Library demo.
- **Routes:** web `/friends`, `/friends/add`, `/sharing`, `/u/:id`, `/u/:id/:section[/:itemId]`, `/library/matches`,
  `/library/match/:id` (ids redacted from telemetry URLs). Android `friends`, `friends/add`, `sharing`, `profile/{id}`,
  `profile/{id}/{section}/{item}`, `collection/matches`, `collection/match/{id}`. iOS `LibraryRoute.social(…)`, pushed
  from the Collection tab or the Account tab (which now has its own navigation path).
- **Push taps:** `friend.request` / `friend.accepted` open Account → Friends (iOS).
- **Where it lives:** iOS `Library/Friends.swift` (store, rules), `Library/FriendsViews.swift`, `Library/FriendsDemo.swift`;
  web `lib/friends.ts`, `lib/friendsDemo.ts`, `screens/Friends.tsx`; Android `library/Friends.kt`, `library/FriendsScreens.kt`.
  Shared matcher cases: `testdata/trade-matches/cases.json`. Client tests: iOS `FriendsTests`,
  web `friends.test.ts`, Android `FriendsTest`.

## Account deletion

`delete_account` removes your friendships, requests, blocks (both ways), sharing settings and audit rows, and clears
`partner_id` on other people's trades with you.
