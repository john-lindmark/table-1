# Import decks and cubes (2026-10-15)

New deck / New cube → **Import from a link or list**. Built on iOS (`ListImportView`, CardLists.swift), web (`screens/ListImport.tsx`, `/library/import/:kind`) and Android (`library/ListImport.kt`, route `collection/import/{kind}`).

## Server: `list-import` edge function

`POST { url } | { text }` with the user's JWT (verify_jwt on) → `{kind, name, format, source_url, entries: [{qty, board, name, set?, cn?, scryfall_id?, finish?}]}`, or `{error}` with 4xx/5xx.

| Source | How |
|---|---|
| Cube Cobra (`/cube/<page>/<id>`, `/c/<id>`) | `cube/api/cubejson/<id>`: mainboard → main, maybeboard → maybe; exact printing (`cardID` is the Scryfall id), foil/etched from `finish` |
| Archidekt (`/decks/<id>`) | `api/decks/<id>/`: categories Sideboard/Maybeboard/Commander, Scryfall `uid`, set + number, Foil/Etched modifier, format |
| MTGGoldfish (`/deck/<id>`) | `deck/download/<id>` text, parsed like a pasted list |
| Moxfield | Refused (Moxfield blocks other apps): "In Moxfield choose Export, copy the list as text and paste it here." |
| Any other public page (ManaBox, TappedOut, mtgdecks, melee.gg …) | Page fetched (no private/local hosts), stripped to text, read by Claude (`claude-opus-5-5`, effort low, strict `report_list` tool). 403 → "export it there and paste it here". |
| Pasted text | Parsed on the server (`parse.ts`): `4 Name`, `4x Name`, `(SET) 123` or `[SET] 123`, `*F*` / `*E*` / `(Foil)`, Moxfield `#tags` dropped, headers (Deck, Sideboard, Maybeboard, Considering, Commander, Companion, with `//` or `:`), `SB:` prefix, Arena `About / Name`, a blank line before the sideboard when there are no headers, and count-less one-per-line cube lists. |

## Clients

Each line resolves to a printing: `scryfall_id` if the catalog has it, else set + collector number (English first), else the card name's original paper printing (catalog contract `original`; front faces match double-faced cards). A finish carries over only when that printing comes in it. Cubes fold sideboard/commander lines into Main. Lines that match nothing are listed ("Not in the card data, left out: …"). The preview lets the player rename the list and pick its format (prefilled from the source), then **Create** calls `list_create` with the entries and the note `Imported from <host>` (or `Imported` for pasted text).
