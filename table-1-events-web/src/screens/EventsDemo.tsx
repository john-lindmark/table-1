import { useState } from "react";
import { Bar, Screen, Segmented, TabBar } from "../components/kit";
import { SeatingPanel } from "../components/SeatingPanel";
import { toBundle } from "../lib/api";
import { TAB_LABELS, type OrganizerTab } from "../lib/organizer";
import type { EventTeam, Participant, SeatingPod } from "../lib/types";
import { DeckPhotoDemo } from "./DeckPhotos";
import { NewEvent } from "./Home";
import { LiveView } from "./organizer/LiveView";
import { SetupView } from "./organizer/SetupView";
import { StandingsTable } from "../components/StandingsTable";
import { pairRound } from "../lib/pairings";

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
  // Accounts, so a tap opens the demo profile (lib/personLink.ts); the last player is a guest.
  userId: demoUser(i + 1),
}));

/** Seat n's account, so a tap opens the demo profile (lib/personLink.ts); the last seat is a guest. */
function demoUser(n: number): string | null {
  return n < NAMES.length ? `d0000000-0000-0000-0000-0000000e${String(n).padStart(4, "0")}` : null;
}

/** An 8-player draft in round 2 of 3, round 1 played, in event_bundle's wire shape. A `team` bundle is a 3v3 team
 *  draft after round 1 with two of round 2's matches in: Alpha has 5 of 9 match wins, so it has clinched. */
function liveBundle(team = false, pods = false) {
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
    id: `r${n}`, event_id: E, number: n, status, matches, pairings_published_at: `2026-10-22T${17 + n}:00:00Z`, recorded_at: null, started_at: null,
    timer_duration_seconds: 3000, timer_ends_at: null, timer_last_started_at: null, timer_remaining_at_change: 1724, timer_status: "paused",
  });
  if (pods) {
    // ?screen=podslive: 15 in Pod 1 (8) and Pod 2 (7), round 2 of 3 inside pods; Pod 2's odd player out has the bye.
    const bye = (r: number, a: number) => ({
      ...match(r, 0, a, a, 2, 0, "confirmed"), id: `m${r}-bye`, table_number: null, is_bye: true, match_sides: [side(`m${r}-bye`, a, 0, 2)],
    });
    const disputed = { ...match(2, 3, 5, 3, 2, 1, "reported"), disputed: true };
    return toBundle({
      access: "organizer", is_organizer: true, teams: [],
      pods: [{ id: "podA", name: "Pod 1", display_order: 0 }, { id: "podB", name: "Pod 2", display_order: 1 }],
      event: {
        id: E, name: "Draft · Duskmourn · Fri 24 Oct", short_code: "DEMO", status: "in_progress", format: "draft", format_name: "draft",
        format_label: "Draft · Duskmourn", event_type: "limited", current_round: 2, number_of_rounds: 3, pairing: "swiss", show_clock: true,
        allow_player_reporting: true, round_length_seconds: 3000, visibility: "link_only", venue_name: "Denver Card Shop", team_size: null,
        set_name: "Duskmourn", created_by: null, created_at: "2026-10-22T18:00:00Z", updated_at: "2026-10-22T18:00:00Z",
        pods: 2, pod_pairing: "pod",
      },
      participants: [...POD_NAMES, "Oli Kerr"].map((n, i) => ({
        id: `p${i + 1}`, event_id: E, pod_id: i < 8 ? "podA" : "podB", display_name: n, seat: i < 8 ? i + 1 : i - 7, status: "active",
        dropped_in_round: null, team_id: null, team_slot: null, user_id: demoUser(i + 1), created_at: "2026-10-22T18:00:00Z",
      })),
      rounds: [
        round(1, "recorded", [match(1, 1, 1, 5, 2, 0, "confirmed"), match(1, 2, 2, 6, 2, 1, "confirmed"), match(1, 3, 3, 7, 0, 2, "confirmed"),
                              match(1, 4, 4, 8, 2, 1, "confirmed"), match(1, 5, 9, 12, 2, 0, "confirmed"), match(1, 6, 10, 13, 1, 2, "confirmed"),
                              match(1, 7, 11, 14, 2, 1, "confirmed"), bye(1, 15)]),
        round(2, "active", [match(2, 1, 1, 2, 0, 0, "pending"), match(2, 2, 7, 4, 2, 1, "confirmed"), disputed,
                            match(2, 4, 6, 8, 2, 0, "reported"), match(2, 5, 9, 15, 2, 1, "confirmed"),
                            match(2, 6, 13, 11, 0, 0, "pending"), match(2, 7, 12, 14, 0, 0, "pending"), bye(2, 10)]),
      ],
    });
  }
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
        team_id: i <= 3 ? "tA" : "tB", team_slot: ((i - 1) % 3) + 1, user_id: demoUser(i), created_at: "2026-10-22T18:00:00Z",
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
      team_id: null, team_slot: null, user_id: demoUser(i + 1), created_at: "2026-10-22T18:00:00Z",
    })),
    rounds: [
      // ?repair: table 3 was corrected by the organizer after round 2 went out, so Live offers to re-pair round 2.
      round(1, "recorded", [match(1, 1, 1, 5, 2, 0, "confirmed"), match(1, 2, 2, 6, 2, 1, "confirmed"),
                            new URLSearchParams(location.search).has("repair")
                              ? { ...match(1, 3, 3, 7, 1, 2, "confirmed"), result_source: "organizer", updated_at: "2026-10-22T19:20:00Z" }
                              : match(1, 3, 3, 7, 1, 2, "confirmed"),
                            match(1, 4, 4, 8, 0, 2, "confirmed")]),
      round(2, "active", [match(2, 1, 1, 2, 2, 1, "confirmed"), match(2, 2, 7, 8, 1, 0, "reported"),
                          match(2, 3, 5, 6, 0, 0, "pending"), match(2, 4, 3, 4, 0, 0, "pending")]),
    ],
  });
}

