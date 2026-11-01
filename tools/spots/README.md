# Feature spots

One file, `marketing/bundle/spots/spots.json`, holds the pieces of Table 1 worth showing: a title, a headline, a body
and where to shoot the screen. It is read by the web landing page, the iPhone and Android sign-in carousels, and the
store listings (`marketing/store/`). Contract: `contract/feature-spots-2026-11-01.md`.

- **Change copy**: edit the JSON, then `tools/spots/run.sh` (rewrites the store listings; shots unchanged unless the
  screens changed) and commit `marketing/`.
- **A screen changed**: `tools/spots/run.sh` re-shoots every spot from the web dev server (`--only <key>` for one) and
  lays the store images out again. Look at `marketing/bundle/spots/shots/*.png` before committing.
- **A new spot**: add it to the JSON with a `shot.route` the dev server can open without signing in (`?demo` for the
  Library and Insights, `/dev/events?screen=…` for organizers), run the shoot, and it appears everywhere.

Outputs:

| Path | What |
|---|---|
| `marketing/bundle/spots/shots/<key>.png` | The phone shot (780×1688), bundled by the apps and used by the landing page |
| `marketing/store/appstore/<n>-<key>.png` | App Store 6.9-inch screenshots (1320×2868) |
| `marketing/store/play/<n>-<key>.png` | Google Play phone screenshots (1080×1920) |
| `marketing/store/og/<n>-<key>.png` | 1200×630 cards for links and posts |
| `marketing/store/feature/feature.png` | Play feature graphic (1024×500) |
| `marketing/store/app-store.md`, `google-play.md` | The listings, with each field's length against its limit |
