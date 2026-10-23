# Share, and "Anyone with the link" (2026-10-23)

Every part of the Library can be shared: All cards, For trade, Wants, each binder, deck and cube. Server: migration
`20261023120000_share_links.sql`; tests `supabase/tests/89_share_links_test.sql`; budgets in `perf_10_library.sql`.
Builds on `contract/friends-sharing-2026-10-18.md` (settings, the profile cap, UX rules) and
`contract/universal-links-2026-10-22.md`.

## Decisions (John, 2026-10-23)

- **Settings stay the rule.** Private / Friends / Anyone decide who sees a part on Table 1, capped by the profile.
  Share never widens anything without asking (UX rule 4's confirm, unchanged).
- **A link is one more audience, per part.** "Anyone with the link" is something the owner turns on for one part.
  Whoever holds the link sees that part and nothing else, **even signed out and even past the profile cap**. The
  part's own setting doesn't change. It's shown wherever "Who sees this" is, and it can be turned off at any time.
- **One live link per part.** Make link returns the live one if there is one. **New link** retires the old one
  (anyone holding it loses it). **Stop sharing link** retires it at once. Deleting the part or the account ends it.
- **Blocks still win** for a signed-in viewer (either way). Signed out, a link can't know who's holding it, and the
  confirm says nothing else on your profile shows.
- **Never shown through a link:** the owner's id or handle, total value, max prices. The owner's name and photo are
  shown ("Shared by Ana Lind").
- **Moderation:** a binder, deck or cube with a live link counts as seen by others: its name is checked when the
  link is made and on every rename. While moderation has unshared that name (enforce mode), its link shows "This
  isn't available"; a rename or a reverted action opens it again.

## RPCs

| Call | Who | Does |
|---|---|---|
| `share_link_create(p_part, p_id?, p_new=false)` | signed in | `{part, id, token, created_at}`. `p_part`: `all_cards` / `for_trade` / `wants` (no id) or `binder` / `deck` / `cube` (with id). Returns the live link, or makes one; `p_new` retires the live one first. Not yours: 42501; bad part/id: 22023; 50 new links a day: 53400. Audited (`sharing.link`). |
| `share_link_revoke(p_part, p_id?)` | signed in | `{ok, revoked}`. Nothing live = `revoked: false`, no audit row. |
| `sharing_get()` | signed in | Adds `links: [{part, id, token, created_at}]` (live links whose part still exists). |
| `shared_view(p_token)` | anyone | `{part, id?, name?, format? (deck/cube), for_trade? (binder), cards, owner: {display_name, avatar_url?}, mine}`. `cards`: copies (a deck's leave out Considering). `name` only for binders, decks and cubes. Closed / unknown / blocked / deleted: "This isn't available" (42501). |
| `shared_cards(p_token, p_after=0, p_limit=5000)` | anyone | `{rows, more}` in `profile_cards`' shapes for that part (for_trade = every for-trade binder). |

The address is `https://table-1.site/l/<token>` (token: 22 url-safe characters).

## Clients

### Share (your own parts)
A **Share** row (detail "Link, or who sees it on Table 1") on All cards, Wants, the Binders screen (for For trade),
each binder, deck and cube opens the **Share** screen (a pushed screen / full panel):

1. **Anyone with the link**
   - No link: **Make a link** ("Anyone with it sees <what>, even without an account"). Tap → confirm
     "Make a link to <name>?" / "Anyone with the link sees <what>, even without a Table 1 account. Nothing else on your
     profile shows. You can stop sharing it any time." (+ All cards: "Your total value is never shown." Wants: "Your max
     prices are never shown.") / **Make link**. Then the link shows.
   - A link: the address (mono, muted), **Share link** (share sheet; web: navigator.share, else copy), **Copy link**,
     **New link** (confirm "Make a new link? The old link stops working for anyone who has it." / New link), **Stop
     sharing link** (confirm "Stop sharing the link? It stops working for anyone who has it. Who sees this on Table 1
     doesn't change." / Stop sharing).
2. **On Table 1**: Who sees this (the existing control; for All cards / For trade / Wants it's that part's setting
   with the same menu and confirm). When it reaches someone: **Send profile link** sharing
   `https://table-1.site/u/<you>/<part>[/<id>]`, with "Only <friends / anyone on Table 1> can open it."
3. **As a copy** (decks and cubes): Export, and Deck image for decks (the existing screens).

"Who sees this" rows read "<value> · Link on" in their detail while a link is live, and Account → Sharing marks
items with a live link ("Link on").

`<what>` is the existing effect line: "every card you own", "the copies in your for-trade binders", "your wishlist",
"every card in this binder, with condition and language", "every card in this deck/cube".

### Opening a link
`/l/<token>` on every client:
- **Web**, signed in or out: header name (binder/deck/cube name, else "All cards" / "For trade" / "Wants"),
  "Shared by <owner>" with their avatar, then the cards exactly like a profile section (search, View, Group by). Decks
  and cubes: Export and (decks) Deck image; signed in and not yours, Copy to my Library too. Signed out, a last row:
  "Make your own on Table 1" → sign in. Closed: "This isn't available" / "The link may have been turned off."
- **Apps** (universal link `/l/*`): signed in → the same screen on the Collection tab; signed out → the web page
  (like standings: no account needed).

### Platform notes
- iOS: Share is a pushed screen (`SocialRoute.share`), `/l/` opens `SocialRoute.sharedLink` on the Collection tab. Debug
  demo: `-T1LibraryDemo share|shareall|shareon|sharedlink|badlink`.
- Web: Share opens over the screen (`screens/Share.tsx`); `/l/:token` is a route for everyone. Who sees this links to
  Account → Sharing (the per-item control isn't on web yet). Dev demo: `/l/demoMaraPublicDeckLink?demo`.
- Android: Share opens over the screen (`library/ShareScreens.kt`); `/l/` → `collection/shared/{token}`. Who sees this
  is read-only there; change it in Account → Sharing.
- Cases every client reads: `testdata/share-links/cases.json` (iOS `ShareLinksTests`, web `shareLinks.test.ts`,
  Android `ShareLinksTest`); `/l/` in `testdata/universal-links/cases.json`.

### Rollout
Apply the migration first (clients without it show "This isn't available" on links and no link rows). Then deploy the
web (it serves the AASA with `/l/*`), then ship the iOS build; builds without `/l/` open the app's home screen for a
tapped link.

### Telemetry
`share_opened {part, from: all_cards | wants | binders | binder | deck | cube}`, `share_link_created {part, new}`,
`share_link_stopped {part}`, `share_link_sent {part, how: share | copy}`, `share_profile_link_sent {part}`,
`shared_link_opened {part, signed_in, mine}`. Never tokens or ids. Web redacts `/l/<token>` to `/l/:id` (screen `shared_link`).
