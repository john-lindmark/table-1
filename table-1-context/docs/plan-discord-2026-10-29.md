# Plan: Table 1 for Discord (2026-10-29)

**Status 2026-10-29: built as proposed; not yet live.** Contract `contract/discord-2026-10-29.md`, migration
`20261029130000_discord.sql`, edge function `discord-bot`, web pages `/discord` and `/discord/link`. Going live needs
the Discord application (SETUP.md § Discord), the migration, the function and its secrets, and the web deploy.

John asked (2026-10-29): a Discord bot where people create events, sign up and drop before the start, see an event's
parameters and who's in, sign in with Discord, post an event's results with a link to it on Table 1; think about how
collection content fits; follow Discord, privacy and security best practice; make it fast; telemetry on everything;
a `/help` command and a page on the site that describe everything it does.

## 1. Shape

**One backend, no new server.** The bot is a Supabase edge function that Discord calls over HTTP (the *interactions
endpoint*), not a long-lived gateway process. Nothing runs between interactions, there is no message-content access,
and every request from Discord is signed (Ed25519) and checked before anything else happens. Slash commands, buttons
and autocomplete all arrive the same way and get an answer within Discord's 3 seconds.

**The bot acts as the person's Table 1 account.** A Discord user links their Table 1 account once (`/link`, or by
signing in to Table 1 with Discord). From then on the bot's database calls run *as that account*: the same
`create_event_v2`, `event_sign_up`, `event_leave`, `share_link_create` and `list_spice` the apps call, with the same
checks, rate limits and audit rows. The bot adds no second set of rules.

**Events stay Table 1 events.** A `/event create` makes a real event (the organizer is seated, rounds auto by default)
and posts a card in the channel with Sign up / Drop / Open in Table 1. The card is the event's single source of truth
in Discord: every sign-up or drop edits it in place. `/event post <link>` attaches an event made in the app. Once
the event is over, `/event results` posts the final standings with the link to the standings page.

## 2. What it does (commands)

