Table 1 0.1.0 (60) — What to Test

On top of build 59 (everything in 59's notes, plus):

LIMITED CARDS WIDGET: TAP TO SWITCH
- The widget's top line is three small buttons: Set, Rarity and Color. Tap one to move to the next choice (Set goes through the Limited sets; Rarity Any → Common → Uncommon → Rare → Mythic → Any; Color Any → W → U → B → R → G → Multi → Colorless → Any). The cards change straight away.
- Tap anywhere else on the widget: Insights → Limited opens on that set with the widget's sort, rarity and color already picked.
- Edit Widget still sets the starting point; editing it starts the buttons over.

Send anything odd through TestFlight feedback (screenshot + shake).

---
Build notes (not for testers): archived 2026-11-10 at 4974e05 from a clean worktree (version 0.1.0, build 60, Release, automatic signing with the App Store Connect API key; archive "Table 1 10-11-2026, 12.09"; dSYMs uploaded to Sentry by the post-action). Uploaded from the command line with the API key ("Upload succeeded"); registered with `bugs.py shipped ios 60 --commit 4974e05`. The only app change since build 59 (99277b5) is ae87159 (Limited cards widget tap buttons and the body tap carrying the picks; 448 unit tests passed at ae87159); 6cba130 refreshed the bundled Support files. No server change. Not yet tried on a phone.
