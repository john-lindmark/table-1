> **UPDATED 2026-10-13:** Two things here are superseded. (1) §1 says to turn the **Email provider OFF** (Apple/Google only). Email sign-in is now being added, so leave email on (using email OTP/magic link, or enable leaked-password protection) and finish the Google provider setup. (2) §9 says the **Collection tab is greyed out ("Soon")**; it is going live as All cards / Decks / Cubes / Trades. See README.md and plan-library-scanning-nav.md. The rest still stands.

# Table 1 — first build: setup and run

Built 2026-10-06. Three clients on one Supabase backend (`aaozhfcbvqrgkkrihkrd`).

| Folder | What | Status |
| --- | --- | --- |
| `table-1-events-web/` | React + Vite web app (existing), now on the V1 backend | Builds, 20 tests pass, changes are uncommitted for your review |
| `apps/ios/` | SwiftUI app (XcodeGen project) | Written and syntax-checked; build in Xcode |
| `apps/android/` | Kotlin + Jetpack Compose app | Written and syntax-checked; build in Android Studio |
| `supabase/` | Migrations (all live), `events-engine` and `delete-account` edge functions (live), pgTAP-style tests | Live on the project |
| `contract/rpc.schema.json` | Every RPC and function the clients call, with exact wire names | Source of truth for models |

What the first build does on every platform: Apple/Google sign-in · create an event (pinned where you stand, optionally open to nearby players) · join by scanning the owner's QR, by Nearby, or from a nearby-alert / owner invite (Join or Decline) · server-side Swiss pairing and standings · report a result (optimistic, idempotent; same score from the opponent confirms, a different one disputes) · organizer edits any result · lifetime record and head-to-head · live updates.

---

## 1. Sign-in keys (needed before anyone can sign in)

Do these once, in this order.

