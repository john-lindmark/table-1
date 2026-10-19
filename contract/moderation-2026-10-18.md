# Moderation: automated checks, enforcement, reports and appeals (2026-10-18)

Server: migration `20261018190000_moderation.sql`, edge function `moderate` (live 2026-10-18, shadow mode). Tests `supabase/tests/88_moderation_test.sql`,
classifier cases `testdata/moderation/cases.json` (`supabase/functions/moderate/policy.test.ts`). Builds on reports
(`contract/friends-sharing-2026-10-18.md` § UX rules 6) and sharing visibility.

## Principles (modern trust & safety practice, sized for Table 1)

1. **Moderate what other people can see, nothing else.** Private decks, binders and notes are never sent anywhere.
   Display names, handles and photos always show to signed-in accounts, so they are always checked; a deck, cube or
   binder name is checked once it reaches friends or anyone; event names, guest names and shared deck photos are
   checked because the event's players see them.
2. **Content is acted on automatically; accounts are judged by a person.** The classifier can hide or reset a piece of
   content. Restricting an account is a moderator decision (`moderation_restrict`), never automatic.
3. **Least drastic, reversible action.** A blocked name is reset to a neutral default; a blocked photo is taken down; a
   blocked deck/binder/cube name stops being shared (its setting is kept and comes back on appeal); nothing is deleted
   until a moderator upholds it. Nobody is ever removed from an event (Play correctness comes first).
4. **Tell people what happened and let them appeal.** Every action sends the owner a notice saying what changed and why
   (category, in plain words), with one appeal per action. Reporters are never named.
5. **Shadow mode first.** `moderation_settings.mode = 'shadow'` records every verdict and puts blocks and reviews in the
   queue without touching anyone's content (except child-safety blocks, which always apply). John switches to
   `'enforce'` after checking a week of verdicts.
6. **Game-aware.** Magic is full of violent and dark words: card names (Murder, Thoughtseize, Necropotence, Slaughter
   Pact, Hymn to Tourach, Doomsday), archetypes (Burn, Death and Taxes, Goblins) and in-jokes are fine. The classifier
   prompt says so and `testdata/moderation/cases.json` holds false-positive cases that must stay `allow`.
7. **Measured.** Every verdict is stored with model, category and reason; `moderation_stats()` reports volumes,
   overturn rate on appeal and review-vs-block split so thresholds are tuned on data.

## Pipeline

```
write (trigger) ─┐                       ┌─ allow ─────────────── done (cached by content hash)
report ──────────┼─> moderation_checks ──> moderate (Claude) ──┼─ review ── queue + push to moderators
nightly sweep ───┘   status pending        structured verdict  └─ block ── enforce (mode enforce or child safety)
                                                                            + notice to owner + queue
```

