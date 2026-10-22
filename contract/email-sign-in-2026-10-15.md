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

`type: email` covers both first sign-in (Confirm signup template) and returning users (Magic Link template).
Accounts with the same verified email as an Apple/Google identity are linked by Supabase.

## Server config (Supabase dashboard, project aaozhfcbvqrgkkrihkrd)
- Auth → Providers → **Email: on**, Confirm email on. Passwords aren't used by the clients.
- Auth → Email Templates → **Magic Link** and **Confirm signup**: body = `supabase/templates/sign-in.html`,
  subject `Your Table 1 code: {{ .Token }}`.
- Auth → SMTP: a custom sender (e.g. Resend, `signin@table-1.site`). The built-in sender only mails project
  team members and a few per hour.
- OTP expiry 3600 s (the email says "an hour"). Code length 6–10 accepted by the clients.

## App-link files (served by table-1.site, `table-1-events-web/public/.well-known/`)
- `apple-app-site-association`: every page the apps have a screen for (`contract/universal-links-2026-10-22.md`), incl. `/j/*` and `/auth/confirm`, for `94889YTX94.site.table1.events`. Serve as
  `application/json`, no redirect.
- `assetlinks.json`: currently the **debug** keystore SHA-256; add the release key's when Android release signing exists.
