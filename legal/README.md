# Protecting Table 1

Started 2026-11-09. Drafts and checklists, not legal advice; a lawyer should review the Terms, the trademark
question and the third-party questions before anything here is treated as settled.

- `audit-2026-11-09.md`: what was found in the repo and the products, what is secret and where it lives, every
  third-party source and its terms, and the trademark knockout search.
- `filings.md`: forming the company, trademark, copyright registration, DMCA agent, and the questions for a lawyer.
- `templates/ip-assignment.md`, `templates/nda.md`: to sign with the company and with anyone who helps.
- `../LICENSE`: proprietary, all rights reserved.
- Terms of Service and the privacy policy live in `table-1-events-web/src/screens/Legal.tsx` (`/terms`, `/privacy`);
  the owner's name and the affiliate note are in `table-1-events-web/src/lib/legal.ts`.

## Order of work

| # | Step | Who | Status |
|---|---|---|---|
| 1 | Make the GitHub repo private; turn on 2FA everywhere | John (one click / `gh repo edit`) | **Open** |
| 2 | `LICENSE`, © lines | done | Done 2026-11-09 |
| 3 | Terms of Service drafted and linked on the web; About row in the apps | done | Draft; not deployed |
| 4 | Sign-in line ("Continuing agrees to the Terms and Privacy policy") in the iOS and Android apps | Claude | To do |
| 5 | Affiliate note on the apps' Buy screens | Claude | To do |
| 6 | Art credit wherever an art crop is the subject; no T1 mark on art in the Card icon widget (Scryfall's image rules) | John decides, Claude builds | Open |
| 7 | Acknowledgements page for open-source notices | Claude | To do |
| 8 | Form the company, assign the IP, move the accounts | John | `filings.md` § 1 |
| 9 | Lawyer meeting: Terms, trademark vs. Table 1 Vegas LLC, Wizards policy, Magic Online / Melee sources | John | `filings.md` § 5 |
| 10 | File the T1 logo (classes 9, 42), then TABLE 1 as advised | John / lawyer | After 8 and 9 |
| 11 | Register copyrights: logo, Figma screens, software 0.1.0 | John | After 8 |
| 12 | Register a DMCA agent | John | After 8 |
| 13 | Send the Melee and Cube Cobra requests already drafted in `table-1-context/docs/` | John | Open |

## What is and isn't protectable

| Asset | Protection | Strength |
|---|---|---|
| Name and logo | Trademark | Strong once registered; logo first |
| Figma designs, icon, marketing art | Copyright | Strong (human-made) |
| Code | Copyright (thin: AI-assisted) + secrecy for server code + Terms | Medium |
| Archetype rules, meta database, scan set, moderation policy | Trade secret (needs the private repo) + Terms | Medium–strong |
| Features, flows, tournament logic as ideas | Nothing | None |
| Users, organizers, history | Not law: the actual moat | — |