| Command | Who | Does |
|---|---|---|
| `/help` | anyone | Every command in one ephemeral message, with the link to table-1.site/discord. |
| `/link` | anyone | Links your Discord account to your Table 1 account: an ephemeral one-time link to table-1.site (10 min). Signed in with Discord on Table 1? Already linked. |
| `/unlink` | linked | Removes the link (a Discord sign-in identity can't be unlinked; that's your sign-in). |
| `/event create` | linked | Format (constructed formats, Draft, Sealed), optional name, when (`YYYY-MM-DD HH:MM` + timezone), venue, cap, top 8, rounds (auto when omitted), set code or cube name. Posts the event card in the channel. |
| `/event post <event>` | organizers and players | Posts the card for an event made in the app: pick it from your open events (run or played in; no past events) or paste its link. A player may post an event they're in unless it's private. |
| `/event list` | anyone | Open events of this server (ephemeral). |
| `/event show <event>` | anyone | The card again (ephemeral) with the buttons; autocomplete over the server's open events. |
| `/event signup <event>` / `/event drop <event>` | linked | Same as the buttons. |
| `/event results <event>` | linked | Final standings as a public post with Open in Table 1. Before the event ends, organizers only ("Standings so far"). |
| `/settings timezone <zone>` | server members with Manage Server | The zone `/event create` reads times in. |
| `/deck <deck>` | linked | Posts one of your decks (autocomplete over your decks): name, format, counts, Spice, the whole deck as a picture, and a link anyone can open. Asks first if that link doesn't exist yet. |
| `/wants [card]` / `/trades [card]` | linked | Posts your wants / your cards for trade, the whole list or one card, with prices and a link anyone can open (asked first when there's no link). |
| `/card <name>` | anyone | A card: cost, type, cheapest TCGplayer price, image, Scryfall link. |

Buttons on the event card: **Sign up**, **Drop**, **Open in Table 1** (link). On an unlinked click the bot answers
with how to `/link`.

## 3. Collection content, thought through

The Library is private by default and every public surface on Table 1 goes through one sharing rule set
(profile cap, per-item visibility, share links). Discord is a *public channel*, so anything the bot posts from the
Library has to be something the owner chose to share, by the same rules:

1. **Built now: `/deck`.** A deck post is a share link (`share_link_create('deck')`), the same "Anyone with the link"
   the apps make, revocable from Sharing. No live link → the bot asks before making one. The post carries name,
   format, card counts, Spice and the hero card. Nothing else about the Library leaves.
2. **Built now: `/card`.** Catalog lookup with the price: no personal data at all.
   **Built the same day (John): the deck post carries the whole deck as a picture**, drawn on the server by the
   `deck-image` function from the share link, and **`/wants` and `/trades`** post your wants or your cards for trade,
   the whole list or one card, behind the part's share link, with a link to Table 1. `/event post` picks from the
   events you run or play in as well as taking a link.
3. **Next: decklists for events.** An event that takes decklists (`decklists` optional/required) gets
   `/event decklist <event> <deck>`: the bot exports your deck as text and calls `decklist_submit`, so a required
   decklist can be met from Discord. Needs a server-side export of a deck to text (today the clients export).
4. **Next: results with decks.** On the results post, a player who submitted a decklist and opted in gets a
   "Deck" link (a share link to the deck). Opt-in per event, never default.
5. **Later: trade matches in a server.** "Who here has what I want": `trade_matches_for` extended to linked members
   of a server who share For trade with Anyone. The same for Wants. Needs a guild-membership notion server-side
   (the bot would have to tell the server who is in the guild, which is a privacy trade-off to think about: today the
   server knows nothing about who is in which Discord server).
6. **Later: event decks, Insights.** `/meta <format>` from the Insights packs (public data) is cheap and useful; a
   deck's archetype on the `/deck` post too.

## 4. Privacy and security

- **Signed requests only.** Ed25519 over `timestamp + body` with the app's public key; timestamps older than
  5 minutes are refused (replay). Discord's PING gets PONG. The function is deployed with `verify_jwt` off, since the
  signature is the credential; the bot token is a function secret and never leaves the function.
- **Least privilege on Discord.** Install scopes `bot` + `applications.commands`; permissions Send Messages and Embed
  Links only. No message content intent, no gateway, no reading of anyone's messages.
- **Minimal data about Discord.** The server keeps a Discord *user id* ↔ Table 1 account map (one each way), the
  guild and channel ids of posted event cards (to edit them), and a timezone per server. All in `t1_private`, never
  readable by clients. No Discord usernames, avatars or guild names are stored. Account deletion removes the link
  (FK cascade).
- **Link flow.** `/link` makes a one-time token (24 random bytes, sha256 at rest, 10 minutes, one per Discord user)
  delivered in the URL fragment so it never reaches a server log; the page confirms it as the signed-in account.
  A Discord account linked to another Table 1 account is refused. Linking is also implicit for people who sign in to
  Table 1 with Discord (Supabase's Discord provider: the identity's provider id *is* the Discord user id).
- **Ephemeral by default.** Everything the bot says to one person is ephemeral. The only public posts are the ones a
  person explicitly asks for: the event card, the results post, a deck post.
- **Guild binding.** Sign up / drop / results only work on events posted in that server; the card and autocomplete
  only ever list that server's events.
- **Rate limits.** Per Discord user before linking (`t1_private.discord_rate`), the account's own limits after.
- **Moderation unchanged.** Event names typed in Discord go through the same `events_moderation` trigger.
- **Telemetry without identities.** Discord ids never reach PostHog: the distinct id is the Table 1 user id once
  linked (as on the clients), else a salted hash of the Discord id. No guild, channel, event or message ids.

## 5. Performance

- Stateless HTTP; nothing to keep warm but the function instance. The public key import is cached per instance.
- **One database round trip per interaction**: each bot RPC resolves the account, acts, and returns the finished
  card in one transaction. Discord REST calls (editing the card, storing the posted message id) run after the
  response in `EdgeRuntime.waitUntil`.
- Button clicks answer with UPDATE_MESSAGE (the edited card) and a follow-up ephemeral note; no second fetch.
- Autocomplete is one indexed query (`discord_events (guild_id)` → open events).
- Budgets: `perf_40_discord.sql` keeps the card under 20 ms at 64 players and sign-up under 30 ms locally.

## 6. Out of scope now
Pushes from Table 1 back into Discord when an event changes in the app (a pg_net trigger editing the card: the ids
are stored for it); reminders before a scheduled start; decklists, trade matches and Insights (§3); Android/iOS
"Sign in with Discord" buttons (web first); per-guild default format/venue.
