> **UPDATED 2026-10-13:** The two-tab navigation below (Events | Account) is the current build, but it is being reworked for progressive disclosure (summaries first, detail one tap deeper) and a player-vs-organizer split, and a Collection tab is being added. Past events are expected to move to Insights history. See README.md and plan-library-scanning-nav.md. Cancel event, add players and demo data below still stand.

# Plan — Events/Account navigation, cancel event, add players, TestFlight demo data (2026-10-11)

## Decisions (John, 2026-10-11)
- Live event: auto-open into the event while a round you're playing is running (once per launch/foreground); Back returns to Events. Otherwise it's the top hero card.
- Cancel mid-event: keep already-confirmed matches in records/H2H; drop unreported ones.
- Scope: all platforms — backend → iOS (TestFlight) → Android → web → Figma.
- Adding players sends an invitation (they accept); never seats them directly.
- Add by email finds existing Table 1 accounts only; no email is sent.

## 1. Navigation: two tabs
iOS TabView / Android bottom NavigationBar / web top nav. Each tab has its own stack.

**Events tab** (priority order)
1. Live now hero — player: round x/y + clock, table, opponent + rank, one-tap report. Organizer: clock, results in/outstanding, Open event. Stacks if several.
2. Invitations (compact Join/Decline).
3. Upcoming (setup, seated).
4. Past (completed, cancelled) behind "Show past".
- Secondary row: Scan QR · Enter code · Nearby. Create = "+" in the top bar (remove the bottom "Create event" CTA).
- Empty state: Scan / Nearby / Create become the centerpiece.

**Account tab**: name/handle, record (matches, games, events, byes), head-to-head, settings (display name, nearby alerts, location), Sign out, Delete account. "My record"/"Sign out" leave the Events bar.

## 2. Cancel event
- DB: add `cancelled` to events_status_check; cancelled_at, cancelled_by, cancel_reason.
- RPC `cancel_event(p_event_id, p_reason)`: organizer only, status in setup/seated/in_progress; stops timer, closes open round, drops unreported matches, audit_log.
- Excluded from nearby_events; join RPCs reject it.
- Live push: extend events trigger so cancel ends Live Activities ("Event cancelled"); widgets clear.
- UI: organizer "Cancel event" (destructive confirm + optional reason); players see a Cancelled banner; listed under Past with a tag.

## 3. Add players to your events
- Where: organizer's event screen → "Add players", while the event is in setup or seated. Also offered right after creating an event.
- Sheet: search field on top, then **Suggested** — people who've shared the most of your events (as organizer or player), most recent as tie-break. Excludes anyone already in, invited, or deleted. Multi-select → "Invite N".
- Search covers only people you've shared an event with, by name or handle. The app never browses all users.
- **By email**: type an address → if it belongs to an existing account they get the invite. The organizer always sees the same "If they have a Table 1 account, they'll get your invite" so the app never reveals who has an account. Caveat: Apple "Hide My Email" users only match on their relay address.
- Invitees get a push and see it under Events → Invitations (existing flow, source `owner_invite`).
- Backend: `suggested_players(p_event_id, p_query, p_limit)` (security definer, scoped to co-participants); `invite_players(p_event_id, p_user_ids uuid[])` batch wrapper over invite_to_event; `invite_by_email(p_event_id, p_email)` looks up auth.users server-side. Rate limits: invites 100/hour per organizer, email lookups 20/hour.

## 4. Demo data (TestFlight only)
- `events.is_demo`; demo events private. Clients show them only on TestFlight/Debug iOS builds; App Store, Android, web never.
- Separate demo record layer so the real player_records/head_to_head stay clean.
- Seed ~8 events (1 playing live R3/4 table 7, 1 organizing live, 1 upcoming, 1 invitation, 4 completed, 1 cancelled) and ~12 demo opponents, so Suggested players is populated too.
- TestFlight-only Developer section in Account: Reset demo (restarts clocks), Remove demo.

## 5. Order
Backend (rolled-back test) → iOS → new TestFlight build → Android + web → Figma screens.

## Status (2026-10-11)
- Backend: live except the destructive part. `supabase/table1_run_in_sql_editor.sql` must be run in the SQL Editor (status check with `cancelled`, cancelled_by FK, demo-aware apply_match_outcomes, demo_remove, delete_account). Until then `demo_seed` is not executable, so demo results can't reach real records.
- live-activity v3 deployed (demo filtered unless include_demo; cancelled ends activities with an alert). events-engine has a local 409-on-cancelled change, not redeployed (the DB guard covers it).
- iOS, Android, web: written; web tsc + 20 tests + build pass; Swift/Kotlin syntax-checked only. Synced to ~/Documents/Table 1. Web is not deployed (table-1.site hosting unknown).
- Figma: Events, Account, Add players, cancel states and new sign-in on iOS, Android and Web; old Home/Profile flows deleted. `font/mono` is temporarily JetBrains Mono — set back to SF Mono.
