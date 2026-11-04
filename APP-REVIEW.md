# App Store and Play review

What to fill in for Apple's App Review and Google Play's review, and how the review account works.
The rules are in `contract/email-sign-in-2026-10-15.md` § Review account.

## Review account

- Email: `appreview@table-1.site`. No email is sent to it; the code is fixed.
- Code: in the Keychain (never in git):

  ```bash
  security find-generic-password -s "Table 1 App Review" -a appreview@table-1.site -w
  ```

- Its name is Robin Ash, an ordinary player name: "App Review" was flagged by moderation as possible
  impersonation (official staff), so don't name it after Apple, Google or Table 1.
- It's a demo tester, so it has 11 demo events (one live, rotos, past events) and a Library (790 cards, two Modern
  decks, a Vintage Cube). Reseed before each submission (resets the live round's clock):

  ```bash
  tools/review/seed.sh
  ```

- The code only works with builds that know the review address: iOS from build 31, Android and web from their
  next release. Builds 30 and earlier would send it an email.

### If a reviewer deletes it

Make a new code and account, then reseed. Run the first part in Terminal, the SQL in the Supabase SQL editor with
the printed hash in place of `<hash>`:

```bash
security delete-generic-password -s "Table 1 App Review" -a appreview@table-1.site
security add-generic-password -s "Table 1 App Review" -a appreview@table-1.site \
  -w "$(python3 -c "import secrets;print(''.join(secrets.choice('0123456789') for _ in range(10)))")"
htpasswd -bnBC 12 "" "$(security find-generic-password -s 'Table 1 App Review' -a appreview@table-1.site -w)" | tr -d ':\n' | sed 's/^\$2y/$2a/'
```

```sql
with u as (
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, recovery_token,
    email_change, email_change_token_new, email_change_token_current, reauthentication_token, phone_change, phone_change_token)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
    'appreview@table-1.site', '<hash>', now(), '{"provider":"email","providers":["email"]}',
    '{"first_name":"Robin","last_name":"Ash","full_name":"Robin Ash"}', now(), now(), '', '', '', '', '', '', '', '')
  returning id
), i as (
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select gen_random_uuid(), id, id::text,
    jsonb_build_object('sub', id::text, 'email', 'appreview@table-1.site', 'email_verified', true), 'email', now(), now(), now()
  from u returning user_id
)
insert into t1_private.demo_testers (user_id, note) select user_id, 'App Store / Play review account' from i;
update public.profiles set display_name = 'Robin Ash'
 where id = (select id from auth.users where email = 'appreview@table-1.site');
```

## App Review Information (App Store Connect)

Sign-in required: yes. User name `appreview@table-1.site`, password: the code from the Keychain. Notes:

> Table 1 runs Magic: The Gathering tournaments and tracks a player's card collection.
>
> To sign in: tap Continue with email, enter appreview@table-1.site, tap Send code, then enter the code from the
> password field above as the code. No email is sent to this address. Sign in with Apple also works, but a new
> account starts empty.
>
> The account holds sample data: Events shows a live event you organize (tap it, then Live to see the round,
> enter results and pair the next round) and events you play in; Collection holds cards, decks and a cube;
> Insights shows tournament metagame data. Account → Delete account deletes the account; please don't, so the
> next review can use it.
>
> Camera: scanning cards (Collection → Add cards → Scan) and join QR codes. Location: finding nearby events and
> pinning an event's place. The app has no purchases. "Buy on TCGplayer" (Collection → Wants) opens TCGplayer's
> website.
>
> Table 1 is unofficial Fan Content permitted under Wizards of the Coast's Fan Content Policy and is free.

## App access (Google Play Console)

Policy → App content → App access: "All or some functionality is restricted", one set of instructions. Name
"Review account", username `appreview@table-1.site`, password the code from the Keychain, and the App Store notes above
as the instructions (replace "Sign in with Apple also works" with "Google and Discord sign-in also work"). Play's
pre-launch robots use these credentials too; the account is a demo tester, so it is never marked or removed as a robot
(contract/test-robots-2026-11-04.md § Testers are never robots). They can still change its data, so reseed before each
submission.

## Data safety (Google Play Console)

- Collects or shares required data types: **Yes**.
- Encrypted in transit: **Yes** (every call is HTTPS: Supabase, PostHog, Sentry).
- Users can request deletion: **Yes**, in the app (Account → Delete account) and at
  `https://table-1.site/delete-account`. Account creation: email code, Google, Discord (OAuth).
- Shared: **No** for every type. Supabase, Sentry, PostHog and Anthropic (moderation, deck finder, briefs) process
  data for us as service providers, and Discord and TCGplayer get data only when the user sends it there, all of
  which Play exempts.
- Processed ephemerally: **No** for every type.

| Data type | Required / optional | Purposes |
|---|---|---|
| Location → Approximate location (rough area for nearby events and alerts) | Optional | App functionality |
| Location → Precise location (an event pinned where the organizer is) | Optional | App functionality |
| Personal info → Name | Required | App functionality, Account management, Fraud prevention, security and compliance |
| Personal info → Email address | Required | App functionality, Account management |
| Personal info → User IDs | Required | App functionality, Analytics, Account management |
| Photos and videos → Photos (profile and deck photos) | Optional | App functionality, Fraud prevention, security and compliance |
| App activity → App interactions (PostHog) | Required | Analytics |
| App activity → Other user-generated content (results, collection, decks, trades, reports) | Required | App functionality, Fraud prevention, security and compliance |
| App info and performance → Crash logs (Sentry) | Required | App functionality, Analytics |
| App info and performance → Diagnostics (Sentry) | Required | App functionality, Analytics |
| App info and performance → Other app performance data (scan reports: text read from cards, never images; Account → Improve scanning turns them off) | Optional | Analytics |
| Device or other IDs (FCM push token, PostHog's install id) | Required | App functionality, Analytics |

Not collected: financial info, health, messages, contacts, calendar, files, audio, web browsing, installed apps,
search history. Camera frames are read on the phone and never leave it.

## App Privacy (App Store Connect), matching `PrivacyInfo.xcprivacy`

None of it is used for tracking. All of it is linked to the user (the account id).

| Data type | Used for |
|---|---|
| Email Address | App Functionality |
| Name | App Functionality |
| User ID | App Functionality, Analytics |
| Photos or Videos (profile and deck photos) | App Functionality |
| Other User Content (results, collection, decks, trades, reports) | App Functionality |
| Precise Location (an event pinned where the organizer is) | App Functionality |
| Product Interaction (PostHog) | Analytics |
| Crash Data, Performance Data, Other Diagnostic Data (Sentry) | App Functionality |

Not collected: contacts, purchases, financial info, health, browsing or search history, device ID, coarse
location (nearby searches aren't stored).

Google Play's Data safety answers are above; they add approximate location, device IDs and scan reports.

## Before submitting

- Moderation is still in shadow mode. Apple wants a working filter for content other people see: switch to
  enforce from Account → Review (John's call).
- The privacy policy (`table-1.site/privacy`) still shows "Draft: under review". Finalize it, and make sure
  `privacy@table-1.site` receives mail.
- The reviewer sees Account → "Developer · testers only" (Load / reset demo). It explains the sample data; if
  Apple calls it a test feature (guideline 2.2), hide it for the review account.
- The location permission says "Your location is never stored", but a pinned event keeps its place. Consider
  "Your own location is never stored; an event you pin keeps its place."
