# Drafts with several pods (2026-11-09)

John: "set up a draft event with multiple pods. give organizer the option to do cross-pod pairings", then "add the
ability to randomize all the pods and seatings but also the ability to move players around between pods".

Format `draft` only (team drafts and rotos stay one pod). Migration `20261109150000_draft_pods.sql`, engine
`pairings.ts` / `seating.ts` / `playoffs.ts` (both copies), shared cases `testdata/draft-pods/cases.json` from
`make_cases.py`. Tests: `supabase/tests/72_draft_pods_test.sql`, `events-engine/pods.test.ts` (whole simulated
events), clients' `DraftPodsTests` / `draftPods.test.ts` / `DraftPodsTest`.

## The pick

- `events.pods` integer, null = **Auto** (pods of up to 8: 17 → 6, 6, 5), else 1–16. Never so many that a pod would
  hold fewer than 2 (`podCount` / `t1_private.pod_count`): 3 players with 4 picked is 1 pod.
- `events.pod_pairing` `'pod'` (default for new events) | `'cross'`. Events made before this keep `'cross'`, which
  is how every multi-pod draft paired until now.
- `set_event_pods(p_event_id, p_pods, p_pod_pairing)` → `{event_id, pods, pod_pairing, number_of_rounds, reseated,
  seating}`. Organizers, drafts, before round 1 (55000 after; 22023 for pods outside 1–16 or another pairing;
  42501 for anyone else). A new number of pods on a seated draft re-draws everyone (`reseated` true); changing only
  the pairing keeps the seats. Audited `event.pods_updated`.
- Create sends it right after `create_event_v2` (like the venue pin); Setup → Details shows the same two rows.
- `podLabel` (cases `label`): "2 pods · 9, 8", "1 pod · 6", "No players yet".

## Seats

- **Randomize** = `seat_event` (unchanged name and answer): draws every pod and seat at random for the pick. Pods the
  draw no longer needs and nobody sits in are deleted (3 → 2 pods leaves no empty Pod 3).
- **Move** `seat_move(p_participant_id, p_pod_id, p_seat)`: to another pod (`p_pod_id`; null = a new pod: the first
  empty one, else "Pod N", at most 16), at a seat (`p_seat`; null or past the end = the end). Seats close up behind
  and open in front, so every pod stays 1..n; moving within a pod reorders it. Audited `participant.seat_moved`.
- **Swap** `seat_swap(p_a, p_b)`: two players trade pod and seat. Audited `participant.seats_swapped`.
- Moves and swaps need a seated draft (55000 before the draw or after round 1) and return the seating
  (`{event_id, pods: [{pod_id, name, seats}]}`, as seat_event).
- **Newcomers**: anyone joining a seated draft (QR, code, link, nearby, waitlist, added by the organizer) has no
  seat. `seat_fill(p_event_id)` seats only them, each at the end of the pod with the fewest players (first on a tie),
  so pods arranged by hand stay; before the draw it is the full draw. Pairing round 1 calls `seat_fill` on a seated
  draft and `seat_event` on one still in Setup. Audited `event.seats_filled`.

## Pairing

- **Round 1** (both): across the table in every pod (1v5 … 4v8). An odd pod's last seat is left over; left-over seats
  play each other in pod order (pod 1's v pod 2's, pod 3's v pod 4's), the last one has the bye only when the event
  is odd. Tables run pod by pod, then the across-pod matches, then the bye (`roundOnePlan`, cases `round1`). Before
  this, every odd pod's last seat had a bye.
- **Inside pods** (`'pod'`, rounds 2+): each pod pairs down its own standings, no rematch where one can be avoided.
  An odd pod leaves one player over, from the bottom of the pod, such that the rest still pair without a rematch; a
  pod too small to pair without one (a pod of 2 in round 2) leaves two more over. Left-over players pair with each
  other across pods by overall standings; the bye (odd events only) goes to the lowest of them without one. Among the
  ways to pick them, the first (lowest-ranked first) with no rematch and no second bye wins. Tables pod by pod, then
  across, then the bye.
- **Across pods** (`'cross'`, rounds 2+): ordinary Swiss over everyone, as before.
- Standings are always one list over every pod (tiebreakers count every opponent); top 8 cuts from it.
- `matches.pod_id` is set for a match inside one pod of a draft with 2+ pods (across-pod matches and playoffs: null).
- Engine `standings` rows gain `pod_id`; the answer gains `pod_pairing` (drafts; else null).

## Automatic rounds

`draftRounds(sizes, pairing)` (cases `rounds`): inside pods, `swissRounds(largest pod)` (two pods of 8 → 3);
across pods, `swissRounds(everyone)` (16 → 4). Before the draw from the pick, once seated from the pods as seated
(so moving a 9th player into a pod can add a round), fixed at round 1 by the engine from the seated pods.

## Clients

- Create → Draft: **Pods** Auto | Choose (a 1–16 stepper; Choose starts at the automatic count, at least 2) with
  `podLabel` for the players so far, and **Pairings** Inside pods | Across pods. The Automatic rounds row's detail
  follows the pods (`draftAutoLabel`, cases `auto_label`: "Auto · 3 rounds for pods of 9"). Sent with
  `set_event_pods` right after create when not the defaults.
- Setup → Seating (drafts): the same Pods and Pairings rows (saved at once), **Randomize** (was Re-seat; "Seat
  players" before the draw), each pod drawn as before. Tapping a seat (seated draft, before round 1) opens a menu:
  Move to Pod N (to its end) · Move to a new pod (when the pod has 2+) · Swap with… (a banner "Swap Ana with… · Tap
  the other player · Cancel"; the next seat tapped swaps). Players who joined after the draw are listed under the
  pods ("Not seated · Seated at round 1, in the smallest pod").
- The round-1 note under a pod names its left-over seat (cases `note`): "Seat 7 plays Pod 2's seat 7" or "Seat 7 has
  the bye"; only the real bye's chip says Bye.
- Standings (organizer and player): with 2+ pods seated, each row's tag is its pod code (`P1`, `podCode`) unless it
  has a team, and a filter (All · Pod 1 · Pod 2 …) shows one pod's players in overall order and overall rank.
- Demos: iOS `-T1EventsDemo pods -T1Tab seating`; web `/dev/events?screen=pods`.
- Telemetry: `event_pods_set` {pods (0 = auto), pod_pairing, reseated}, `seat_moved` {to: pod|new|seat},
  `seat_swapped`; `seating_drawn` unchanged.

## Not yet

- Discord `/event create` has no pods option.
- No per-pod top cut or pod winners; one top 8 from overall standings.
