Table 1 for Android 0.1.0 (versionCode 29890522) — release notes

## Play Console "What's new" (en-US, under 500 characters)

<en-US>
Shared decks, cubes and binders open again: a friend's cube or a share link showed an error and 0 cards. Rank a set before it comes out: sets in spoiler season, like Star Trek, lead the Limited set row in Insights, with Rank this set. The Arena cube goes by its name, Arena Powered Cube · Oct 2025. Reopening the app brings you back to exactly where you were, instead of Events.
</en-US>

If 29889968 was already uploaded to testers, the first sentence alone is what's new.

## What to test (internal testers)

New since the bundle of 30 October (versionCode 29889968):

SHARED DECKS, CUBES AND BINDERS
- Open someone's profile → Decks, Cubes or Binders → one of them. Its cards show, with the right count under the name. It used to show a red "Serializer for class … is not found" error and 0 cards.
- Same for a share link (table-1.site/l/…) opened in the app, and for All cards / For trade / Wants on a profile.

Everything from 29889968 (spoiler-season sets, Arena cube names, reopening keeps your screen) is in this bundle too; see `android-release-29889968.md`.

Nothing in this bundle has been run on a phone yet (no Android device or emulator on the build Mac).

---

Build notes (not for testers): built 2026-10-31 at c2771fa from the main checkout with `apps/android/tools/bundle-release.sh` (signed with the upload key, `jarsigner -verify` clean, versionCode 29890522, versionName 0.1.0); `apps/android/app/build/outputs/bundle/release/app-release.aab`, 14.9 MB. On top of 29889968 (25cf8ac) it adds c2771fa: since 9eae756 (2026-10-20) `object SharedList` sat between `@Serializable` and `ProfileCardsPage` in `library/Friends.kt`, so supabase-kt's runtime serializer lookup failed for every `profile_cards` / `shared_cards` answer (in release the class name was shortened, hence "class 'Qj'"). Tests: `FriendsTest.profileCardsPageDecodesByRuntimeLookup`, and `DecodeTypesTest`, which reads the sources and fails if any type given to `decodeAs` / `decodeList` / `decodeSingle` lacks `@Serializable` (both failed with the old code). No server change. Not uploaded: upload it in Play Console → Test and release → Testing → Internal testing → Create new release, and paste the en-US block above into release notes. Then `bugs.py shipped android 29890522 --commit c2771fa`.
