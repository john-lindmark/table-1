import { useState } from "react";
import { Screen, Segmented, TabBar } from "../components/kit";
import { SeatingPanel } from "../components/SeatingPanel";
import { toBundle } from "../lib/api";
import { TAB_LABELS, type OrganizerTab } from "../lib/organizer";
import type { EventTeam, Participant, SeatingPod } from "../lib/types";
import { DeckPhotoDemo } from "./DeckPhotos";
import { NewEvent } from "./Home";
import { LiveView } from "./organizer/LiveView";

// Design QA without signing in (dev server only): /dev/events shows the create form, the seating table and the
// organizer's Live round (two columns on a desktop window) on sample data. Server calls made from here fail (no
// session).
const NAMES = ["Ann Ito", "Bo Lindqvist", "Cy Park", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt"];

function pod(n: number, id = `pod${n}`): SeatingPod {
  return {
    pod_id: id,
    name: "Pod 1",
    seats: Array.from({ length: n }, (_, i) => ({ seat: i + 1, participant_id: `p${i + 1}`, display_name: NAMES[i], team: null })),
  };
}

const people: Participant[] = NAMES.map((n, i) => ({
  id: `p${i + 1}`, eventId: "demo", podId: "pod8", displayName: n, seat: i + 1, status: "active", droppedInRound: null,
}));

/** An 8-player draft in round 2 of 3, round 1 played, in event_bundle's wire shape. A `team` bundle is a 3v3 team
 *  draft after round 1 with two of round 2's matches in: Alpha has 5 of 9 match wins, so it has clinched. */
function liveBundle(team = false) {
  const E = "demo-event";
  const side = (m: string, p: number, s: number, wins: number) =>
    ({ id: `${m}-${s}`, match_id: m, event_id: E, participant_id: `p${p}`, side: s, game_wins: wins, user_id: null });
  const match = (r: number, t: number, a: number, b: number, wa: number, wb: number, status: string) => {
    const id = `m${r}-${t}`;
    return {
      id, round_id: `r${r}`, event_id: E, pod_id: null, table_number: t, is_bye: false, status, disputed: false, game_draws: 0,
      intentional_draw: false, version: 0, reported_at: null, result_at: null, result_source: null, reported_by_participant: null,
      reported_by_user: null, created_at: "2026-10-22T18:00:00Z", updated_at: "2026-10-22T18:00:00Z",
      match_sides: [side(id, a, 0, wa), side(id, b, 1, wb)],
    };
  };
  const round = (n: number, status: string, matches: unknown[]) => ({
    id: `r${n}`, event_id: E, number: n, status, matches, pairings_published_at: null, recorded_at: null, started_at: null,
    timer_duration_seconds: 3000, timer_ends_at: null, timer_last_started_at: null, timer_remaining_at_change: 1724, timer_status: "paused",
  });
  if (team) {
    const ids = [1, 2, 3, 4, 5, 6];
    return toBundle({
      access: "organizer", is_organizer: true, teams: [],
      event: {
        id: E, name: "Team draft · Duskmourn · Fri 24 Oct", short_code: "DEMO", status: "in_progress", format: "draft",
        format_name: "team_draft", format_label: "Team draft · Duskmourn", event_type: "limited", current_round: 2,
        number_of_rounds: 3, pairing: "swiss", show_clock: true, allow_player_reporting: true, round_length_seconds: 3000,
        visibility: "link_only", venue_name: "Denver Card Shop", team_size: 3, set_name: "Duskmourn", created_by: null,
        created_at: "2026-10-22T18:00:00Z", updated_at: "2026-10-22T18:00:00Z",
      },
      participants: ids.map((i) => ({
        id: `p${i}`, event_id: E, pod_id: "pod8", display_name: NAMES[i - 1], seat: i, status: "active", dropped_in_round: null,
        team_id: i <= 3 ? "tA" : "tB", team_slot: ((i - 1) % 3) + 1, user_id: null, created_at: "2026-10-22T18:00:00Z",
      })),
      rounds: [
        round(1, "recorded", [match(1, 1, 1, 5, 2, 1, "confirmed"), match(1, 2, 2, 6, 2, 0, "confirmed"), match(1, 3, 3, 4, 2, 1, "confirmed")]),
        round(2, "active", [match(2, 1, 1, 6, 2, 0, "confirmed"), match(2, 2, 2, 4, 2, 1, "reported"), match(2, 3, 3, 5, 0, 0, "pending")]),
      ],
    });
  }
  return toBundle({
    access: "organizer", is_organizer: true, teams: [],
    event: {
      id: E, name: "Draft · Duskmourn · Fri 24 Oct", short_code: "DEMO", status: "in_progress", format: "draft", format_name: "draft",
      format_label: "Draft · Duskmourn", event_type: "limited", current_round: 2, number_of_rounds: 3, pairing: "swiss", show_clock: true,
      allow_player_reporting: true, round_length_seconds: 3000, visibility: "link_only", venue_name: "Denver Card Shop", team_size: null,
      set_name: "Duskmourn", created_by: null, created_at: "2026-10-22T18:00:00Z", updated_at: "2026-10-22T18:00:00Z",
    },
    participants: NAMES.map((n, i) => ({
      id: `p${i + 1}`, event_id: E, pod_id: "pod8", display_name: n, seat: i + 1, status: "active", dropped_in_round: null,
      team_id: null, team_slot: null, user_id: null, created_at: "2026-10-22T18:00:00Z",
    })),
    rounds: [
      round(1, "completed", [match(1, 1, 1, 5, 2, 0, "confirmed"), match(1, 2, 2, 6, 2, 1, "confirmed"),
                             match(1, 3, 3, 7, 1, 2, "confirmed"), match(1, 4, 4, 8, 0, 2, "confirmed")]),
      round(2, "active", [match(2, 1, 1, 2, 2, 1, "confirmed"), match(2, 2, 7, 8, 1, 0, "reported"),
                          match(2, 3, 5, 6, 0, 0, "pending"), match(2, 4, 3, 4, 0, 0, "pending")]),
    ],
  });
}

const LIVE_TABS: OrganizerTab[] = ["round", "standings", "players"];

const DEMO_TEAMS: EventTeam[] = [
  { id: "tA", name: "Alpha", order: 1, members: [] },
  { id: "tB", name: "Bravo", order: 2, members: [] },
];

function LiveDemo({ team = false }: { team?: boolean }) {
  const [tab, setTab] = useState<OrganizerTab>("round");
  const [bundle] = useState(() => liveBundle(team));
  const teams = team ? DEMO_TEAMS : null;
  return (
    <>
      <TabBar tabs={LIVE_TABS} value={tab} onChange={setTab} labels={TAB_LABELS} />
      <LiveView eventId="demo-event" bundle={bundle} tab={tab} isTeam={team} isDraft teams={teams}
                teamNames={new Map((teams ?? []).map((t) => [t.id, t.name]))}
                refetch={async () => {}} onOpenMatch={() => {}} setActionError={() => {}} mutate={async () => {}} />
    </>
  );
}

export function EventsDemo() {
  const [screen, setScreen] = useState<"create" | "seating" | "live" | "team" | "photos">("seating");
  return (
    <Screen width={screen === "live" || screen === "team" ? "wide" : "column"}>
      <Segmented
        label="Demo"
        value={screen}
        onChange={setScreen}
        options={[
          { value: "create", label: "Create" },
          { value: "seating", label: "Seating" },
          { value: "live", label: "Live" },
          { value: "team", label: "Team" },
          { value: "photos", label: "Photos" },
        ]}
      />
      {screen === "photos" ? (
        <DeckPhotoDemo />
      ) : screen === "team" ? (
        <LiveDemo key="team" team />
      ) : screen === "live" ? (
        <LiveDemo key="live" />
      ) : screen === "create" ? (
        <NewEvent onCancel={() => setScreen("seating")} onCreated={() => {}} />
      ) : (
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          <SeatingPanel pods={[pod(8)]} formatName="draft" participants={people} teams={null} highlightParticipantId="p3" />
          <SeatingPanel pods={[pod(7, "pod7")]} formatName="draft" participants={people} teams={null} />
          <SeatingPanel pods={[pod(10, "pod10")]} formatName="draft" participants={people} teams={null} seatEnds />
        </div>
      )}
    </Screen>
  );
}
