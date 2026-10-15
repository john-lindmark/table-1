Apply the following corrections to the existing Magic team event dashboard. These instructions replace any conflicting matchup-completion, button-disable, draw-scoring, and overtime-progress-bar behavior from earlier prompts.
1. Do not disable either player’s win button
Both players’ win-recording buttons must remain interactive regardless of the current score.
Do not disable the opposing player’s button when one player reaches 2 game wins.
Each player’s button independently cycles through:
0 → 1 → 2 → 0
Examples:
0–0
Click Player A → 1–0
Click Player A → 2–0
Click Player B → 2–1
Click Player B → 2–2
Click Player A → 0–2
Both buttons must remain available so the organizer can quickly correct or adjust a score without needing a separate edit mode.
The UI may highlight a likely winner or show the current matchup state, but it must never lock either score button.
2. Support all permitted matchup outcomes
An individual matchup may be recorded with any of the following outcomes:
	•	2–0
	•	2–1
	•	1–2
	•	0–2
	•	1–1
	•	1–0
	•	0–1
	•	0–0
Do not treat 1–1, 1–0, 0–1, or 0–0 as necessarily incomplete.
These may be valid final outcomes when time expires or when the organizer records the current match.
A score of 2–2 may appear temporarily while the organizer is editing the controls, but it must not be accepted as a finalized matchup outcome. Identify it as invalid and require the organizer to correct it before recording the round.
No player may have more than 2 game wins.
3. Determine the individual matchup result
Determine the result of each individual player matchup as follows.
Direct win
A player wins the individual matchup when that player has more game wins than the opponent.
Examples:
	•	2–0: Team A player wins
	•	2–1: Team A player wins
	•	1–0: Team A player wins
	•	0–1: Team B player wins
	•	1–2: Team B player wins
	•	0–2: Team B player wins
The winner’s team receives one matchup win.
Tied individual matchup
The individual matchup is tied when both players have the same number of game wins.
Supported tied outcomes include:
	•	0–0
	•	1–1
Do not automatically award both teams a draw or half point.
Instead, resolve the tied matchup based on the two teams’ records within that format during the current match or round.
The team with the better record in that format receives the matchup win for the tied individual matchup.
4. Resolve ties using the current format record
For each format and current round, calculate each team’s format record from the non-tied individual matchups in that format.
Example:
Modern pairings:

Pairing 1: Team A wins 2–0
Pairing 2: Team B wins 2–1
Pairing 3: 1–1 tie
Pairing 4: Team A wins 1–0
Before resolving the tie:
Team A format record: 2 matchup wins
Team B format record: 1 matchup win
The 1–1 tied pairing is therefore awarded to Team A because Team A has the better record in Modern for that round.
After resolving the tie:
Team A format record: 3 matchup wins
Team B format record: 1 matchup win
Apply the same logic to 0–0 tied outcomes.
Equal format records
When an individual matchup is tied and the teams also have equal records in that format, do not arbitrarily award the matchup.
Mark the tied matchup as requiring resolution.
Before the round can be recorded, prompt the organizer to select which team receives the matchup win.
Present a clear control such as:
	•	Award to Team A
	•	Award to Team B
Store this as a tie-resolution decision rather than changing the visible game score.
The visible score must remain 0–0 or 1–1.
5. Avoid circular tie calculations
Calculate format records in this order:
	1	Count all individual matchups with unequal game-win scores.
	2	Compare the teams’ records from those decisive matchups.
	3	Award tied matchups to the team with the better decisive record in that format.
	4	When the decisive records are equal, require manual organizer resolution.
Do not use already resolved tied matchups to determine which team initially had the better record. This prevents circular scoring.
If a format contains only tied matchups, every tied matchup requires manual resolution because neither team has a better decisive record.
6. Update the pairing data model
Update each pairing to store:
	•	team_a_game_wins integer default 0
	•	team_b_game_wins integer default 0
	•	result_status text
	•	winning_team_id uuid nullable
	•	resolution_method text nullable
	•	tie_resolution_team_id uuid nullable
	•	is_recorded boolean default false
Suggested result statuses:
	•	not_started
	•	in_progress
	•	decisive
	•	tied
	•	requires_resolution
	•	resolved
	•	invalid
Suggested resolution methods:
	•	game_score
	•	better_format_record
	•	organizer_decision
Apply these rules:
	•	0–0 is a tied result when the round is being finalized.
	•	1–1 is a tied result.
	•	Unequal scores are decisive.
	•	2–2 is invalid.
	•	winning_team_id is set directly for unequal scores.
	•	For tied scores, winning_team_id is determined by the format-record rule.
	•	When format records are equal, winning_team_id remains null until the organizer resolves the tie.
	•	Manual resolution is stored in tie_resolution_team_id.
	•	Do not alter the underlying tied game score when resolving the team matchup winner.
