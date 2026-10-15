13. Completed event results dashboard

When all configured rounds have been recorded, replace the live event dashboard with a completed-event results dashboard.

Do not continue showing the live matchup-entry interface as the primary view once the event is complete.

Winning team treatment

Display the winning team prominently at the top of the completed dashboard.

Use large celebratory text such as:

Team Fire Wins

Also display:

* Final matchup-win total for each team
* Winning margin
* Event name
* Completed status
* Completion date and time

The winning-team announcement should be the most visually prominent element on the screen.

If the teams finish with equal final totals, show:

Event Ends in a Tie

Do not arbitrarily select a winner when the final team totals are equal.

Final score summary

Show a large final-score presentation directly beneath the winning-team announcement.

Example:

Team Fire 24 — 18 Team Ice

Clearly distinguish:

* Winning team
* Losing team
* Final recorded matchup wins
* Overall event result

Use the configured team names and team visual identifiers.

Results from all rounds

Show the results from every recorded round in chronological order.

For each round, display:

* Round number
* Final team score for that round
* Winning team for the round
* Timer status when the round was recorded, including whether it ended in overtime
* Results grouped by format
* Every individual player matchup
* Final game-win score for each matchup
* Team that received the matchup win
* Tie-resolution method, when applicable

Example individual result:

Alex 2–1 Jordan
Matchup win: Team Fire

Example tied result:

Morgan 1–1 Taylor
Matchup win: Team Ice
Resolved by better Legacy record

Example manually resolved result:

Casey 0–0 Riley
Matchup win: Team Fire
Resolved by organizer decision

Round summary cards

Represent each round with an expandable summary card.

The collapsed state should show:

* Round number
* Team matchup-win totals
* Round winner
* Number of formats
* Number of tied matchups
* Overtime indicator, when applicable

The expanded state should show the complete format and pairing breakdown.

Automatically expand the final round when the results dashboard first loads.

Format-level results

Within each round, group pairings by format.

For each format, show:

* Format name
* Team A matchup wins
* Team B matchup wins
* Format winner
* Number of tied matchups
* Any organizer-resolved matchups

Example:

Modern
Team Fire 3 — 1 Team Ice
Format winner: Team Fire

If the teams have equal matchup wins in a format, label it as a tied format.

Event-level format summary

Include an aggregate summary showing performance across the full event for each format.

For every format, display:

* Total matchup wins by team across all rounds
* Number of rounds won by each team in that format
* Total tied matchups
* Overall format winner

This should help organizers understand which team performed better in each format across the entire event.

Navigation and actions

The completed dashboard should provide:

* View all round results
* Expand or collapse all rounds
* Return to Past Events
* Open event-management settings
* Export or print results, when supported
* Start a new event
* Archive event

Do not show active score-entry controls on the completed dashboard.

Owners and organizers may enter an explicit correction mode from event management. After a historical result is corrected:

* Recalculate all affected round totals.
* Recalculate format summaries.
* Recalculate final team totals.
* Update the winning-team announcement.
* Preserve the audit history.

Supabase requirements

Persist the completed event state in Supabase.

When the final round is recorded:

* Set the event status to completed.
* Set completed_at using database time.
* Preserve all round, pairing, timer, and tie-resolution records.
* Recalculate final team totals from recorded pairings.
* Return the completed-event result from the round-finalization database function.
* Synchronize all connected clients to the completed dashboard through Supabase Realtime.

Do not store the winning team as an independently editable value.

Derive the winning team from the final recorded matchup-win totals so historical corrections automatically update the result.

Create or update a completed-event query or view that returns:

* Event
* Teams
* Final totals
* Winning team, when one exists
* All rounds
* Round totals
* Format totals
* Pairing results
* Tie-resolution methods
* Overtime status
* Audit history

Completed dashboard acceptance criteria

The completed-event experience is correct when:

* Recording the final round automatically opens the completed results dashboard.
* The winning team appears in large text.
* A tied event is clearly labeled as a tie.
* Final team totals are prominently displayed.
* Results from every round are available.
* Every round can be expanded to show format and matchup details.
* Tied matchups show how they were resolved.
* Overtime rounds are visibly identified.
* No active matchup-entry controls appear.
* Corrections automatically update round totals, format totals, final totals, and the winning-team announcement.
* All completed-event data reloads correctly after refresh.
* Connected devices transition to the completed dashboard at the same time.