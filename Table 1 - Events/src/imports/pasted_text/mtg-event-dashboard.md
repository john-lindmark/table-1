Design and build a responsive dashboard for running and recording large team-based Magic: The Gathering events.

Build this as a functional application connected to a Supabase backend. Do not use static mock data except as an optional development fallback. Event configuration, rosters, pairings, timer state, matchup results, event history, and score corrections must persist in Supabase.

Product goal

The dashboard should help an event organizer:

* Configure a new team event
* Run the current timed match or round
* Record individual matchup results
* Track each team’s cumulative match wins
* Correct previously recorded results
* Review past events

Optimize the primary dashboard for rapid, low-error use during a live tournament. It should be easy to operate on a laptop or tablet from several feet away.

Technology requirements

Use:

* React and TypeScript
* Supabase JavaScript client
* Supabase Postgres database
* Supabase Authentication
* Supabase Realtime
* Postgres Row Level Security
* Postgres database functions for multi-record operations
* Environment variables for Supabase configuration

Use these environment variables:

VITE_SUPABASE_URL
VITE_SUPABASE_ANON_KEY

Initialize the Supabase client in a reusable module.

Never place the Supabase service-role key in the browser or client-side code.

Provide clear loading, empty, offline, saving, saved, and error states for all database interactions.

Authentication and access

Require organizers to sign in before creating or modifying events.

Support:

* Email magic-link authentication
* Email and password authentication if easily supported
* Persistent authenticated sessions
* Sign out
* Auth-loading state
* Friendly authentication error messages

An authenticated user can:

* Create an event
* Own an event
* Invite or add other authenticated organizers
* Edit events for which they have organizer access
* View their own past events

Support these event roles:

* Owner
* Organizer
* Viewer

Permissions:

* Owners can edit the event, manage organizers, archive the event, and delete draft events.
* Organizers can run the event, record results, change the timer, and correct results.
* Viewers can see the event dashboard and history but cannot make changes.

For the initial prototype, provide a simple organizer-management interface using authenticated user email addresses.

Event structure

An event supports:

* Up to 6 formats
* 2 teams by default
* A configurable number of teams in the data model
* A configurable number of players assigned to each format for each team
* A configurable number of matches or rounds
* Round Robin or Swiss matchup generation
* A configurable timer duration
* Optional draws

The primary live-event experience should initially optimize for two-team events.

Each format is its own competition group. Players may only be paired with opponents assigned to the same format.

Round Robin matchup logic

For each format, every player on one team plays every player from the opposing team assigned to that format.

Examples:

* 3 players versus 3 players creates 9 total pairings
* 4 players versus 4 players creates 16 total pairings

Distribute pairings across the configured matches or rounds without repeating a pairing until all possible pairings have been used.

Swiss matchup logic

For each format, assign each player an opponent from the opposing team for the current match.

* Randomize initial pairings.
* Avoid repeat pairings when possible.
* Never pair players across formats.
* Make pairings visible before the match begins.
* Allow an organizer to regenerate pairings before any results have been recorded.
* Persist the generated pairings so all connected devices see the same pairings.
* Do not regenerate pairings solely because the page refreshes.

Supabase database schema

Create the following Postgres tables. Use UUID primary keys generated with gen_random_uuid() unless otherwise noted.

All tables should include appropriate foreign keys, indexes, constraints, and timestamps.

profiles

Represents authenticated users.

Fields:

* id uuid primary key references auth.users(id)
* display_name text
* email text
* created_at timestamptz default now()
* updated_at timestamptz default now()

Create a profile automatically when a new authenticated user is created.

events

Fields:

* id uuid primary key
* owner_id uuid references profiles(id)
* name text not null
* status text not null
* matchup_method text not null
* number_of_rounds integer not null
* current_round_number integer default 1
* default_timer_seconds integer default 3000
* draws_allowed boolean default false
* started_at timestamptz
* completed_at timestamptz
* archived_at timestamptz
* created_at timestamptz default now()
* updated_at timestamptz default now()

Allowed event statuses:

* draft
* ready
* in_progress
* paused
* completed
* archived

Allowed matchup methods:

* round_robin
* swiss