7. Score-bar behavior
The Total Recorded Match Wins bar counts individual matchup wins, not game wins.
Each pairing contributes exactly one matchup win to one team once its winner has been determined.
Examples:
	•	2–0 contributes 1 win.
	•	2–1 contributes 1 win.
	•	1–0 contributes 1 win.
	•	0–1 contributes 1 win.
	•	A resolved 1–1 tie contributes 1 win to the team with the better format record.
	•	A manually resolved 0–0 tie contributes 1 win to the selected team.
	•	An unresolved tied matchup contributes no pending win until its winner is determined.
	•	A 2–2 invalid score contributes no win.
Pending totals should include all current-round pairings that have a determined winning team, including tied pairings resolved through the format-record rule or an organizer decision.
8. Round-finalization validation
Allow the round to be recorded when every pairing has a valid outcome and a determined winning team.
Valid finalized scores include:
	•	2–0
	•	2–1
	•	1–2
	•	0–2
	•	1–0
	•	0–1
	•	1–1 with a resolved winning team
	•	0–0 with a resolved winning team
Prevent round finalization when:
	•	A pairing has a 2–2 score.
	•	A tied pairing still requires organizer resolution.
	•	Any game-win value is outside the range of 0 through 2.
	•	A score update is still saving or has failed to persist.
Before recording, show a review of tied matchups and how each one was resolved.
For example:
1–1 — awarded to Team A based on the better Modern record
0–0 — awarded to Team B by organizer decision
9. Win-button component behavior
Continue using the uploaded light-mode Figma win-recording components.
Respect all existing component properties and variants, including:
	•	Default
	•	Hover
	•	Pressed
	•	Focus
	•	Selected
	•	Saving
	•	Error
Do not use a disabled variant based on the other player reaching 2 wins.
The button may only be temporarily non-interactive while its own score update is being submitted, if necessary to prevent duplicate requests. This saving state should be extremely brief and should not visually imply that the opposing player has already won.
Persist each change to Supabase and synchronize it through Realtime.
10. Overtime progress-bar treatment
The bottom bar remains a full-width progress visualization for the configured match duration.
At the start of a 50-minute match:
	•	The bar is full.
	•	It uses its normal progress color.
As time counts down:
	•	The bar gradually empties.
At exactly 00:00:
	•	The bar is empty.
When the timer becomes negative:
	•	Keep the progress fill empty.
	•	Change the progress bar to the design system’s error color.
	•	Apply the error color to the bar track, border, glow, or other visible bar treatment.
	•	The entire overtime bar treatment should clearly indicate that the match is over time.
	•	Do not refill or reverse the progress bar.
	•	Do not place content inside the bar.
The large timer number must also use the error color while in overtime.
When the timer is reset or set back to a positive value, restore the normal progress-bar treatment.
11. Supabase calculation requirements
Implement the tie-resolution and scoring logic in the backend or in an authoritative database function rather than relying only on client-side calculations.
Create or update a function such as:
calculate_round_pairing_results(round_id)
It should:
	1	Group pairings by format.
	2	Calculate decisive matchup wins for each team.
	3	Identify 0–0 and 1–1 tied matchups.
	4	Resolve tied matchups for the team with the better decisive format record.
	5	Leave tied matchups unresolved when the decisive format records are equal.
	6	Apply any explicit organizer resolutions.
	7	Reject 2–2 scores as invalid.
	8	Return the determined winner and resolution method for every pairing.
	9	Return the current pending team totals.
	10	Avoid changing recorded historical results unless explicitly invoked as part of a correction workflow.
Call this calculation after score changes and before finalizing a round.
Treat Supabase as the source of truth for the final team totals and resolution methods.
12. Updated acceptance criteria
The correction is complete when:
	•	Neither player’s button becomes disabled because the other player reached 2 wins.
	•	Each button cycles independently through 0, 1, 2, and back to 0.
	•	1–0, 0–1, 1–1, and 0–0 can be recorded as final outcomes.
	•	Unequal scores award one matchup win to the player with more game wins.
	•	Tied scores are awarded to the team with the better decisive record in that format for the current round.
	•	Tied scores require organizer resolution when the decisive format records are equal.
	•	The visible tied score remains unchanged after resolution.
	•	2–2 is identified as invalid and prevents round finalization.
	•	The score bar counts matchup wins rather than individual game wins.
	•	Tie-resolution decisions persist in Supabase.
	•	The bottom progress bar becomes the error color during overtime.
	•	The overtime bar stays empty and does not refill.
	•	The large timer also uses the error color during overtime.

