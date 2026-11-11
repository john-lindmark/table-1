import type { EventBundle } from "../../lib/api";
import type { OrganizerTab } from "../../lib/organizer";
import { toTeams } from "../../lib/useEventExtras";
import type { EventTeam, Match, Participant, RoundWithMatches } from "../../lib/types";
import { matchTitle, nameLookup, scoreText } from "../../lib/organizer";
import { roundName } from "../../lib/scheduledEvents";
import { PodHeader, Row, Section } from "../../components/kit";
import { matchCount, podSections, type PodRef } from "../../lib/draftPods";
import { StandingsTable } from "../../components/StandingsTable";
import { TeamStandingsTable } from "../../components/TeamStandingsTable";

/** What every phase view gets from the organizer screen. */
export interface PhaseViewProps {
  eventId: string;
  bundle: EventBundle;
  tab: OrganizerTab;
  isTeam: boolean;
  isDraft: boolean;
  teams: EventTeam[] | null;
  teamNames: Map<string, string>;
  refetch: () => Promise<void>;
  /** Opens the set-result panel for a (non-bye) match. */
  onOpenMatch: (match: Match) => void;
  /** Big-action / tab errors shown under the tabs. */
  setActionError: (message: string | null) => void;
}

/** The standings list; team events show the team table first. */
export function StandingsBlock({
  bundle,
  isTeam,
  teams,
  teamNames,
}: Pick<PhaseViewProps, "bundle" | "isTeam" | "teams" | "teamNames">) {
  return (
    <>
      {isTeam && (
        <>
          <Section title="Teams" />
          <TeamStandingsTable teams={toTeams(teams ?? [])} participants={bundle.participants} rounds={bundle.rounds} />
          <Section title="Players" />
        </>
      )}
      <StandingsTable participants={bundle.participants} rounds={bundle.rounds} teamNames={isTeam ? teamNames : undefined}
                      pods={bundle.event.formatName === "draft" ? bundle.pods : undefined} />
    </>
  );
}

/** Rounds newest first, every match tappable to correct its result (Results → Rounds, Live → Earlier). */
export function RoundsList({ rounds, participants, numberOfRounds, onOpenMatch, pods = [] }: {
  rounds: RoundWithMatches[];
  participants: Participant[];
  numberOfRounds: number;
  onOpenMatch: (match: Match) => void;
  /** Drafts: the event's pods, so each round's matches sit under Pod 1 / Pod 2 / Across pods. */
  pods?: PodRef[];
}) {
  const nameOf = nameLookup(participants);
  const podOf = podOfParticipants(participants);
  const row = (m: Match) => (
    <Row
      key={m.id}
      title={matchTitle(m, nameOf)}
      detail={m.resultSource === "organizer" && !m.isBye ? "Set by organizer" : undefined}
      value={roundValue(m)}
      onClick={m.isBye ? undefined : () => onOpenMatch(m)}
    />
  );
  return (
    <>
      {[...rounds]
        .sort((a, b) => b.number - a.number)
        .map((r) => {
          const sections = matchPodSections(r.matches, pods, podOf, r.stage);
          return sections ? (
            // Drafts with 2+ pods: "Round 2 · Pod 1", "Round 2 · Across pods", each its own block.
            <div key={r.id} className="flex flex-col gap-px">
              {sections.map((s) => (
                <div key={s.pod ?? s.title} className="flex flex-col gap-px">
                  <PodHeader title={`Round ${r.number} · ${s.title}`} right={matchCount(s.items.filter((m) => !m.isBye).length)} />
                  {s.items.map(row)}
                </div>
              ))}
            </div>
          ) : (
            <div key={r.id} className="flex flex-col gap-px">
              <Section title={r.stage && r.stage !== "swiss" ? roundName(r.stage, r.number, numberOfRounds) : `Round ${r.number}`} />
              {[...r.matches]
                .sort((a, b) => Number(a.isBye) - Number(b.isBye) || (a.tableNumber ?? 0) - (b.tableNumber ?? 0))
                .map(row)}
            </div>
          );
        })}
    </>
  );
}

/** participant → pod, for grouping matches by pod. */
export function podOfParticipants(participants: Participant[]): Map<string, string | null> {
  return new Map(participants.map((p) => [p.id, p.podId]));
}

/** A round's matches by pod (null: one list). */
export function matchPodSections(matches: Match[], pods: PodRef[], podOf: Map<string, string | null>, stage?: string | null) {
  return podSections(matches, pods, podOf, stage, {
    players: (m) => m.sides.map((s) => s.participantId), table: (m) => m.tableNumber, isBye: (m) => m.isBye,
  });
}

function roundValue(m: Match): string {
  if (m.isBye) return "2–0";
  if (m.status === "pending") return "—";
  return scoreText(m);
}
