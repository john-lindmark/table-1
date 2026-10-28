# Note to Cube Cobra: reading public cubes for a "Spice" score (draft, 2026-10-28)

Not sent. John sends it through whatever channel Cube Cobra uses for this (the contact link on cubecobra.com or their
Discord). Why: Cube Cobra's terms forbid "data mining, data harvesting, data extracting", so Table 1's cube Spice
(`contract/spice-2026-10-28.md`) has no cubes to compare with until they say yes. If they say yes, the weekly sync
that fills `t1_private.cube_corpus` gets built (ask for the request rate they want first). If they offer a data
export instead, use that.

---

Subject: Permission to read popular public cubes for a card-comparison feature

Hi,

I'm John Lindmark. I build Table 1 (table-1.site), a free tournament runner and collection app for Magic players.
Cube Cobra is what most of our cube players use, and we already open Cube Cobra links when someone imports a cube or
names one for an event.

We'd like to add a "Spice" score to cubes: how different a cube is from the cubes most like it. For example, "these 12
cards are in none of the 20 cubes closest to yours". To do that we need a set of comparison cubes. Your terms rule out
collecting data from the site, so I'm asking before we build anything.

What we'd like to do, if you're OK with it:

- Read the card lists of about 1,000 of the most-followed public cubes once a week, through the cube JSON your site
  already serves, at one request a second or slower (or whatever rate you prefer).
- Keep only each cube's name, its Cube Cobra id and its card list (card ids only). No owner names, descriptions, decks
  or anything else.
- Show the nearest cubes by name with a link back to each on Cube Cobra, and credit Cube Cobra wherever the score
  appears.
- Never resell or republish the lists, and remove any cube on request (or when it goes private).

If there's a data export or an API you'd rather we use, that works even better for us. And if the answer is no,
that's fine too: we'll compare cubes only with those Table 1 players share with each other.

Thanks for Cube Cobra. It's the reason cube is as easy to play as it is.

John Lindmark
Table 1 · table-1.site