13. Completed event results dashboard
When all configured rounds have been recorded, replace the live event dashboard with a completed-event results dashboard.
Do not continue showing the live matchup-entry interface as the primary view once the event is complete.
Winning team treatment
Display the winning team prominently at the top of the completed dashboard.
Use large celebratory text such as:
Team Fire Wins
Also display:
	•	Final matchup-win total for each team
	•	Winning margin
	•	Event name
	•	Completed status
	•	Completion date and time
The winning-team announcement should be the most visually prominent element on the screen.
If the teams finish with equal final totals, show:
Event Ends in a Tie
Do not arbitrarily select a winner when the final team totals are equal.
Final score summary
Show a large final-score presentation directly beneath the winning-team announcement.
Example:
Team Fire 24 — 18 Team Ice
Clearly distinguish:
	•	Winning team
	•	Losing team
	•	Final recorded matchup wins
	•	Overall event result
Use the configured team names and team visual identifiers.
Results from all rounds
Show the results from every recorded round in chronological order.
For each round, display:
	•	Round number
	•	Final team score for that round
	•	Winning team for the round
	•	Timer status when the round was recorded, including whether it ended in overtime
	•	Results grouped by format
	•	Every individual player matchup
	•	Final game-win score for each matchup
	•	Team that received the matchup win
	•	Tie-resolution method, when applicable
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
	•	Round number
	•	Team matchup-win totals
	•	Round winner
	•	Number of formats
	•	Number of tied matchups
	•	Overtime indicator, when applicable
The expanded state should show the complete format and pairing breakdown.
Automatically expand the final round when the results dashboard first loads.
Format-level results
Within each round, group pairings by format.
For each format, show:
	•	Format name
	•	Team A matchup wins
	•	Team B matchup wins
	•	Format winner
	•	Number of tied matchups
	•	Any organizer-resolved matchups
Example:
Modern
Team Fire 3 — 1 Team Ice
Format winner: Team Fire
If the teams have equal matchup wins in a format, label it as a tied format.
Event-level format summary
Include an aggregate summary showing performance across the full event for each format.
For every format, display:
	•	Total matchup wins by team across all rounds
	•	Number of rounds won by each team in that format
	•	Total tied matchups
	•	Overall format winner
This should help organizers understand which team performed better in each format across the entire event.
Navigation and actions
The completed dashboard should provide:
	•	View all round results
	•	Expand or collapse all rounds
	•	Return to Past Events
	•	Open event-management settings
	•	Export or print results, when supported
	•	Start a new event
	•	Archive event
Do not show active score-entry controls on the completed dashboard.
Owners and organizers may enter an explicit correction mode from event management. After a historical result is corrected:
	•	Recalculate all affected round totals.
	•	Recalculate format summaries.
	•	Recalculate final team totals.
	•	Update the winning-team announcement.
	•	Preserve the audit history.
Supabase requirements
Persist the completed event state in Supabase.
When the final round is recorded:
	•	Set the event status to completed.
	•	Set completed_at using database time.
	•	Preserve all round, pairing, timer, and tie-resolution records.
	•	Recalculate final team totals from recorded pairings.
	•	Return the completed-event result from the round-finalization database function.
	•	Synchronize all connected clients to the completed dashboard through Supabase Realtime.
Do not store the winning team as an independently editable value.
Derive the winning team from the final recorded matchup-win totals so historical corrections automatically update the result.
Create or update a completed-event query or view that returns:
	•	Event
	•	Teams
	•	Final totals
	•	Winning team, when one exists
	•	All rounds
	•	Round totals
	•	Format totals
	•	Pairing results
	•	Tie-resolution methods
	•	Overtime status
	•	Audit history
Completed dashboard acceptance criteria
The completed-event experience is correct when:
	•	Recording the final round automatically opens the completed results dashboard.
	•	The winning team appears in large text.
	•	A tied event is clearly labeled as a tie.
	•	Final team totals are prominently displayed.
	•	Results from every round are available.
	•	Every round can be expanded to show format and matchup details.
	•	Tied matchups show how they were resolved.
	•	Overtime rounds are visibly identified.
	•	No active matchup-entry controls appear.
	•	Corrections automatically update round totals, format totals, final totals, and the winning-team announcement.
	•	All completed-event data reloads correctly after refresh.
	•	Connected devices transition to the completed dashboard at the same time.