Add constraints:

* Event name cannot be blank.
* Number of rounds must be at least 1.
* Default timer must be greater than 0.
* Current round number must be at least 1.

event_members

Connects authenticated users to events.

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* user_id uuid references profiles(id) on delete cascade
* role text not null
* created_at timestamptz default now()

Allowed roles:

* owner
* organizer
* viewer

Add a unique constraint on:

* event_id
* user_id

teams

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* name text not null
* color text
* display_order integer not null
* created_at timestamptz default now()
* updated_at timestamptz default now()

Team names must be unique within an event.

formats

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* name text not null
* display_order integer not null
* created_at timestamptz default now()
* updated_at timestamptz default now()

An event may contain no more than six active formats.

Format names must be unique within an event.

players

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* team_id uuid references teams(id) on delete cascade
* format_id uuid references formats(id) on delete cascade
* name text not null
* display_order integer not null
* is_active boolean default true
* created_at timestamptz default now()
* updated_at timestamptz default now()

A player belongs to one team and one format within an event.

rounds

Use “round” as the database term even if the interface labels it “Match.”

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* round_number integer not null
* status text not null
* started_at timestamptz
* recorded_at timestamptz
* recorded_by uuid references profiles(id)
* created_at timestamptz default now()
* updated_at timestamptz default now()

Allowed round statuses:

* pending
* active
* paused
* recorded

Add a unique constraint on:

* event_id
* round_number

pairings

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* round_id uuid references rounds(id) on delete cascade
* format_id uuid references formats(id) on delete cascade
* team_a_player_id uuid references players(id)
* team_b_player_id uuid references players(id)
* result text
* winning_team_id uuid references teams(id)
* is_draw boolean default false
* recorded_at timestamptz
* recorded_by uuid references profiles(id)
* created_at timestamptz default now()
* updated_at timestamptz default now()

Allowed pairing results:

* pending
* team_a_win
* team_b_win
* draw

Rules:

* Both players must belong to the same format.
* Players must belong to different teams.
* winning_team_id must be null for pending results and draws.
* winning_team_id must match the winning player’s team for a win.
* A pairing result can be edited until the event is archived.
* Pairings must not be duplicated within the same round.

timer_states

Store one authoritative timer record per event.

Fields:

* event_id uuid primary key references events(id) on delete cascade
* round_id uuid references rounds(id) on delete cascade
* duration_seconds integer not null default 3000
* remaining_seconds_at_change integer not null default 3000
* timer_status text not null default 'paused'
* last_started_at timestamptz
* updated_by uuid references profiles(id)
* updated_at timestamptz default now()

Allowed timer statuses:

* paused
* running
* completed

Do not write to the database every second.

Calculate the visible timer locally using:

* remaining_seconds_at_change
* last_started_at
* The current time
* timer_status

When running:

displayed remaining seconds =
remaining_seconds_at_change -
seconds elapsed since last_started_at

Allow the value to become negative after zero.

When pausing:

* Calculate the current remaining value.
* Save that value to remaining_seconds_at_change.
* Set timer_status to paused.
* Set last_started_at to null.

When resuming:

* Preserve remaining_seconds_at_change.
* Set timer_status to running.
* Set last_started_at to the current server time.

When resetting for a new round:

* Set remaining_seconds_at_change to the event’s default timer.
* Set timer_status to paused.
* Set last_started_at to null.
* Associate the timer with the new round.

result_audit_log

Store every change to a recorded pairing.

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* round_id uuid references rounds(id) on delete cascade
* pairing_id uuid references pairings(id) on delete cascade
* changed_by uuid references profiles(id)
* previous_result text
* new_result text
* previous_winning_team_id uuid references teams(id)
* new_winning_team_id uuid references teams(id)
* reason text
* created_at timestamptz default now()

Audit records must be append-only.

event_activity

Store significant event actions.

Fields:

* id uuid primary key
* event_id uuid references events(id) on delete cascade
* user_id uuid references profiles(id)
* action_type text not null
* metadata jsonb default '{}'::jsonb
* created_at timestamptz default now()

Example action types:

