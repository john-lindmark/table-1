# Web Google sign-in straight to Google (2026-10-23)

Web only, client-only. iOS and Android already sign in with Google natively and hand Supabase the ID token.

## Why
The web used Supabase's OAuth hop (`signInWithOAuth`), so Google's return address was
`aaozhfcbvqrgkkrihkrd.supabase.co/auth/v1/callback` and its screen said "to continue to aaozhfcbvqrgkkrihkrd.supabase.co".

## Flow
1. **Continue with Google** (our own button, unchanged) sends the tab to
   `accounts.google.com/o/oauth2/v2/auth` with the web OAuth client, `response_type=id_token`,
   `scope=openid email profile`, `prompt=select_account`, a random `state` and the hex SHA-256 of a random nonce.
   The raw nonce, the state and the page to return to are kept in `sessionStorage` (`t1.signin.google`).
2. Google returns to `<origin>/auth/google#id_token=…&state=…`. The page drops the fragment from the address bar,
   checks the state, and calls `signInWithIdToken({ provider: "google", token, nonce: raw })`, the same check the apps
   get. Then it goes back to the page that asked (same-origin paths only).
3. `error=access_denied` (declined at Google) goes back to that page signed out; any other error, a state this tab
   didn't send, or a token Supabase refuses shows "Google didn't sign you in" with the sign-in buttons.

Google's screen then names `table-1.site`, and **Table 1** (with the logo) once the brand is verified in Google
Cloud (Google Auth Platform → Branding / Verification Center).

`/auth/google` is never claimed by the apps (apple-app-site-association, Android manifest; cases in
`testdata/universal-links/cases.json`), so the return always lands in the browser that asked.

## Setup
- `VITE_GOOGLE_WEB_CLIENT_ID` in the web build's `.env`: the web OAuth client (the one Supabase Auth → Google lists
  first, also Android's `T1_GOOGLE_WEB_CLIENT_ID`). Empty falls back to Supabase's OAuth hop.
- That client's **Authorized redirect URIs** in Google Cloud must list `https://table-1.site/auth/google`,
  `https://www.table-1.site/auth/google` and, for dev, `http://localhost:5173/auth/google`. Without them Google
  answers `Error 400: redirect_uri_mismatch`.
- Apple sign-in on the web is unchanged (Supabase's OAuth hop).

Tests: `table-1-events-web/src/lib/googleSignIn.test.ts`, `universalLinks.test.ts`. Telemetry: `signed_in` /
`sign_in_failed` with `method: "google"` as before.
