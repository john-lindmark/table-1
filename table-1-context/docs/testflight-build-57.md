Table 1 0.1.0 (57) — What to Test

On top of build 56 (everything in 56's notes, plus):

FRIENDS ON PROFILES
- Account → Sharing → Friends: "Friends" sets who sees your friends list (starts Private); "You in friends' lists" sets who sees you on your friends' lists (starts Friends).
- Open a friend's profile whose list is shared with you: a Friends row ("3 mutual"), opening their friends, mutual first. Tap one to open their profile; long-press for Block or Report.
- Opening either setting to more people asks first ("Friends will see: your friends.").

EVENT LINKS OPEN IN THE APP
- Open an event's link (table-1.site/s/…) for an event you're not in, after round 1: it opens in the app with Standings and Matchups (no web page), and keeps up every 20 seconds.
- Before round 1 it's the sign-up page, as before. A private event says it isn't available.

FOLLOW AN EVENT YOU'RE NOT IN
- On that same page: Follow. It shows on the Events tab under Following, and you get a notification when each round is paired and when it finishes (once the server part is on).
- Tap Following to turn its notifications off or unfollow.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-09 at 11399c8 from a clean worktree (version 0.1.0, build 57, Release, automatic signing). 428 unit tests passed at 121bf8e (the same app code). On top of build 56 (8052216): dea44b9 (friends on profiles; server live 2026-11-09: migration profile_friends), 121bf8e (event links open in the app; follow events you're not in; the follow server part, migration event_follows and notify-worker, not yet live: until it is, the Follow row and Following section stay hidden). Not yet tried on a phone.