* event_created
* event_started
* pairings_generated
* round_recorded
* result_corrected
* timer_changed
* event_completed
* event_archived

Score calculation

Do not store a manually editable cumulative score on the team record.

Calculate team scores from pairing results so corrections cannot leave stored totals out of sync.

Create a database view named event_team_scores.

For each team and event, return:

* team_id
* event_id
* recorded_wins
* pending_wins
* displayed_total_wins

Definitions:

Recorded wins

Count pairings where:

* The pairing belongs to a round with status recorded.
* The team is the winning team.

Pending wins

Count pairings where:

* The pairing belongs to the current active or paused round.
* A winner has been selected.
* The round has not yet been recorded.
* The team is the selected winning team.

Displayed total wins

recorded_wins + pending_wins

Draws do not add a team win unless a future scoring configuration explicitly changes this rule.

Use the score view to populate the “Total Recorded Match Wins” bar.

Database functions

Use Postgres functions for operations that must be atomic.

Do not finalize a round through multiple independent client-side inserts and updates.

create_event_with_configuration

Create a function or Edge Function that accepts the complete event configuration as JSON.

It should create, in a single operation:

* Event
* Owner membership
* Teams
* Formats
* Players
* Round records
* Initial pairings
* Initial timer state
* Event activity record

If any required insert fails, roll back the entire operation.

Return:

* Created event ID
* Validation errors, when applicable

generate_round_pairings

Create a function that:

* Accepts an event ID and round ID.
* Validates that the caller is an owner or organizer.
* Reads the event matchup method.
* Generates valid pairings by format.
* Avoids duplicate historical pairings where possible.
* Saves the generated pairings.
* Returns the generated pairing records.

For Swiss pairings, perform the randomization in the database function or Edge Function and persist the results.

Do not rely on each client independently generating random pairings.

record_round_and_advance

Create a database function that atomically:

1. Confirms that the caller has edit access.
2. Confirms that the supplied round is the event’s current round.
3. Confirms that all required pairings have results.
4. Marks the current round as recorded.
5. Sets recorded_at and recorded_by.
6. Writes an event activity record.
7. Determines whether another round exists.
8. If another round exists:
    * Advances current_round_number.
    * Activates the next round.
    * Generates its pairings if they do not already exist.
    * Resets the timer to the default duration.
    * Leaves the timer paused.
9. If no round remains:
    * Marks the event completed.
    * Sets completed_at.
    * Marks the timer completed.
10. Returns the updated event, current round, timer, scores, and next pairings.

The entire operation must succeed or fail as one transaction.

Make repeated calls safe. Do not record the same round twice.

correct_pairing_result

Create a database function that:

1. Confirms that the caller is an owner or organizer.
2. Reads and locks the current pairing record.
3. Validates the new result.
4. Writes the previous and new values to result_audit_log.
5. Updates the pairing result.
6. Writes a result_corrected event activity record.
7. Returns recalculated team scores.

Require a correction reason when editing a pairing from a recorded round.

update_event_timer

Create a database function that:

* Confirms that the caller is an owner or organizer.
* Accepts an event ID, timer action, and optional seconds.
* Supports:
    * Start
    * Pause
    * Resume
    * Set specific time
    * Reset
* Uses database time rather than trusting the browser clock for stored timestamps.
* Updates the timer state.
* Writes a timer activity record.
* Returns the authoritative timer state.

Row Level Security

Enable Row Level Security on every table exposed through the Supabase Data API.

Create policies based on event_members.

General policy behavior:

profiles

* Users can read and update their own profile.
* Users may read limited profile information for other members of an event they can access.

events and related event tables

A user may select an event and its related data when they have a matching event_members record.

A user may insert an event when:

* They are authenticated.
* They are creating themselves as its owner through the approved event-creation function.

A user may update event data when their event role is:

* owner
* organizer

Only an owner may:

* Manage owner-level membership.
* Archive an event.
* Delete a draft event.

Viewers must only have select access.

audit tables

* Event members may read the audit history.
* Clients may not directly insert, update, or delete audit records.
* Audit records should only be inserted by approved database functions.
* No user may update or delete an existing audit record.

Restrict execution of database functions to authenticated users and validate event membership inside each function.