**Apple** (developer.apple.com → Certificates, IDs & Profiles)
1. App ID `site.table1.events` with **Sign in with Apple** and **Associated Domains** enabled.
2. A **Services ID** (e.g. `site.table1.events.web`) with Sign in with Apple; return URL `https://aaozhfcbvqrgkkrihkrd.supabase.co/auth/v1/callback`; domain `aaozhfcbvqrgkkrihkrd.supabase.co`.
3. A **Sign in with Apple key** (.p8). Note the Key ID and your Team ID.
4. Supabase → Authentication → Providers → **Apple**: enable; Client IDs = `site.table1.events,site.table1.events.web`; paste the secret generated from the .p8 (Supabase's Apple docs have the generator).

**Google** (console.cloud.google.com → APIs & Services)
0. **OAuth consent screen** (Google Auth Platform → Branding/Audience): app name Table 1, support email, authorized domains `table-1.site` and `aaozhfcbvqrgkkrihkrd.supabase.co` (plain `supabase.co` is a public suffix and is refused), scopes `openid`, `email`, `profile`. Set the audience to **In production** (these scopes need no Google review); while it is in Testing, only listed test users can sign in.
1. Credentials → OAuth client **Web application** → redirect URI `https://aaozhfcbvqrgkkrihkrd.supabase.co/auth/v1/callback`. This is the *web client ID* (and the only one with a secret).
2. OAuth client **iOS** → bundle ID `site.table1.events`. This is the *iOS client ID*.
3. OAuth client **Android**, one per signing key, all with package `site.table1.events`:
   - debug key SHA-1 `05:9F:BA:EF:ED:5C:86:77:BC:22:F3:3A:97:B5:7E:CD:49:15:FC:58` (this Mac's `~/.android/debug.keystore`)
   - upload key SHA-1 `AE:F5:F4:0B:48:64:A7:87:E7:C8:61:A0:5D:F9:DF:18:8F:8C:08:ED` (`~/.android/table1-upload.jks`, printed by `apps/android/tools/make-upload-key.sh`)
   - Play App Signing SHA-1 `4E:AE:05:E6:D1:BB:E6:D1:CE:A7:16:34:A9:44:91:C7:A4:02:AE:3D` (Play Console → Protected with Play → Play app signing; App integrity moved there in 2026). Builds installed from Play are signed with this one, so Google sign-in from a Play install fails until its client exists.
   The app never uses the Android client IDs directly; Google matches package + SHA-1 to them.
4. Supabase → Authentication → Sign In / Providers → **Google**: enable; Client ID = web client ID, Client Secret = its secret; **Authorized Client IDs** = web, iOS and Android client IDs (comma-separated); turn on **Skip nonce check** (the Google iOS SDK can't pass a nonce).
5. Put the IDs in the apps: Android `apps/android/gradle.properties` → `T1_GOOGLE_WEB_CLIENT_ID` = web client ID; iOS `project.yml` → the iOS client ID (see §3); web needs nothing. Until then the Google button is hidden on iOS and Android.

**Apple token revocation on account deletion** (Supabase → Edge Functions → Secrets)
Apple requires apps with Sign in with Apple to revoke the user's Apple token when they delete their account. The live `delete-account` function does this when these secrets are set (without them, deletion still works and revocation is skipped):
- `APPLE_TEAM_ID` = `94889YTX94`
- `APPLE_KEY_ID` = `3R9N2D4M28`
- `APPLE_PRIVATE_KEY` = the full contents of `AuthKey_3R9N2D4M28.p8`, including the BEGIN/END lines
- `APPLE_BUNDLE_ID` = `site.table1.events`

**Supabase → Authentication → URL Configuration**
- Site URL: `https://table-1.site`
- Redirect URLs: `https://table-1.site/**`, `http://localhost:5173/**`, `table1://auth-callback`
- Providers → Email: **on** (passwordless code + link). Templates, SMTP and subject: `contract/email-sign-in-2026-10-15.md`; the email body is `supabase/templates/sign-in.html`.

## 2. Web

```bash
cd table-1-events-web
npm install
npm run dev      # http://localhost:5173
npm test         # 20 tests: pairings, tiebreakers, analytics redaction
```
Review the changes with `git diff` (they are not committed). New routes: `/j/:code?s=…` (QR join) and `/me` (record + head-to-head). The organizer QR now encodes the secure `/j/` link and has a **New code** button.

### Hosting: Cloudflare (table-1.site)

The domain stays registered at Squarespace; its DNS is on Cloudflare (nameservers `colette` / `sid.ns.cloudflare.com`, set 2026-10-15), which hosts the site and forwards `privacy@table-1.site`. The site is a Cloudflare Worker named `table-1` serving `dist/` as static assets (no server code; Cloudflare now deploys Pages projects this way). Config: `table-1-events-web/wrangler.jsonc`. Live at `https://table-1.site` (2026-10-15).

1. **Cloudflare account** (done 2026-10-15): domain added on the Free plan; the Squarespace/Figma Sites website records and the "no email" SPF/DKIM placeholders were deleted, `_dmarc` kept.
2. **Squarespace** (done): custom nameservers → Cloudflare's two. Cloudflare emails when the domain is active (up to 24 h).
3. **Deploy** from `table-1-events-web` (with `.env` holding the production Supabase URL and anon key, which are baked into the build):
   ```bash
   npm run deploy   # builds, then uploads dist/ with wrangler (pinned version); first run opens the browser to log in
   ```
4. **Custom domains** (done 2026-10-15): `table-1.site` and `www.table-1.site` are `routes` in `wrangler.jsonc`, so `npm run deploy` keeps them attached (this also turns off the workers.dev address). Still to do in the dashboard: Rules → Redirect Rules → template "Redirect from WWW to root", so `www` redirects to `table-1.site`.
5. **Email**: Email → Email Routing → enable (it adds the MX/SPF records) → Routing rules → `privacy@table-1.site` → your Gmail (verify the destination). For `signin@table-1.site` (Supabase SMTP via Resend), add Resend's DKIM/SPF records in Cloudflare DNS, DNS-only (grey cloud).
6. **Check**: `https://table-1.site/privacy` and `/delete-account` load; `curl -sI https://table-1.site/.well-known/apple-app-site-association` returns 200 and `content-type: application/json` with no redirect; sign in on the site (Supabase already allows `https://table-1.site/**`).

`public/_headers` sets the `.well-known` content types, `nosniff` and long caching for `/assets/*`; `not_found_handling: single-page-application` sends unknown paths to `index.html`, so app routes load directly.

## 3. iOS (Xcode 16+, iOS 17+)

```bash
brew install xcodegen
cd apps/ios
xcodegen            # creates Table1.xcodeproj from project.yml
open Table1.xcodeproj
```
1. In `project.yml` replace `REPLACE_WITH_IOS_CLIENT_ID` (two places: `GIDClientID` and the URL scheme `com.googleusercontent.apps.<id>`), then rerun `xcodegen`.
2. Signing & Capabilities: pick your team. Sign in with Apple and Associated Domains come from the entitlements file.
3. Run on a device (QR scanning and location need real hardware).
4. Test Sign in with Apple: tap **Continue with Apple** → Face ID → you land on Home. Your name is saved from the first Apple sign-in only; to see that again, remove Table 1 under Settings → [your name] → Sign in with Apple, which also signs the app out the next time it opens.
5. Profile → **Delete account** asks you to confirm with Apple once more, then deletes the account and revokes Apple's token (App Store review checks for this).

## 4. Android (Android Studio Ladybug or newer, JDK 17)

1. Open `apps/android` in Android Studio; let Gradle sync (Gradle 8.11.1, AGP 8.10.1, compile/target SDK 36, which Play requires for new apps since Aug 31 2026).
2. In `gradle.properties` set `T1_GOOGLE_WEB_CLIENT_ID` to the **web** client ID from step 1.
3. Run on a device or an emulator with Google Play services (sign-in, code scanner and location use them).

### Play Console internal testing (Android's TestFlight)

Internal testing reaches up to 100 testers by email within minutes, with no review and no 12-tester/14-day rule (that applies to production on new personal accounts).

1. **Upload key** (once): `apps/android/tools/make-upload-key.sh`. It asks for a password, writes `~/.android/table1-upload.jks` and `apps/android/keystore.properties` (both git-ignored) and prints the SHA-1 for Google step 3. Save the .jks and password in your password manager.
2. **Developer account**: play.google.com/console, $25, identity verification (can take a few days).
3. **Create app**: name Table 1, app, free. Package name comes from the first upload: `site.table1.events` (permanent).
4. **Build**: `apps/android/tools/bundle-release.sh` → `apps/android/app/build/outputs/bundle/release/app-release.aab`. Each build gets a newer versionCode (minutes since 1970).
5. **Internal testing** → Testers: create an email list, save → Create new release → keep **Play App Signing** on (default) → upload the .aab → release notes → Save and publish. Copy the **opt-in link** from Testers and send it to testers (they accept, then install from Play).
6. **After the first upload**, Protected with Play → Play app signing (was App integrity → App signing): copy the **SHA-1** into a new Android OAuth client (Google step 3) and the **SHA-256** into `table-1-events-web/public/.well-known/assetlinks.json` (next to the debug one), so Google sign-in and the email/QR app links work for Play installs.
7. **App content** (Policy → App content) before the first release can be published: privacy policy URL (needed for location and camera), app access (testers sign in with email codes; give review an email they can use, or mark "all functionality available without special access" is false), ads: none, content rating questionnaire, target audience (18+ / not for children), data safety (email, name, approximate and precise location, camera stays on device; account deletion URL). Privacy policy URL: `https://table-1.site/privacy`; account-deletion URL: `https://table-1.site/delete-account` (both public, signed out, in the web app: `src/screens/Legal.tsx`; the policy text is a draft to review, and the contact address `privacy@table-1.site` must exist). Use `/privacy` for the Google consent screen's privacy policy link too. They need table-1.site deployed first.

## 5. Universal / app links

Every table-1.site page the apps have a screen for opens in the app when it's installed and on the web when it isn't: the join QR (`/j/<code>?s=<secret>`), join links, events, standings, the life tracker, the whole Collection, Account, friends and profiles, and the sign-in email's `/auth/confirm`. The list and how each address maps to a screen are in `contract/universal-links-2026-10-22.md` (cases `testdata/universal-links/cases.json`). Both hosts, `table-1.site` and `www.table-1.site`, serve:

- `/.well-known/apple-app-site-association`: the paths for `94889YTX94.site.table1.events` (iOS entitlement `applinks:table-1.site` + `applinks:www.table-1.site` in `project.yml`).
- `/.well-known/assetlinks.json`: the SHA-256 of the debug key, the upload key and Play App Signing (`CF:C0:3F:8E:…:E9:65:A8`, added 2026-10-30; Play installs opened email and QR links in the browser until then). The Android manifest's `autoVerify` filter lists the same paths.

Both files are in `table-1-events-web/public/.well-known/` and ship with the web build. `src/lib/universalLinks.test.ts` fails if the two files, the manifest and the web routes drift apart.

## 6. Known gaps in this first build

- **Not compiled here.** My workspace can't reach the Apple, Google or Maven download servers, so the iOS and Android projects were syntax-checked but not built. Expect a short round of compile fixes on first open; send me the errors and I'll fix them.
- **Push notifications** (2026-10-16): the `notify-worker` edge function sends the `pgmq` queue `notify` through APNs within seconds (cron `t1-notify-sweep` every minute as backup), using the same APNs secrets as Live Activities. iOS registers its token at sign-in (`register_device`). Android goes through FCM (2026-10-29): Firebase project `table-1-53243`, `apps/android/app/google-services.json` (committed; not a secret) and the service account key JSON in the `FCM_SERVICE_ACCOUNT` function secret (Firebase → Project settings → Service accounts → Generate new private key).
- **Pairing on web** still runs in the browser (same rules file as the server); native apps use the `events-engine` function. Moving web onto the function is a small follow-up.
- **Full pairing path untested end to end**: the function's auth checks are verified live, but pairing a real round needs a signed-in organizer, so the first real event is the end-to-end test.
- Recommended rounds per player count (MTR Appendix E) is still unconfirmed.

## 7. Live Activity and widgets (iOS)

What it does: when a round is paired, each player's phone gets a Live Activity (Lock Screen, Dynamic Island, StandBy, Apple Watch Smart Stack) showing the round clock, table, their rank, opponent and opponent's rank, with 2-0 … 0-2 buttons, then Confirm / Dispute when the opponent reports first. Home Screen (small, medium) and Lock Screen (circular, rectangular, inline) widgets show the same match; small/medium have the result buttons too.

How it stays light on battery:
- The clock is drawn by iOS from the round's end time; nothing updates it.
- The server pushes only when something the player sees changes (pairing, a result in their match, clock pause/resume, round recorded, event over), and only to the players affected. Rank-only updates go at low priority.
- Database triggers hand off through pg_net after commit, so recording a result never waits on Apple; events with no iOS players cost one index lookup.
- Widgets read a shared cache, refresh at most every 15 minutes during a match (10 between rounds, ~6 h when idle), and the app refreshes them whenever it learns something.
- Result buttons update every surface instantly, then settle on the server's answer. Reporting from the Lock Screen asks for Face ID first.

One-time setup:
1. developer.apple.com → Keys → **+** → name "Table 1 APNs", tick **Apple Push Notifications service (APNs)**, Configure → Environment **Sandbox & Production**, Key restriction **Team Scoped**. Download the .p8 and note the Key ID.
2. Supabase → Edge Functions → **Secrets**: `APNS_KEY_ID` = that Key ID, `APNS_PRIVATE_KEY` = full contents of the .p8 (BEGIN/END lines included), `APNS_TEAM_ID` = `94889YTX94`. Until these are set the server skips pushes (everything else works).
3. `cd apps/ios && xcodegen` (the project file is now `Table 1.xcodeproj`, with a new **Table1Widgets** target). Open it, check Signing & Capabilities on both targets uses team 94889YTX94 — Push Notifications, App Groups (`group.site.table1.events`) and Keychain Sharing come from the entitlements.
4. Run on your iPhone and sign in once (this registers the push-to-start token). Players on iOS 17.2+ then get the Live Activity automatically when a round is paired, even with the app closed; on 17.0–17.1 it starts when they open the event.
5. Debug builds use the APNs sandbox and TestFlight/App Store builds production automatically.

Test it: sign in on the phone and join an event as a player, pair a round from the web or another device → the Live Activity appears. Report from the Lock Screen, or have the opponent report first to see Confirm / Dispute. Long-press the Home Screen → **+** → Table 1 to add the widgets.

## 8. Events / Account tabs, cancelling, adding players, TestFlight demo data (2026-10-12)

What changed on every platform:
- **Two tabs.** *Events* puts what's live first: a big card for a round you're playing (clock, table, opponent and ranks, one-tap result) or running (clock, results in, disputes), then invitations, Scan QR / Nearby (web: event code), Upcoming, and Past (collapsed). *Create* is the **+ New** in the top bar. With no events at all, the ways in fill the screen. *Account* holds your record, head-to-head, settings (display name, nearby alerts), sign out and delete account.
- **Auto-open.** While a round you're playing is running, the app opens straight into it once per launch or return from the background. Back goes to Events.
- **Cancel event.** Organizers: event screen → More (iOS) / Cancel event. Players see a Cancelled banner, their Live Activity ends ("This event was cancelled by the organizer"), and the event moves to Past. The open round closes: results players already reported confirm, unreported matches never count. Nobody can join a cancelled event or pair another round in it.
- **Add players.** Organizers, while the event is in setup or seated: Players tab → Add players (also opens right after creating an event). Suggested people are those who've shared the most of your events; search narrows that list; email finds existing accounts only and always answers the same way.
- **Sign-in** uses the new full-bleed Table 1 mark from the Figma "Sign In Graphic".
- **Demo data (TestFlight only).** TestFlight and Xcode builds show sample events on your account; App Store, Android and web never do, and your real record never includes them. Account → Developer → *Load / reset demo* (also restarts the live round's clock) or *Remove demo*.

One-time steps:
1. Supabase → SQL Editor: run `supabase/migrations/20261012120000_cancel_players_demo.sql`'s destructive part, shipped as **table1_run_in_sql_editor.sql** (drops/recreates the status check, swaps the records function so demo results stay out of lifetime records, adds demo removal). Everything else is already live.
2. iOS: `cd apps/ios && xcodegen` (adds AddPlayersView.swift), raise `CURRENT_PROJECT_VERSION`, archive, upload to TestFlight.
3. Web: `npm run build` and deploy `dist/` wherever table-1.site is hosted.

## 9. Life tracker, event types & formats, team events, Collection tab (2026-10-12)

Full spec: `contract/features-2026-10-13.md`. Backend is already live (migration `20261013120000_formats_teams_tracker.sql`, edge functions `events-engine` v4 and `sets-sync`); nothing to run in the SQL Editor this time.

What changed on every platform:
- **Life tracker.** Events top bar → **Life** opens it with no event; from an event, **Open life tracker** syncs both phones live. Your half is at the bottom, the opponent's is rotated to face them. Tap left/right for −/+, hold to repeat; taps less than 2 s apart on the same counter count as one change in History. Counters: Poison, Energy, Experience, Rad, Speed. **Record game** asks you to confirm before it counts; when someone reaches two wins it offers to report the match. The screen stays on while the tracker is open.
- **Track games** (Account, and a switch on the event screen): *Life tracker* makes live cards and auto-open go to the tracker; *Elsewhere* (default) keeps result reporting first.
- **Create event.** Pick Constructed (Standard, Pioneer, Modern, Legacy, Vintage, Pauper, Premodern, Canadian Highlander, Other) or Limited (Draft, Team draft, Sealed, Team sealed) with a set from the Scryfall list (refreshed daily) or a cube name. Team events choose 3 or 4 per team. Rounds default to 3.
- **Draft seating.** Drafts seat players in pods of up to 8 and round 1 pairs across the table (1 v 5, 2 v 6, …). Team drafts alternate teams around the table.
- **Teams.** Organizers set teams by hand or **Randomize** before round 1. Standings show teams first (team points, then members' match wins), with each player's own match wins under their team and in the player table.
- **Collection** tab is in the navigation, greyed out ("Soon"). *(Superseded 2026-10-13: going live.)*
- **Only alerts are native.** Tab bars, segmented controls, switches, steppers, menus and sheets are Table 1's own components on iOS and Android; system alert dialogs stay native. (iOS pull-to-refresh is still the system one.)
- Web pairing now goes through the `events-engine` function like the apps.

One-time steps:
1. iOS: `cd apps/ios && xcodegen` (adds `Tracker/TrackerModel.swift`, `Tracker/LifeTrackerView.swift`, `UI/TeamsView.swift`). `CURRENT_PROJECT_VERSION` is already raised to 3 in `project.yml`. Archive and upload to TestFlight.
2. Android: open in Android Studio and build (new `tracker/` packages).
3. Web: `npm install && npm run build` and deploy `dist/`.
4. Not compiled here: Swift and Kotlin were syntax-checked only, so expect a short round of compile fixes; send me the errors. Web type-checks, tests (50) and builds.

## 10. Organizer event screen: Setup, Live and Results (2026-10-12)

Full spec: `contract/organizer-phases-2026-10-14.md`. Backend is live (migration `20261013140000_organizer_phases.sql`: `update_event_details`, `set_round_clock`).

- **Setup** (before round 1): Players (add players, join QR and code), Seating for drafts, Teams for team events, and **Details** — name, format, set or cube, team size, rounds and round length are editable until round 1 and save as you go. "Start event · pair round 1" asks to confirm.
- **Live** (rounds running): a big round clock with Pause/Resume and +5 min, matches grouped Disputed → Waiting → Results in (tap to set a result), live standings, and Players with Drop / Reinstate. Disputes must be settled before the next round can be paired. Finishing the event asks to confirm.
- **Results** (finished or cancelled): winner card (winning team for team events), final standings, every round's results (tap to correct), and players' final records.
- The web now changes the round clock through the server, so phones, Live Activities and the web always agree.

One-time steps: iOS `cd apps/ios && xcodegen` (adds `UI/OrganizerPhases.swift`), bump `CURRENT_PROJECT_VERSION` to 4, archive. Android: build. Web: `npm run build` and deploy `dist/`. Swift and Kotlin are syntax-checked only.

## 11. Table 1 for Discord (2026-10-29)

**Status 2026-10-29:** steps 1–5 and 7 done (migration applied, `discord-bot` v1 deployed, secrets set, URL saved,
commands registered globally and on John's server). Step 6 done too: table-1.site deployed at c5cae2f on 2026-10-29, so `/discord` and the `/link` page are live. A
server that got its own copy of the commands shows them twice once the global ones arrive: `register.sh --guild <id> --clear`. `tools/discord/bundle.sh` lays out the deploy copy (engine files under `events-engine/`).

Contract `contract/discord-2026-10-29.md`, plan `table-1-context/docs/plan-discord-2026-10-29.md`. The bot is the edge
function `discord-bot` (Discord's *interactions endpoint*: no gateway process, every request Ed25519-signed), its
`discord_*` RPCs (migration `20261029130000_discord.sql`), and the web pages `/discord` and `/discord/link`.

1. **Discord application** (discord.com/developers → Applications → the Table 1 app, client id `1565382252706140300`,
   the same one Sign in with Discord uses). General Information: note the **Public Key**. Bot: add a bot, **Reset
   Token** and keep it in the Keychain: `security add-generic-password -s 'Table 1 Discord' -a <application id> -w <bot token>`.
   Leave every Privileged Gateway Intent off (the bot reads no messages). Installation: Guild Install only, scopes
   `bot` + `applications.commands`, permissions Send Messages + Embed Links.
2. **Function secrets** (Supabase → Edge Functions → Secrets): `DISCORD_APPLICATION_ID` (the number; the bot itself
   uses each interaction's id, so this only salts telemetry), `DISCORD_PUBLIC_KEY` (the
   app's key `cd5249585e23c7a5ac9af4c457d4bba723806dce107724b5143a2c49fc623878` is built into `index.ts` as the default,
   so this one is optional),
   `DISCORD_BOT_TOKEN`; telemetry `POSTHOG_KEY` (the project key from `.env`), `POSTHOG_HOST`
   (`https://us.i.posthog.com`), `DISCORD_TELEMETRY_SALT` (any random string; hashes Discord ids for PostHog),
   `T1_ENVIRONMENT` (`production`).
3. **Apply the migration**, then **deploy** `discord-bot` with `verify_jwt` **off** (Discord sends no Supabase JWT; the
   signature is the credential). MCP deploys need `../events-engine/{playoffs,standings,pairings,types}.ts` copied in
   beside `index.ts` with the imports repointed, as `insight-brief` does.
4. **Interactions Endpoint URL** (General Information): `https://aaozhfcbvqrgkkrihkrd.supabase.co/functions/v1/discord-bot`.
   Discord sends a PING to save it; it only saves when the function answers correctly, so do step 3 first.
5. **Register the commands**: `tools/discord/register.sh` (global, up to an hour to appear) or
   `tools/discord/register.sh --guild <server id>` (one server, at once). `--dry-run` prints them. Re-run after
   changing `supabase/functions/discord-bot/commands.json` (and copy it to `table-1-events-web/src/lib/discordCommands.json`;
   `discord.test.ts` fails when they differ).
6. **Web**: `VITE_DISCORD_CLIENT_ID=1565382252706140300` in `.env` (already in `.env.example`) shows **Add to your
   server** on `/discord`; deploy the web as usual.
7. **Add it to a server** from `/discord` (or `https://discord.com/oauth2/authorize?client_id=1565382252706140300&scope=bot+applications.commands&permissions=18432`),
   run `/settings timezone Europe/Stockholm`, `/link`, `/event create format:Modern when:"2026-11-07 18:30"`.

**The deck picture** (2026-10-29, live the same day: both migrations applied, `deck-image` v1 and `discord-bot` v2 deployed, commands re-registered): deploy the `deck-image` function too (`verify_jwt` off; no cross-folder imports),
and re-run `tools/discord/register.sh` whenever `commands.json` changes (`/wants`, `/trades` and the `/event post`
picker were added 2026-10-29).

Smoke test without Discord: `deno test discord-bot/` (signatures, cards, results, telemetry hygiene) and
`supabase/tests/run.sh 94_discord` (links, acting as the account, sign-ups, results, grants).