const LIVE_TABS: OrganizerTab[] = ["round", "rounds", "standings", "players"];

const DEMO_TEAMS: EventTeam[] = [
  { id: "tA", name: "Alpha", order: 1, members: [] },
  { id: "tB", name: "Bravo", order: 2, members: [] },
];

function LiveDemo({ team = false, pods = false }: { team?: boolean; pods?: boolean }) {
  const [tab, setTab] = useState<OrganizerTab>(() => (new URLSearchParams(location.search).get("tab") as OrganizerTab | null) ?? "round");
  const [bundle] = useState(() => liveBundle(team, pods));
  const teams = team ? DEMO_TEAMS : null;
  return (
    <>
      <TabBar tabs={LIVE_TABS} value={tab} onChange={setTab} labels={{ ...TAB_LABELS, rounds: "Earlier" }} />
      <LiveView eventId="demo-event" bundle={bundle} tab={tab} isTeam={team} isDraft teams={teams}
                teamNames={new Map((teams ?? []).map((t) => [t.id, t.name]))}
                refetch={async () => {}} onOpenMatch={() => {}} setActionError={() => {}} mutate={async () => {}}
                onRepair={() => window.alert("Re-pair round 2? (demo)")} />
    </>
  );
}

/** `?screen=pods`: a seated draft of 14 in two pods of 7, paired inside pods (contract/draft-pods-2026-11-09.md),
 *  the organizer's Seating tab, then standings after round 1 as the engine would pair and a sample result. */
const POD_NAMES = [...NAMES, "Ivy Novak", "Jo Reyes", "Kai Sato", "Lu Bianchi", "Max Weber", "Nia Adeyemi"];
function podsBundle() {
  const E = "demo-pods";
  return toBundle({
    access: "organizer", is_organizer: true, teams: [],
    pods: [{ id: "podA", name: "Pod 1", display_order: 0 }, { id: "podB", name: "Pod 2", display_order: 1 }],
    event: {
      id: E, name: "Draft · Duskmourn · Fri 24 Oct", short_code: "PODS", status: "seated", format: "draft", format_name: "draft",
      format_label: "Draft · Duskmourn", event_type: "limited", current_round: 0, number_of_rounds: 3, pairing: "swiss", show_clock: true,
      allow_player_reporting: true, round_length_seconds: 3000, visibility: "link_only", team_size: null, set_name: "Duskmourn",
      created_by: null, created_at: "2026-10-22T18:00:00Z", updated_at: "2026-10-22T18:00:00Z", pods: 2, pod_pairing: "pod", auto_rounds: true,
    },
    participants: POD_NAMES.map((n, i) => ({
      id: `q${i + 1}`, event_id: E, pod_id: i < 7 ? "podA" : "podB", display_name: n, seat: (i % 7) + 1, status: "active",
      dropped_in_round: null, team_id: null, team_slot: null, user_id: null, created_at: "2026-10-22T18:00:00Z",
    })),
    rounds: [],
  });
}