Realtime synchronization

Subscribe to Supabase Realtime changes for the current event.

Listen for changes to:

* events
* rounds
* pairings
* timer_states
* event_members

When another organizer changes a result:

* Update the current pairing UI.
* Recalculate or reload the score view.
* Show a subtle notification such as “Result updated by another organizer.”

When another organizer changes the timer:

* Immediately synchronize the local timer.
* Do not continue displaying a stale local timer state.

When a round is recorded on another device:

* Advance all connected devices to the next round.
* Reset the current result controls.
* Load the new pairings and timer state.

Handle duplicate and out-of-order real-time events safely by treating Supabase as the source of truth and re-fetching the affected record when necessary.

Unsubscribe from old event channels when navigating to another event.

Optimistic updates

Use optimistic updates only for low-risk interactions such as selecting a pending pairing result.

For a pending result selection:

1. Update the control immediately.
2. Update the visible pending score immediately.
3. Send the update to Supabase.
4. Show a compact saving indicator.
5. If the update fails:
    * Revert to the last confirmed database value.
    * Restore the previous score.
    * Show an actionable error message.

Do not optimistically show a round as finalized before record_round_and_advance succeeds.

Conflict handling

Use the updated_at value for basic stale-update detection.

When editing a previously recorded result:

* Include the last known updated_at.
* If the database record has changed since it was loaded, reject the update.
* Reload the latest result.
* Show: “This result was changed by another organizer. Review the latest result before trying again.”

Disable repeated action buttons while a mutation is in progress.

Use idempotency protection for round finalization so double-clicking does not create duplicate score records or advance two rounds.

Data loading

When opening a current event, fetch:

* Event details
* Current user’s membership and role
* Teams
* Formats
* Active players
* Current round
* Current-round pairings
* Timer state
* Team score view
* Recent event activity

Show skeleton loading states rather than an empty interface.

Do not render editable controls until the current user’s role has been resolved.

Primary dashboard

Create a live-event dashboard with the following hierarchy.

Header

Display:

* Event name
* Current match or round, such as “Match 2 of 5”
* Event status
* Database synchronization status
* Indicator showing whether all current results have been entered
* Current organizer role

Synchronization states:

* Saved
* Saving
* Offline
* Sync error

Total Recorded Match Wins

Create a prominent horizontal score bar labeled “Total Recorded Match Wins.”

Display both teams on opposite sides with:

* Team name
* Team color or identifier
* Large total match-win count
* Recorded-win count
* Pending-win count

Example:

Team A: 12 recorded + 3 pending = 15
Team B: 10 recorded + 2 pending = 12

Pending wins must be visually distinguishable from finalized wins.

Populate this UI from the event_team_scores database view rather than a manually maintained front-end total.

Event timer

Display a large countdown timer.

Timer behavior:

* Default duration is 50:00.
* Timer state is persisted in Supabase.
* Connected devices display the same timer state.
* The visible timer updates locally every second.
* The database is only updated for timer actions, not every second.
* After 00:00, continue into negative overtime.
* Display overtime as −00:01, −04:32, and so on.
* Change the timer to the design system’s error color when negative.
* Include Pause and Resume controls.
* Owners and organizers can set a specific time.
* Viewers cannot change the timer.
* Returning to the page should reconstruct the correct current timer from the stored timestamps.

Format sections

Show one section or card for each active format.

Each section should include:

* Format name
* Current pairings
* Player names from both teams
* Result controls
* Completion state
* Count such as “2 of 3 results entered”

Matchup result controls

For every pairing, allow:

* Team A player wins
* Team B player wins
* Draw, when enabled
* Not yet recorded

Use large explicit controls rather than small dropdowns.

Changing a pending result should:

* Update Supabase.
* Update the pending score.
* Synchronize to other connected organizers.
* Display saving and error feedback.

Prevent both players from being marked as winners.

Disable editing for viewers.

Record Match and Continue

Include a prominent button for owners and organizers.

When selected:

1. Validate that all required results are present.
2. Identify incomplete pairings if validation fails.
3. Show a confirmation dialog.
4. Call the record_round_and_advance database function.
5. Wait for a successful database response.
6. Load the next round and timer from the returned data.
7. Show a success confirmation.

