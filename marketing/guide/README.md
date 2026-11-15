# Table 1 Feature Guide: the sources

The Feature Guide (https://claude.ai/artifact/Lj6y8earFPdKFka4YdN8Ai) is built from this folder. Edit here,
never on the published page.

- `manifest.json`: the date in the header and footer (`updated`), the sections in order with their index titles
  (`nav`, `new` for the index's NEW mark), the artifact's address, and the hash of the page last published.
- `sections/<id>.html`: one `<section>` each, as it sits in the page. `new.html` is What's new (newest first, one
  `<li>` per line), `status.html` the Status table.
- `page.html`: the styles, header, index and footer around them (`{{nav}}`, `{{sections}}`, `{{updated}}`).

## When work lands on main

1. Edit only the sections the work touches: a paragraph or `<li>` in its section, a line at the top of
   `sections/new.html`, the row in `sections/status.html`. Find the spot with grep; there's no need to read whole
   files. Set `updated` in `manifest.json` to today. A new section takes a file and an entry in `manifest.json`.
2. Put anything about builds, dates, testing or what isn't live in `<span class="team">…</span>`: the page shows it,
   Support leaves it out. (Older paragraphs mix the two; `tools/support/scrub.json` handles those.)
3. `python3 tools/guide/build.py`: writes the page to `marketing/guide/build/feature-guide.html` (not committed),
   Support's copy `marketing/bundle/support/guide.json` and the search cases. Read the diff of `guide.json`; a
   sentence players shouldn't see takes a team span or a `scrub.json` rule. Commit the folder, `guide.json` and
   `testdata/support-search/cases.json` with the work. `./test.sh` fails if they drift apart.

## Publishing

Publish in batches, when a build ships or once a day, not after every commit: the Artifact tool has the publishing
session read the live page first (about 600 KB). The build says whether the page differs from the one published.

1. Artifact `read` the guide's address, save the page, and run `python3 tools/guide/split.py <saved page>`. No
   `git diff marketing/guide` means nobody changed the page outside the repository; otherwise commit what it brings
   in first.
2. `python3 tools/guide/build.py`, then Artifact publish `marketing/guide/build/feature-guide.html` with the guide's
   `url`.
3. `python3 tools/guide/build.py --published` and commit `manifest.json`.

A subagent on a smaller model can do these three steps, so the page never enters a feature session's context.
