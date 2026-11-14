# Plan: public events, leagues, leaderboards, entry fees, TV display (2026-11-13)

John, 2026-11-13: "Let's start to put together public events and associated leagues and leaderboards. Use MMS as an
example of a league. We will need to support team events, probably need team captains(?). Consider notifications for
new events and league status updates. Let's consider how people could pay via the app when signing up and how payouts
work to the participants. Some payout stays with the host sometimes. Need the ability to add descriptions to the
events and leagues. There should be a general leaderboard for each format. Build a widget for upcoming events that can
be edited to include only the formats you want. Need tools for the organizer similar to EventLink like timer and
standings that can be cast to TVs/displays."

Status: decisions 1–5 below are John's picks (2026-11-13). Phase 1 is being built; phases 2–4 are proposed and wait
for his OK. Nothing here is live.

## What MMS is (the example league)

The Mountain Magic Series (themountainmagicseries.com, read 2026-11-13): a 12-month season around Denver, one Open a
month hosted in turn by four stores, formats rotating (Modern, Standard, Legacy, Pauper, Duel Commander, Booster
Draft, Team Sealed, Team Trios with a different format per seat), then an invite-only Players Championship.

- Points by final place at each Open: 1st an invite to the Championship, 2nd 10, top 4 8, top 8 6, top 16 3, anyone
  else 1. Season standings are the total. Ties: best single finish, then second best, and so on.
- Team events: every player on a team takes the team's points; Team Trios cuts to top 4, and all three winners qualify.
- Championship invites: the 12 Open winners, the top 10 on points, last year's champion. A second invite passes down.
- Money: $1,000 in prizes per Open paid to the top 8; $7 of every entry goes to the Championship prize pool, which is
  split among its top 8. Top 8s may agree a split but must play it out.
- Competitive REL, decklists required. Standings live in a Google Sheet; news goes out on Facebook, X, Bluesky, Discord.

What we have to match: seasons of events across several hosts, configurable placement points, qualification, team
events, a per-entry league cut, and a public standings page that replaces the Google Sheet.

## Decisions (John, 2026-11-13)

1. **Entry fees: Stripe or at the door.** The host connects their own Stripe account and picks per event: pay in the
   app, pay at the door (host marks paid), or either. Table 1 never holds money.
2. **Prizes: the app works it out, the host pays; in-app transfers later.** Data is shaped so transfers can be added.
3. **General leaderboards rank by a rating from matches** (Elo-style), one board per format.
4. **Listed by default, opt out.** Signing up for a public event says results are public; a switch in Sharing takes
   you off the general boards. A league's standings always list its players, like an event's standings do.
5. **Private, Friends, Public** (John, later the same day): "events can be created with private, friends, and public
   visibilty. users should be able to view a list of events visible to them in the events tab of the app. users
   should be able to filter public events by the same modes as companion, format, location, etc." Create offers the
   three; the list of events you can find sits in the Events tab; filters are format, distance, date, words, team,
   league, seats left.

## What exists and what's missing

Exists: scheduled events with a sign-up link, cap and waitlist, top 8, decklists; visibility `nearby` / `link_only` /
`private`; `/s/<id>` public page (sign-up, then Standings | Matchups); event follows; team draft and team sealed (3 or
4 a side, organizer builds the teams); regulars and nearby alerts; lifetime records (not per format); a Next event
widget (no settings); round clock with pause / add time.

Missing: a public listing, descriptions, leagues and seasons, stored final places (standings are worked out by the
engine on request and nothing keeps where a player finished), per-format anything, captains and team sign-up,
constructed team events, money of any kind, any screen meant for a TV.

## Phase 1: public events, leagues, leaderboards, display, widget (building now)

Contract: `contract/public-events-leagues-2026-11-13.md`.

**Finding events.** Who can find it becomes **Public** (everyone on Table 1 and the web), **Friends** (the
organizers' friends) or **Private** (nobody: QR, code, link or invitation, today's default). It is about finding: a
friends event's link still opens for whoever has it. The older Nearby + QR and invitation-only choices stay in Setup.
Events gain a **description** (2,000 characters, plain text, links tappable, queued for moderation review) and a
**venue address**. The Events tab lists the events you can find under your own, with the filters Companion's event
search has: format (several), distance from you, date (today, this weekend, this week, this month), words (name,
venue, league), team events, league events, seats left, and Public or Friends. The event page leads with name, date,
venue and format as now, description one tap deeper.

**Final places are kept.** When an event completes, the engine writes each player's final place (`event_placements`:
place, points, record, playoff finish, the team's place for team events), and rewrites it if a result is corrected
afterwards. It is a rebuildable copy of what the standings say, never an input to them. Leagues and profiles read it.

**Leagues.** A league has a name, an address (`/league/<slug>`), a description, a region, a link (Discord, site),
an owner and organizers, and **seasons**. A season has dates, a points rule and a qualification rule:
- points by final place in brackets (MMS: 2nd 10, top 4 8, top 8 6, top 16 3), a participation value for everyone
  else, optional points per match win (store leagues), an event multiplier (a 2× event), optional best N results;
