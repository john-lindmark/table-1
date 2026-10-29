# Sign in with Discord (2026-10-29)

**Continue with Discord** on the sign-in screen on iOS, web and Android. It signs in to an existing account or makes a
new one, like Apple, Google and email. No server change: Supabase's Discord provider (Authentication → Sign In /
Providers, set up by John 2026-10-29) does the work. Cases `testdata/discord-sign-in/cases.json`; tests
`SignInFailureTests` + `DiscordSignInTests` (iOS), `discordSignIn.test.ts` (web), `DiscordSignInTest` (Android).
The Discord bot (`contract/discord-2026-10-29.md`) counts a Discord sign-in as a link to that Discord user.

## Flow
Discord gives Supabase no ID token, so no client signs in natively: every client goes through Supabase's OAuth
redirect (`/auth/v1/authorize?provider=discord`, scopes `identify email`, Supabase's default) and Discord's own
consent screen, which names the Discord application ("Table 1").
- **iOS:** `supabase.auth.signInWithOAuth(provider: .discord, redirectTo: table1://auth-callback)` in an
  `ASWebAuthenticationSession` sheet (the `table1` scheme is already the app's; the sheet takes the return itself,
  so `onOpenURL` never sees it).
- **Android:** `auth.signInWith(Discord)` in a Custom Tab, back via `table1://auth-callback` like Apple on Android.
- **Web:** `signInWithOAuth({ provider: "discord", redirectTo: <the page that asked> })`, like Apple on the web.
- Redirect allow list (Supabase → URL Configuration): `table1://auth-callback` (both apps; Apple on Android already
  uses it) and the table-1.site pages.

## Buttons
Order: Apple, Google, **Discord**, email. Discord's button is a surface button (`CONTINUE WITH DISCORD`), like
email's: the accent stays Google's, and no Discord blurple (one accent). Busy while the sheet/tab is open.

## Accounts
- Same email as an existing account: Supabase adds the Discord identity to that account when Discord says the email
  is verified; otherwise it makes a new account.
- **Name step:** Discord brings a username (`full_name`), not a real name, and events show "First Last". So, like
  email, an account whose identities are all `email` or `discord` and that has no `first_name` takes the name step
  before the app opens (`needsName`; cases `needsName`). Its display name is the Discord username until then.
- Nothing extra on account deletion: unlike Apple, Discord has no token to revoke.

## Failures
- Cancelled: closing the sheet/tab (iOS `ASWebAuthenticationSessionError.canceledLogin`) or **Cancel** on Discord's
  screen (`error=access_denied` in the return). Says nothing.
- Anything else: "Sign-in failed. Try again." and a Sentry report (iOS, Android).

## Telemetry
`sign_in_started` (web), `signed_in` and `sign_in_failed` with `method: discord`; `reason` cancelled / error.
