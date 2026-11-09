Table 1 0.1.0 (56) — What to Test

On top of build 55 (everything in 55's notes, plus):

DRAFTS WITH SEVERAL PODS
- Create → Limited → Draft: Pods (Auto, or Choose a number) and Pairings (Inside pods / Across pods). The line under Pods says how players split ("2 pods · 9, 8").
- Setup → Seating: the same rows; Randomize redraws everyone. Tap a seat: Move to Pod 2, Move to a new pod, or Swap with… then tap the other player.
- Add a player after seating: they show under "Not seated" and are seated in the smallest pod when round 1 is paired.
- Round 1: an odd pod's last seat plays another odd pod's last seat (the note under each pod says so). Inside pods, later rounds stay in your pod.
- Standings show each player's pod (P1, P2) and a filter for one pod.

RE-PAIR A ROUND
- Live → Earlier tab: correct an earlier round's result; the Round tab then offers Re-pair round N (also in More). It asks first, clears results already in for that round when it says so, and players get "Round N re-paired".

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-09 at 8052216 from a clean worktree (version 0.1.0, build 56, Release, automatic signing). 421 unit tests passed at 1a8303b (the same app code). On top of build 55 (5d05cac): a3f3eb0 (re-pair a round; server live 2026-11-09: migration withdraw_round, events-engine v18, notify-worker v21), d41cd4e + 7ffba59 (drafts with several pods; server live 2026-11-09: migration draft_pods, events-engine v18). Not yet tried on a phone.
