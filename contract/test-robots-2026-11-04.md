# Google's test robots (2026-11-04)

John found four accounts he didn't know (John Lane, Mack Sandoval, Vanessa Waters, Joshua Gonzalez; Oct 31 – Nov 4).
They were Google Play's **pre-launch report**: after each Play upload, Firebase Test Lab phones open the app, sign in
with Google test accounts (`firstnamelastname.NNNNN@gmail.com`) from Google's networks (108.177.x, 66.102.x) and tap
through it. Each made a Star Trek draft with every default, added a guest or two ("Alex", "Alice") and left. Three
events were Nearby, so the server ran nearby alerts and regulars alerts for them; no real player was near, so none
went out. No other signup since mid-October looks automated.

We keep the robots (the report finds crashes on real phone models) and keep them apart from real players.
A CAPTCHA wouldn't help: the robots use real Google accounts.

## Which accounts are robots

`t1_private.robots` (user_id, reason, marked_at), one of:

- **device**: the Android app reads `Settings.System.getString(cr, "firebase.test.lab")`; when it is `"true"`, every
  account that signs in calls `account_mark_robot()` (self only, idempotent, `{marked}`; `util/TestLab.kt`).
- **network**: a sign-in (`auth.sessions` insert) from an address in `t1_private.robot_networks` within an hour of the
  account being made. The table holds Test Lab's published blocks (firebase.google.com/docs/test-lab/android/get-started,
  also `gcloud beta firebase test ip-blocks list`; Google updates them about once a year) plus `66.102.8.0/24`, which a
  robot used and the list doesn't have. Add a block with an insert. Long-standing accounts are never marked this way.
  The trigger never fails a sign-in.
- **manual**: `select t1_private.robot_quarantine('<id>', 'manual')` in the SQL Editor.

A false positive comes back out with `select t1_private.robot_release('<id>')`.

## What being a robot does

- The profile and the robot's events are demo data (`is_demo`; events get `demo_owner` = the robot; new events from the
  start, by a trigger). Every list, search, profile, record and push already leaves demo data out for real accounts.
- Two places didn't, and now do: nearby alerts (`_send_nearby_alerts`) skip demo events, and Nearby (`nearby_events`)
  shows a demo event only to whoever made it.
- The robot still sees and runs its own events, so the pre-launch report reaches every screen.
- Android on Test Lab sends nothing to PostHog; Sentry still gets crashes, as environment `test_lab` (filed as bugs,
  since they are real crashes on real phones).
- Marking is audited: `account_audit` `robot.marked` / `robot.released`, and `audit_log` `event.robot_quarantined` /
  `event.robot_released` per event.

## Removal

`t1-robot-sweep` (pg_cron, 05:10 UTC daily) removes robots marked a week ago or more, as account deletion does:
`delete_account()` acting as the robot (which also clears its demo events), its Live Activity tokens, then the auth user.
Accounts with an Apple sign-in are left for delete-account (Apple's token must be revoked). One that can't go (it joined
a real event) stays and is tried again the next day. `t1_private.robot_remove('<id>')` removes one at once.

## Testers are never robots (2026-11-04)

Accounts in `t1_private.demo_testers` are never marked (`robot_quarantine` returns false, whatever the reason) and
never removed (`robot_remove` returns false, for a tester marked before it became one). The store review account
(`appreview@table-1.site`) is a demo tester, and Play's pre-launch robots sign in with the App access credentials on
Test Lab phones, where the Android app marks whoever signs in; without this the sweep would delete the review account
a week later. Migration `20261104140000_robots_spare_testers.sql`. To mark a tester as a robot, take it off the
tester list first.

Tests: `supabase/tests/52_test_robots_test.sql`, Android `TestLabTest`.
