# Universal links (2026-10-22)

Any table-1.site link someone taps opens in the app when it's installed, and on the web when it isn't. All three
clients, no server change. Cases: `testdata/universal-links/cases.json` (iOS `WebLinkTests`, Android `WebLinkTest`,
web `universalLinks.test.ts`).

## Rule
- Web addresses are the links. Nothing new to share: the join QR, Copy join link, Copy standings link, a profile or
  deck address copied from the browser all open the matching app screen.
- Both hosts: `table-1.site` and `www.table-1.site`, https only.
- The phone hands the app only the paths below (`public/.well-known/apple-app-site-association`, the Android
  manifest's `autoVerify` filter). Everything else stays in the browser: privacy policy, account deletion, `/dev/*`,
  unknown pages.
- A web sign-in coming back (Apple/Google return with `#access_token=`, `#…error_description=`, or `?code=`) belongs to
  the browser that asked: excluded in the AASA; Android can't exclude by `#`/`?`, so its app sends those back.
- An address under a claimed path that the app has no screen for (`/j/<code>` without a secret, a malformed
  `/library/…`) goes back to the web: iOS shows it in an in-app Safari view (it never hands its own address back to the
  app, so nothing can bounce); Android opens the default browser by package (a plain VIEW would come back to the app).
- Links wait for sign-in like the QR join always has: signed out, the app signs in first, then opens the screen. The
  exception is standings, which need no account: signed out, they open on the web.
- Widgets, Live Activities, controls and pushes keep `table1://` and push payloads: they never leave the app.

## Map
Stacks are opened fresh on that tab, parents first, so Back lands where it would on the web.

| Web address | App |
|---|---|
| `/`, `/sign-in` | Events tab |
| `/e/<id>`, `/p/<id>` | Events › the event |
| `/e/<id>/add` | Events › the event › Add players |
| `/s/<id>` | the event if you organize or play in it (`event_preview` access), else the standings page on the web |
| `/join/<code>` | joins with the code (`join_event`, your account's name; already in → lands on it), then the event; a refusal shows the server's words ("Ask the organizer for an invite") |
| `/j/<code>?s=<secret>` | QR join, as before |
| `/auth/confirm?token_hash=…` | sign-in email, as before |
| `/life`, `/life/<match>` | life tracker (local / that match) |
| `/library` | Collection tab |
| `/library/cards`, `/add`, `/card/<oracle>`, `/decks`, `/cubes`, `/import`, `/trades`, `/binders`, `/wants`, `/matches` | that screen |
| `/library/find`, `/library/import/deck` | Decks › Find a deck / Import |
| `/library/import/cube`, `/library/rankings` | Cubes › Import / Rankings |
| `/library/list/<id>[/add, /stats[/hand, /odds, /pack], /versions, /v/<n>, /rankings]` | the deck/cube › that screen |
| `/library/list/<id>/printing?…` | the deck/cube (Change printing needs the line) |
| `/library/ranking/<id>[/screen/<job>, /lists/<job>, /card/<oracle>/<job>, /compare/<other>/<job>, /pack, /changes]` | the ranking › that screen |
| `/library/trade/<id or new>`, `/library/binder/<id>`, `/library/match/<user>` | Trades / Binders / Trade matches › that one |
| `/me` | Account tab |
| `/friends`, `/friends/add` | Account › Friends |
| `/sharing` | Account › Sharing |
| `/u/<user>[/<section>[/<item>]]` | Account › the profile (a section's title and deck come from the profile) |

## Telemetry
`link_opened` `{to: event | events | standings | join_code | join_qr | sign_in | tracker | collection | account | web}`
when a table-1.site link reaches the app (never the address or ids).

## Rollout
- iOS: needs a new build; build 19 and earlier only understand `/j/` and `/auth/confirm`, so a newly claimed link
  opens build 19 on its home screen and goes no further. Deploy the web (which serves the new AASA) after the build
  that carries this is on TestFlight. iOS fetches the AASA through Apple's CDN on install and update.
- Android: same paths in the manifest; Play App Signing SHA-256 still to add to `assetlinks.json` (SETUP.md §4).
- Not yet tried on a device: the simulator can't check universal links without a signed build.