function PodsDemo() {
  const [bundle] = useState(podsBundle);
  const [error, setError] = useState<string | null>(null);
  // Round 1 as the engine pairs it; side 0 wins every match 2–1.
  const r1 = pairRound({ participants: bundle.participants, rounds: [], roundNumber: 1, draftSeating: true, podOrder: ["podA", "podB"] });
  const played = [{
    id: "r1", eventId: "demo-pods", number: 1, status: "recorded" as const, timerDurationSeconds: 3000, timerRemainingAtChange: 0,
    timerStatus: "paused" as const, timerLastStartedAt: null, timerEndsAt: null,
    matches: r1.map((m) => ({
      id: `m${m.tableNumber}`, eventId: "demo-pods", roundId: "r1", tableNumber: m.tableNumber, isBye: m.isBye, gameDraws: 0,
      intentionalDraw: false, status: "confirmed" as const,
      sides: [{ id: `m${m.tableNumber}a`, matchId: `m${m.tableNumber}`, participantId: m.side0ParticipantId, side: 0 as const, gameWins: 2 },
              ...(m.side1ParticipantId ? [{ id: `m${m.tableNumber}b`, matchId: `m${m.tableNumber}`, participantId: m.side1ParticipantId, side: 1 as const, gameWins: 1 }] : [])],
    })),
  }];
  return (
    <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
      <SetupView eventId="demo-pods" bundle={bundle} tab="seating" isTeam={false} isDraft teams={null} teamNames={new Map()}
                 refetch={async () => {}} setActionError={setError} onAddPlayers={() => {}} onTeamsSaved={() => {}}
                 onOpenMatch={() => {}} />
      {error && <div className="bg-t1-surface px-4 py-2 text-[11px] text-t1-muted">Demo: {error}</div>}
      <div className="bg-t1-surface px-4 py-2 t1-label">Standings after round 1</div>
      <StandingsTable participants={bundle.participants} rounds={played} pods={bundle.pods} />
    </div>
  );
}

type DemoScreen = "create" | "seating" | "live" | "team" | "photos" | "pods" | "podslive";
const DEMO_SCREENS: DemoScreen[] = ["create", "seating", "live", "team", "photos", "pods", "podslive"];

export function EventsDemo() {
  // `?screen=live` opens on that screen; `&bare` swaps the demo's picker for the organizer screen's own bar (the
  // feature-spot shots, tools/spots/shoot.mjs).
  const params = new URLSearchParams(window.location.search);
  const bare = params.has("bare");
  const [screen, setScreen] = useState<DemoScreen>(() => {
    const asked = params.get("screen") as DemoScreen | null;
    return asked && DEMO_SCREENS.includes(asked) ? asked : "seating";
  });
  return (
    <Screen width={screen === "live" || screen === "team" || screen === "podslive" ? "wide" : "column"}>
      {bare ? <Bar title={screen === "team" ? "Team draft · Duskmourn · Fri 24 Oct" : "Draft · Duskmourn · Fri 24 Oct"} subtitle="Organizer · Round 2 of 3" onBack={() => {}} /> : <Segmented
        label="Demo"
        value={screen}
        onChange={setScreen}
        options={[
          { value: "create", label: "Create" },
          { value: "seating", label: "Seating" },
          { value: "live", label: "Live" },
          { value: "team", label: "Team" },
          { value: "photos", label: "Photos" },
          { value: "pods", label: "Pods" },
          { value: "podslive", label: "Pods live" },
        ]}
      />}
      {screen === "pods" ? (
        <PodsDemo />
      ) : screen === "photos" ? (
        <DeckPhotoDemo />
      ) : screen === "team" ? (
        <LiveDemo key="team" team />
      ) : screen === "live" ? (
        <LiveDemo key="live" />
      ) : screen === "podslive" ? (
        <LiveDemo key="podslive" pods />
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
