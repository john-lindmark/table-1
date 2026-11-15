Table 1 for Android 0.1.0 (versionCode 29912614) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
A new way around the app: the tabs are Play, Cards, Insights and Account, each with sub-tabs right above the tab bar. Trade and Wants keep the tab bar, Insights → Rankings has your rankings, your friends' and popular cubes to rank, and Account splits into Profile, Records and Settings. Each tab comes back to where you left it. Collection shelves show their art without the dark overlay.
</en-US>

## What to test

On top of 29911357 (everything in its notes, plus):

- **Sub-tabs**: Play (Events · Life tracker), Cards (Collection · Trade · Wants), Insights (Constructed · Limited · Rankings), Account (Profile · Records · Settings). Life tracker opens full screen; closing it lands on Events.
- **Remembering**: pick Wants, go to another tab, come back: still Wants. Close the app and open it again: still Wants.
- **Rankings**: yours, your friends' (shared with you), popular cubes, cubes and sets you can rank.
- **Account**: Profile is your own profile with Friends at the top; Records has your record, deck photos and every head-to-head; Settings has everything else.
- **Links and notifications**: a trade or wants notification opens the Trade or Wants sub-tab.
- **Collection shelves** (873c2d8, 798c34e): art with no scrim, names and values on tags.

---
Build notes: built 2026-11-15 at 3011efc from a clean worktree (`.claude/worktrees/ship-64`) with `tools/bundle-release.sh`; the Android unit suite (603) passed on the nav work before the commit; jar verified. Copied to `apps/android/app/build/outputs/bundle/release/table1-29912614.aab`. Contract: `contract/main-nav-2026-11-14.md`.
