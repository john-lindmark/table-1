# Filings: company, trademark, copyright, DMCA agent

Step-by-step for the four things only John can file. Fees are from memory as of late 2026 and change: check each
office's fee page before paying. A startup or IP lawyer can do all of this in one engagement; the notes say where
doing it yourself is reasonable.

## 1. Form the company (first: everything else is filed in its name)

Why: it separates personal assets from the product's liabilities (events, user uploads, affiliate income), and gives
one owner for the IP, accounts and contracts.

1. **Pick the state.** Default: the state you live in. A Delaware or Wyoming LLC run from another state usually has
   to register in the home state too, so it costs more without helping a one-person company. Delaware matters only
   if you plan to raise venture money (then a C-corp, later).
2. **Pick the name.** "Table 1 LLC" may be taken or confusing next to Table 1 Vegas LLC (see the audit § 4). A
   neutral holding name ("Lindmark Games LLC") that owns the Table 1 brand avoids the question.
3. File Articles of Organization with the state (online, $50–$500 depending on state; some have an annual fee).
4. Get an EIN at irs.gov (free, ten minutes).
5. Sign a single-member **operating agreement** (a short template is fine).
6. Open a business bank account; route Impact/TCGplayer payouts, Apple and Google there.
7. **Assign the IP to the company.** Sign `templates/ip-assignment.md` as John → the LLC, covering everything made
   before the company existed: code, designs, the name and logo, the domain, the data. Without this the LLC owns
   nothing.
8. **Move the accounts** to the company: Apple Developer (convert Individual → Organization; needs a D-U-N-S number,
   free, takes a week or two), Google Play (organization account), domain registrar, Supabase, Cloudflare, GitHub
   (an organization that owns the repo), Sentry, PostHog, Impact, Discord application, Resend, Anthropic.
9. Update `OWNER` in `table-1-events-web/src/lib/legal.ts`, the `LICENSE`, the privacy policy's "run by", and the
   store listings' seller name.

## 2. Trademark

What to file (in the company's name, after step 1):

| Filing | Mark | Classes | Notes |
|---|---|---|---|
| A (first) | The **T1 logo** (design mark) | 9, 42 | Strongest and least contested. |
| B | **TABLE 1** (standard characters) | 9, 42 | Get a lawyer's view on the live class 41 poker registration first (audit § 4). |
| C (maybe) | TABLE 1 | 41 (organizing game tournaments) | Most exposed to the poker mark. Lawyer's call. |

- Class 9: downloadable mobile applications for organizing and running trading card game tournaments, tracking game
  scores, and cataloging trading card collections.
- Class 42: providing online non-downloadable software for the same.
- Basis: **use in commerce** (1(a)). First use: the date the first TestFlight/public web build reached real users;
  specimens are an App Store / Play listing or the site showing the mark with a way to get the software.
- Fee: about $350 per class per mark at the USPTO. A lawyer's clearance + filing typically runs $1,000–$2,000 per
  mark. Timeline: roughly 12–14 months to registration; you can use ™ now and ® only after registration.
- Descriptiveness: an examiner may say "table 1" describes tournament software (the top table). Arguments: it
  doesn't describe what the software does; worst case the logo registers and the words go on the Supplemental
  Register until five years of use.
- Outside the US: file through the Madrid Protocol within six months of the US filing to keep its date (EU, UK,
  Canada, Australia are where competitive Magic is).
- While waiting: use "Table 1™" consistently, keep dated screenshots of the mark in use, hold the domain, the store
  names and the social handles (@table_1_mtg exists).
- Never register or use anything of Wizards' (names, mana symbols) as part of our mark.

## 3. Copyright registration

Registration isn't needed to own copyright, but it is needed to sue in the US, and registering **before** an
infringement (or within three months of publication) is what unlocks statutory damages and legal fees.

File at copyright.gov (eCO). $65 per work ($45 if one author, one work, not for hire).

| Work | Type | Why |
|---|---|---|
| 1. The T1 logo and app icon | Visual art | Fully human-made; cleanest registration. |
| 2. The screen designs John drew in Figma (life tracker, Collection home, card detail, Account, tab bar) | Visual art (a collection of unpublished or published works) | Human-authored; this is the "look" a cloner would copy. |
| 3. Table 1 software, version 0.1.0 | Literary work → computer program | See the AI note below. |

Software specifics:
- Deposit: the first 25 and last 25 pages of source for one version; trade-secret portions may be blacked out.
- **AI disclosure is required.** The Office registers only human authorship. In the application, describe the
  human contribution (for example "selection, coordination and arrangement of the program; design of the system;
  portions of text written and revised by the author") and exclude AI-generated material under "Material excluded".
  Leaving it out can void the registration. Expect a narrow registration; that is honest and still useful against
  wholesale copying.
- Publication date: the first public release date; nation: United States.
- Re-register major versions if they add a lot (each is a new work based on the last).

## 4. DMCA agent (20 minutes, $6)

Users upload photos, avatars and names. To keep the safe harbor for what they upload:
1. Register a designated agent at dmca.copyright.gov (in the company's name; renew every three years).
2. Name the same contact in the Terms' "Copyright complaints" section (it uses privacy@table-1.site now; a
   dedicated copyright@ address is tidier).
3. Act on valid notices quickly and close repeat infringers' accounts (the moderation tools already do the removal).

## 5. What to ask a lawyer (one meeting)

1. Review the Terms and Privacy drafts at table-1.site/terms and /privacy; name the governing state.
2. Trademark clearance for TABLE 1 against Table 1 Vegas LLC; which filings to make.
3. The Wizards Fan Content Policy questions in the audit § 3 (accounts, charging, affiliate income).
4. Magic Online page reading and the Melee cache: keep, ask permission, or drop.
5. How to word the copyright application given AI-assisted code.
6. Any state-specific LLC points.