- **Subjects** (`subject_kind`): `display_name`, `handle`, `avatar`, `list_name` (deck/cube), `binder_name`,
  `event_name`, `guest_name` (a participant's name in an event), `deck_photo`, `deck_photo_note`.
- **Enqueue** on write by triggers (only when the content changed and, for lists and binders, only when it reaches someone
  besides the owner). A nightly sweep (`t1-moderation-sweep`) enqueues visible content whose current text has no
  check yet, which covers things that became visible through Sharing. Identical content already judged `allow` is not
  re-sent (`content_hash`).
- **Kick:** enqueueing pings the `moderate` function (pg_net, like `notify-worker`); `t1-moderation-tick` runs it every
  minute as a fallback. It takes up to 20 text checks per request and one image per request.
- **Classifier:** `claude-opus-5-5`, effort `low`, structured output (JSON schema), refusal fallbacks on
  (`fallbacks: "default"`). Text is sent as an anonymous list (no ids, names of owners or emails); images are sent as
  bytes. A refusal or an error marks the check `review` (a person looks), never `allow` or `block`.
  Verdict: `allow` · `review` (unclear, needs a person) · `block` (clear violation). Category: `none`, `hate`,
  `harassment`, `sexual`, `child_safety`, `violence`, `self_harm`, `spam`, `personal_info`, `impersonation`, `other`.
- **Child safety:** a `child_safety` block applies in every mode: the file is moved out of its bucket into the private
  `moderation-quarantine` bucket, the photo is taken down, and moderators get an urgent push. US providers must report
  apparent CSAM to the NCMEC CyberTipline and keep it for the report; that is a moderator duty, shown on the review
  screen. No hash matching (PhotoDNA, Cloudflare CSAM scanning) yet: worth adding before photos are widely used.

## Enforcement (mode `enforce`, verdict `block`)

| Subject | Action (`moderation_actions.action`) | Restored on revert |
|---|---|---|
| `display_name` | reset to "Player 1234" (last 4 of the account id) | old name |
| `handle` | cleared | old handle |
| `avatar` | `avatar_url` cleared (file kept until upheld) | photo |
| `list_name`, `binder_name` | `visibility = 'private'` (hidden from others; rename to share again) | old visibility |
| `event_name` | renamed "Event <code>" (audited in `audit_log` as `moderation.renamed`) | old name |
| `guest_name` | renamed "Guest <seat>" (audited) | old name |
| `deck_photo` | hidden (`event_deck_photos.hidden_at`) | shown |
| `deck_photo_note` | cleared | old note |

Every action writes `moderation_actions` (with `before`), sends the owner `moderation.notice`, and lists in
`moderation_notices()`. **Strikes** are derived, never stored: actions in the last 90 days that weren't reverted. Three
or more put the account at the top of the moderator queue (`flagged`).

## Reports

`user_report` (unchanged API) now also: queues a fresh check of what was reported (the profile's name, handle and
photo, or the named binder/deck/cube) with `source = 'report'`, and raises the account's priority when **3 or more
trusted reporters** reported it in 14 days. A reporter isn't trusted once 3 of their reports were dismissed and none
actioned. Reports are linked to the checks they caused; `moderation_resolve` closes them (`actioned` / `dismissed`).

## Restricting an account (moderators only)

`moderation_restrict(p_user_id, p_days, p_reason)` (0 days lifts it): while restricted the account can't send friend
requests or email lookups ("You can't send friend requests right now") and its profile shows to no one but itself.
Events are not affected. Audited, and the account gets a notice.

## RPCs

Owner (authenticated):

| Call | Does |
|---|---|
| `moderation_notices()` | `[{id, subject_kind, label, action, category, reason_text, at, appeal: none \| open \| upheld \| reverted, can_appeal}]`, newest first, last 180 days. `label` names the thing ("Your display name", "Deck Mono-red"). |
| `moderation_appeal(p_action_id, p_note)` | One appeal per action, note up to 500 characters; `{appeal: 'open'}`. Not yours: 42501. Already appealed: 22023. |
| `moderation_notices_seen()` | Marks notices seen (the Account row's badge). |

Moderators (`t1_private.moderators`; anyone else gets 42501):

| Call | Does |
|---|---|
| `moderation_queue(p_limit = 50)` | `{checks: [...], appeals: [...], flagged: [...]}`: open `review` and `block` checks (content, category, reason, reports, owner's name and strikes), open appeals, accounts with 3+ strikes or a report threshold hit. Images come with a signed URL (10 min). |
| `moderation_resolve(p_check_id, p_decision, p_note?)` | `allow` (undoes any action, dismisses linked reports) or `block` (applies the action even in shadow mode, actions linked reports). |
| `moderation_appeal_resolve(p_action_id, p_decision, p_note?)` | `uphold` (stays) or `revert` (restores `before`, doesn't count as a strike). Notice to the owner either way. An upheld profile photo returns `delete_path`; the review screen then calls `moderate` with `{purge: path}` to delete the file. |
| `moderation_restrict(p_user_id, p_days, p_reason)` | As above. |
| `moderation_stats(p_days = 30)` | Checks by verdict and category, actions, appeals and overturn rate. |
| `moderation_set_mode(p_mode)` | `shadow` / `enforce`. Audited. |

Worker (service role only): `moderation_claim(p_limit)` hands out pending checks (`status = 'running'`, 5-minute lease);
`moderation_record(p_results jsonb)` stores verdicts and enforces.

## Privacy and retention

- Checks keep the content they judged (needed to review it) for 180 days, then the text is cleared (`t1-moderation-purge`).
- Deleting an account deletes its checks and restrictions; its actions are kept for the statistics with the owner
  id and the replaced content cleared.
- The privacy policy names Anthropic as the processor that classifies visible names and photos.

## Clients

- **Account tab:** a "From Table 1" row when there are notices (badge for unseen) → Notices screen: what changed, why,
  when, and **Appeal** (a note, sent once) / "Appeal sent" / "Restored" / "Upheld".
- Push `moderation.notice` ("We changed your display name"), tap → Notices. Moderators get `moderation.review`
  ("3 items to review"), at most once an hour, tap → Review.
- **Review screen** (iOS, moderators only, Account → Review): the queue with content (text or photo), category, reason,
  reports and strikes; Allow / Block; appeals with Uphold / Revert; flagged accounts with Restrict 7 days / Lift.
- Telemetry: `moderation_notice_opened`, `moderation_appealed`, `moderation_resolved` (`decision`, `subject`), no ids.
- iOS demo: `-T1LibraryDemo notices|review`.