- qualification: event winners, the top N on points, named extra invites (last year's champion); a second
  qualification passes down the points list.
An organizer of both the league and the event puts the event in a season. Standings are worked out from the kept
places on every read: rank, points, events, best finishes, qualified or not; a player's row opens their event by
event points. Guests (no account) are listed by name and merge by name within a league; their points follow them when
they claim a seat with an account. The league page is public on the web, signed out too (names, no profiles).

**League notifications.** Follow a league (players of a season follow it automatically, mutable per league):
- `league.event`: a new event was added ("MMS 2026 · Modern Open · Sun 29 Mar · MeH Games");
- `league.results`: an event's places are in: players get their points and new rank, followers get the winner;
- `league.qualified`: you qualified for the season's final;
- `league.season`: the season ended, with the champion and your final place.
New public events near you by format need a saved home area; that is phase 2.

**Format leaderboards.** One board per constructed format, one for Limited (draft and sealed), one for Cube. Rating
starts at 1500; each rated match moves both players by Elo (K 40 for a player's first 10 matches on the board, then
24; a draw is half). Rated: matches between two accounts in completed events that are public or in a league, with 6+
players, not demo. Byes, guests and unfinished events never count. Boards are rebuilt from the match records whenever
an event completes or a result is corrected, and nightly, so there is no drift. Listed: 10+ rated matches on the
board, one in the last 12 months, not opted out. Boards are readable signed out on the web (names only).

**TV display (web).** `table-1.site/d/<event>`: a full-screen page for a TV, projector or cast tab. Three views that
rotate on their own or stay put: the round clock (huge, with round and results-in count), pairings (by table, and A–Z
by player so people find their seat), standings (paged). Works signed out for public and link events, signed in as
the organizer for private ones. The organizer's Live screen gets a Display row with the address and a QR code. Native
casting (AirPlay second screen, Google Cast) and remote control of what's showing are phase 4; AirPlay mirroring and
Chrome's Cast tab work with the web page today.

**Upcoming events widget** (iPhone, Android): the next events you can find, with Formats (pick any; none = all) and Near me
| Everywhere in the widget's settings. Small: the next one. Medium: three. Large: six. Your own sign-ups are marked.

Build order: server, the web display (web only by nature), iOS screens and widget, then web, then Android.

## Phase 2: teams and championships (proposed)

- **Captains and team sign-up.** For team events with sign-up open, a player signs up a team (name), becomes its
  captain and gets a team link; teammates join through it. The captain orders the seats, removes a teammate, hands the
  captaincy on, withdraws the team. A team counts toward the cap when full. The organizer can still build or fix teams.
- **Team Trios (constructed).** A team format with a format per seat (Modern / Standard / Duel Commander), paired
  team against team, seat against seat. Team Sealed and Team Draft keep working as now.
- **Top 4** as a cut choice beside None and Top 8, for teams too.
- **Championship events.** A season's final takes sign-ups only from qualified players; Invite the qualified sends
  the invitations; a declined or doubled invite passes down.
- **New event alerts by format and area.** A saved home area (rough, your choice) and formats; one push per new
  public event that matches, at most a few a week.
- League organizers invited by name or email; several hosts per league each running their own events.

## Phase 3: entry fees and prizes (proposed)

**How the money moves.** Stripe Connect, Express accounts, direct charges on the host's account: the host is the
seller, Stripe pays out to the host's bank, Stripe handles the host's identity checks and tax forms. Table 1's part
is an optional application fee on each charge. In-person event entry is a real-world service, so Apple's and
Google's in-app purchase rules don't apply (App Store guideline 3.1.3(e)); we use Stripe's PaymentSheet with Apple
Pay and Google Pay on the phones and Stripe Checkout on the web.

- **Host setup.** Account → Payments → Connect Stripe (Stripe's hosted onboarding). A league connects its own account
  the same way to receive its cut.
- **Event setup.** Entry fee, currency, Pay in app | At the door | Either, refund rule (full until N hours before
  the start, then the host decides), what the host keeps (flat or percent), the league cut per entry (from the
  season, like MMS's $7), and a payout table by place (percent of the pool, presets by field size).
- **Sign-up.** Pay in app holds the seat when the payment succeeds; the waitlist charges on move-up with a few hours
  to pay. At the door: the organizer's player list has Paid / Not paid, and round 1 can warn about unpaid players.
  Team events: the captain pays for the team or each member pays their share (host's pick).
- **Prize pool.** Pool = entries − host's share − league cut, shown on the event page as it grows. At the finish the
  app lists what each place is owed; the organizer can record an agreed split; each row is marked paid (cash, store
  credit, other) and the player sees it. The league's pool adds up across the season on the league page.
- **League cut.** In-app payments send it to the league's Stripe account at charge time; door payments list it as
  owed by the host.
- **Later: in-app prize transfers.** The payout rows gain a transfer state; winners connect a bank through Stripe.
  That puts Table 1 in the flow of prize money (state contest rules, 1099s, disputes), so it waits for a lawyer's read.

Needs from John before building: a Stripe account for Table 1 with Connect turned on, the fee Table 1 takes (0 at
launch is the simplest), and a read of the organizer terms (they already say organizers are responsible for fees,
prizes and local law).

## Phase 4: organizer tools for the room (proposed)

- Display remote: the organizer picks what every display shows, pins an announcement ("Round 4 starts 2:15"), and
  displays follow at once; a display link that works for private events.
- Native second screen: AirPlay external display on iPhone and iPad, Google Cast on Android.
- Time extensions per table, shown on the display and the players' trackers; judge call from a player's screen.
- Printable pairings, standings and result slips from the web.
- Rules level (Casual / Competitive) and decklist deadline on the event page.

## Open points (defaults chosen, John can change)

- Anyone can make a league (3 per account, names and descriptions moderated). Alternative: approve leagues by hand.
- League pages and format boards are readable signed out, by name only.
- Rated events need 6+ players, to keep two friends from farming a board.
- Limited is one board, not one per set.
- Table 1's fee on in-app entry payments.
