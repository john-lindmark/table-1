# Email sign-in (2026-10-15)

Email joins Apple and Google on the sign-in screen, all three clients. Passwordless: Supabase email OTP.

## Flow
1. Sign-in screen → **Continue with email** → address → **Send code** (`signInWithOtp`, `shouldCreateUser: true`).
2. One email carries both a **Sign in** button and the same one-time code.
3. Either:
   - **Code**: typed on the code step → `verifyOtp(email, token, type: email)`. Works on any device.
   - **Link**: `https://table-1.site/auth/confirm?token_hash=<hash>&type=email`.
     - App installed: universal link (iOS `applinks:table-1.site`) / app link (Android, `autoVerify`) opens the app,
       which calls `verifyOtp(token_hash, type: email)` and is signed in.
     - No app (or a computer): the web route `/auth/confirm` verifies in the browser, then returns to the page that
       asked (kept in `localStorage` when the code was sent; Home otherwise).
   - A used or expired link shows "That sign-in link has expired or was already used. Send a new one." on sign-in.
4. **Name (required, new email accounts).** Signed in, an account whose identities are all `email` and whose
   `user_metadata.first_name` is empty sees a name step before anything else: First name + Last name, both required
   (Continue stays disabled), plus Sign out. Saving writes `profiles.display_name = "First Last"` (40 chars max) and
   `user_metadata` `{ first_name, last_name, full_name }`. Apple/Google accounts never see it. Applies however the
   email was verified (code, app link or web link). Until then the signup trigger's placeholder name (the email's
   local part) stands, but nothing in the app can be reached.
5. Resend is allowed once a minute (Supabase's per-address limit); the button counts down.

## Already sent (2026-10-24)
A returning player on iOS asked for a code about 18 times over three days and never got into the app: each extra
tap was refused (HTTP 429, "you can only request this after N seconds"), the app called that "Couldn't send the
email. Check the address", stayed on the address step, and the Return key could send twice. Now, on all clients
(rules and cases: `testdata/email-sign-in/cases.json`):
- **A refused send is read, not reported.** `over_email_send_rate_limit` (or a bare 429) whose message says
  "after N second(s)" means a code went out moments ago: go to the code step, no error, Resend counts down N
  (capped at 60). Any other 429 (`over_request_rate_limit`, the project's hourly email cap) is **too many**:
  stay, say "Too many sign-in emails right now. Wait a few minutes, or continue with Apple or Google." Neither goes
  to Sentry; `sign_in_failed` `reason` is `already_sent` / `too_many`. Everything else is `error` as before.
- **One send at a time.** Send, Resend and the keyboard's Return/Go all go through one guard while a send is in
  flight.
- **The code step survives leaving the app.** After a send (or an already-sent), the address, the send time and the
  resend time are kept on the device (iOS UserDefaults, Android SharedPreferences, web localStorage
  `t1.signin.pending`). Opening sign-in within 3600 s of the send (the code's life) comes back on the code step for
  that address; Resend is never earlier than send + 60 s. Change email, an expired code and any sign-in clear it.
- The code step adds "Not there? Check spam." under the address.

`type: email` covers both first sign-in (Confirm signup template) and returning users (Magic Link template).
Accounts with the same verified email as an Apple/Google identity are linked by Supabase.

## Review account (2026-10-26)
App Store and Play reviewers can't read a code from our email, so one address, `appreview@table-1.site`, signs in
with a fixed code. On all three clients (`EmailSignIn.isReview` / `isReview`; cases `review` in
`testdata/email-sign-in/cases.json`): an address that is that one after trimming and lowercasing goes to the code
step **without sending an email** (no Supabase call, no `sign_in_email_sent`), and its code is sent as the
account's **password** (`signInWithPassword`; iOS `signed_in` method `review`). Any other address is unchanged. The
code is 10 digits (the code fields take up to 10) and lives only in John's Keychain: service `Table 1 App Review`,
account `appreview@table-1.site` (`security find-generic-password -s "Table 1 App Review" -w`). Only this account
has a password; nobody else can set one from the apps.

The account (made 2026-10-26, id `cb992b93-2672-423e-8949-d405203bc756`, name Robin Ash; "App Review" was flagged as possible impersonation, so it has a plain player name) is in
`t1_private.demo_testers`, so it sees the demo events (seeded with `demo_seed`: 11 events, a live round, rotos)
and a Library seeded from the iOS demo fixture: 400 printings / 790 copies, Boros Energy and Izzet Murktide, the
Vintage Cube. `tools/review/seed.sh` signs in with the Keychain code and reseeds (demo events reset, Library
idempotent). If a reviewer deletes the account, recreate it as in `APP-REVIEW.md` and run the script.
Review notes and the store privacy answers: `APP-REVIEW.md`.

## Server config (Supabase dashboard, project aaozhfcbvqrgkkrihkrd)
- Auth → Providers → **Email: on**, Confirm email on. Passwords aren't used by the clients, except by the review
  account below.
- Auth → Email Templates → **Magic Link** and **Confirm signup**: body = `supabase/templates/sign-in.html`,
  subject `Your Table 1 code: {{ .Token }}`.
- Auth → SMTP: a custom sender (e.g. Resend, `signin@table-1.site`). The built-in sender only mails project
  team members and a few per hour.
- OTP expiry 3600 s (the email says "an hour"). Code length 6–10 accepted by the clients.

## App-link files (served by table-1.site, `table-1-events-web/public/.well-known/`)
- `apple-app-site-association`: every page the apps have a screen for (`contract/universal-links-2026-10-22.md`), incl. `/j/*` and `/auth/confirm`, for `94889YTX94.site.table1.events`. Serve as
  `application/json`, no redirect.
- `assetlinks.json`: currently the **debug** keystore SHA-256; add the release key's when Android release signing exists.
