# Note to Melee: read access to public results for Insights (draft, 2026-10-28)

Not sent. John sends it to contact@melee.gg. Why: Melee's API is only for organizations and staff they clear
(help.melee.gg/?p=11549: a third party needs Coverage Staff clearance on each organization plus the owner's emailed
OK), so Insights (`contract/insights-2026-10-24.md`) has no paper data beyond TopDeck.gg. This asks for read access
outside that route. If they say yes, add Melee as a `meta-sync` source next to TopDeck (ask what the API returns and
the rate they want first; events go into the same tiers, `meta_matches` from round results, decks as Oracle ids, no
names). If they point us to organizers instead, the big ones to ask are those running RCs and large opens on Melee.

---

Subject: Read-only API access to public results for a free metagame feature

Hi,

I'm John Lindmark. I build Table 1 (table-1.site), a free app for Magic players: a tournament runner for store,
cube and team draft nights, plus collection tools. We aren't trying to run competitive Constructed events; that's
what Melee is for.

Table 1 has a free Insights section that shows Constructed metagames: archetype shares over time, win rates,
matchups, how a format settles after a ban. Today it reads MTGO's published decklists and TopDeck.gg's API. The
biggest gap is paper events, and most of the large ones run on Melee. Your help page says API access is for
organizations and the staff they clear, so I'm asking whether a read-only arrangement for public results is
possible.

What we'd like to read, for finished events only, and only what Melee already shows publicly:

- Event name, date, format and player count.
- Final standings (place, match record) and round results (who beat whom, game scores).
- Decklists once the organizer has made them public.

How we'd handle it:

- No player names anywhere in Table 1. We keep only a salted hash to tell decks apart, and nothing else about the
  players.
- Credit Melee with a link wherever its results appear, and link each event back to its page on Melee.
- Insights stays free. We never resell or republish the raw data, only aggregates (shares, rates, card counts).
- Read at whatever rate you set; we can poll for finished events once an hour, plus a one-time read of the past
  year.
- Leave out any event or organizer on request.

If it's simpler for you to grant this per organizer, or there's a data export you'd rather we use, that works too,
and if the answer is no, that's fine.

Thanks for Melee. It's where the big paper events live now.

John Lindmark
Table 1 · table-1.site