Do not calculate or permanently increment cumulative scores solely in client state.

For the final round, label the action “Complete Event.”

Configuration and event management

Place a persistent gear icon in the bottom-right corner.

The management area should include:

* Current Event
* New Event
* Past Events
* Organizers

Current Event

Allow authorized organizers to:

* Review recorded rounds
* Expand rounds to see pairings
* Correct previously recorded results
* Enter a required correction reason
* Recalculate scores automatically
* Set the timer to a specific value
* Pause or resume the timer
* Rename the event
* Update team names and colors
* Archive the event

Use the correct_pairing_result database function for corrections.

Show:

* Who changed the result
* When it changed
* Previous result
* New result
* Correction reason

New Event

Provide a guided configuration flow.

Allow the organizer to set:

* Event name
* Number of formats, from 1 to 6
* Format names
* Number of teams
* Team names
* Team colors
* Players assigned by team and format
* Number of rounds
* Default timer duration
* Matchup method
* Whether draws are allowed

Keep the unfinished configuration in local form state.

Only write the complete event to Supabase after the organizer confirms the review screen.

Call create_event_with_configuration to create the full event atomically.

Prevent duplicate submission while creation is in progress.

Past Events

Query completed and archived events the current user can access.

Display:

* Event name
* Date
* Teams
* Final score
* Winning team
* Number of formats
* Number of rounds
* Status

Allow users to inspect:

* Final totals
* Results by round
* Results by format
* Individual pairings
* Corrections and audit history

Past events should be read-only unless an owner or organizer explicitly enters correction mode.

Organizers

Allow the owner to:

* See current event members
* Add an authenticated user by email
* Change a member between organizer and viewer
* Remove organizers or viewers
* Transfer ownership only through an explicit confirmation flow

Do not allow an event to have no owner.

Offline and failure behavior

The interface must clearly communicate when Supabase cannot be reached.

When offline:

* Continue displaying the most recently loaded event data.
* Continue calculating a running timer from its last confirmed state.
* Disable round finalization.
* Disable corrections to recorded results.
* Allow pending result selections to remain visibly unsaved only if they are clearly labeled.
* Do not silently imply that unsaved results are persisted.

Provide a Retry Sync action.

Do not overwrite newer server data with stale offline data after reconnecting.

Important application states

Design these states:

* Authentication required
* Authentication loading
* No event configured
* Event draft
* Event ready but not started
* Match in progress
* Timer paused
* Timer in overtime
* Some results entered
* All results entered
* Result saving
* Result save failed
* Match confirmation
* Missing-result error
* Match finalization in progress
* Between matches
* Event complete
* Editing a recorded result
* Conflict detected
* Offline
* Reconnecting
* Empty event history
* Insufficient permissions

Visual direction

Use a polished tournament-operations aesthetic:

* Dark, high-contrast interface
* Large typography for timer and scores
* Strong separation between teams
* Compact, readable format cards
* Clear success, warning, saving, offline, and error states
* Minimal decorative imagery
* Accessible contrast
* Keyboard navigation
* Visible focus states
* Do not rely on color alone

Favor clarity and speed over visual novelty.

The score, timer, current pairings, saving status, and result controls should always be the most prominent information.

Sample development data

Create an optional seed script with:

* One authenticated organizer
* One active event
* Two teams
* Three formats
* Three players per team in each format
* Three configured rounds
* Current-round pairings
* Several recorded historical results
* Several pending current results
* A running timer
* One corrected historical result and audit record

Clearly separate seeded development data from production data.

Deliverables

Generate:

* Functional responsive interface
* Supabase client integration
* Authentication flow
* Database migration SQL
* Tables, indexes, constraints, and views
* Row Level Security policies
* Database functions
* Realtime subscriptions
* Seed data
* Typed database interfaces
* Loading and error states
* A README explaining:
    * Required environment variables
    * How to create the Supabase project
    * How to run the migration
    * How to seed development data
    * How to run the application locally

Do not leave Supabase functionality represented only by placeholder comments. Implement the persistence flows and provide the required SQL.