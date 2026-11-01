# Feature spots (2026-11-01)

The pieces of Table 1 worth showing, each as copy and a phone shot of the real screen, kept in one place and drawn
everywhere Table 1 presents itself: the web landing page, the apps' sign-in screens, the App Store and Google Play
listings, and link previews or posts. John (2026-11-01): make images and copy for the unique functionality, keep
them up to date as the functionality and UI change, and apply them to the site and onboarding on every platform.

## The file

`marketing/bundle/spots/spots.json` is the source. Each spot has:

| Field | What |
|---|---|
| `key` | Short id; the shot is `shots/<key>.png` |
| `title` | The feature's name, drawn as an uppercase label ("Run your own events") |
| `headline` | One line in capitals, the promise ("Run the night from your phone") |
| `body` | Two or three sentences, plain words, what you can do |
| `shot` | Where the shooter opens the screen: `route` on the web dev server (`?demo` for the Library and Insights, `/dev/events?screen=…&bare` for the organizer), `ready` text to wait for, optional `scrollTo` (that text goes to the top of its list) and `file` (a CSV dropped into the page's file input) |
| `onboarding` | In the apps' sign-in carousel and the landing page |
| `store` | Gets a store screenshot, in file order |

`product` holds the name, tagline and one-line description; `store` the listing fields that aren't spots (subtitle,
promotional text, keywords, short description); `limits` the copy lengths every client's test enforces (title 26,
headline 44, body 260). `updated` is the day the copy or shots last changed.

The six spots on day one: **run** (organizer's live round), **play** (life tracker), **record** (lifetime record and
head-to-head, on a sample account), **insights** (a deck's archetype rows: win rate, good and bad against),
**import** (a ManaBox import previewed), **rank** (a ranking screen, four cards). Scanning stays in the import body
until there's a way to shoot the phone's camera screen.

## The shots

`tools/spots/run.sh` (Playwright, Chromium) starts the web dev server, opens each spot's route at 390×844 at 2x,
waits for `ready`, applies `scrollTo` / `file`, stills animations and saves `marketing/bundle/spots/shots/<key>.png`
(780×1688). Then it opens `/dev/spots?size=…` (dev server only) and captures each `[data-spot]` tile:

| Size | Pixels | For |
|---|---|---|
| `appstore` | 1320×2868 | App Store 6.9-inch screenshots (title, headline, body, the shot bleeding off the bottom) |
| `play` | 1080×1920 | Google Play phone screenshots (title, headline, the shot) |
| `og` | 1200×630 | Link previews and posts (copy left, the shot right) |
| `feature` | 1024×500 | Play's feature graphic (the mark and the tagline) |

into `marketing/store/<size>/<n>-<key>.png`, and `copy.mjs` writes `marketing/store/app-store.md` and
`google-play.md` (name, subtitle, promotional text, description, keywords; title, short and full description), each
field with its length against Apple's and Google's limit, the description one paragraph per store spot in order.

The dev server serves the shots folder as it is (`/@fs/…`), so a shoot shows on the landing page and `/dev/spots`
without a restart; a production build bundles the PNGs as hashed assets.

**Keeping them current.** After a UI change to any screen a spot shows, or an edit to the JSON, run
`tools/spots/run.sh`, look at the shots, and commit `marketing/`. The web's `spots.test.ts` fails when a spot has
no shot, a route the router doesn't have, copy over a limit or store copy over a field limit; iOS `SpotsTests` and
Android `SpotsTest` fail when the bundled file doesn't decode or a carousel page has no shot.

## Where they show

- **Web landing page** (`/`, signed out): the tagline and line from `product`, then one section per onboarding
  spot: title, headline and body beside the shot, sides alternating down the page on a wide window, stacked on a
  phone (the shot 260 px wide, cropped at 440 px tall). Copy is drawn from the JSON at build time; the shots are the
  bundled PNGs.
- **iOS and Android sign-in** (signed out, the providers step, no scanned join QR or sign-up page waiting): the mark
  becomes a short band and a carousel takes the space above the buttons, one page per onboarding spot (title,
  headline, body on the left; the shot 132 pt wide on the right, top-aligned, cropped), a row of dots under it
  (the current one accent and wider). It moves on every 6 s until the first swipe, wrapping. With an event waiting
  (join QR, sign-up link), the email and code steps, the name step and the permissions step, the screen is as before.
  iOS bundles `marketing/bundle/spots` as the folder `spots/` (project.yml); Android adds `marketing/bundle` to the
  main assets (`assets/spots/`). Both read the JSON at launch; a missing or undecodable file shows the old screen.
- **Stores**: the listing text and screenshots in `marketing/store/` are what to paste and upload; the per-release
  "What's new" stays in the release notes under `table-1-context/docs/`.

## Telemetry

`spot_viewed` `{key, index, swiped}` when the carousel shows a page other than its first (`swiped` true once the
person has swiped, so auto-advances and taps tell apart). No event on the web landing page (the `$pageview` covers it).
