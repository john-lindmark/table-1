import type { EventBundle } from "../../lib/api";
import type { OrganizerTab } from "../../lib/organizer";
import { toTeams } from "../../lib/useEventExtras";
import type { EventTeam, Match, Participant, RoundWithMatches } from "../../lib/types";
import { matchTitle, nameLookup, scoreText } from "../../lib/organizer";
import { roundName } from "../../lib/scheduledEvents";
import { Row, Section } from "../../components/kit";
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
export function RoundsList({ rounds, participants, numberOfRounds, onOpenMatch }: {
  rounds: RoundWithMatches[];
  participants: Participant[];
  numberOfRounds: number;
  onOpenMatch: (match: Match) => void;
}) {
  const nameOf = nameLookup(participants);
  return (
    <>
      {[...rounds]
        .sort((a, b) => b.number - a.number)
        .map((r) => (
          <div key={r.id} className="flex flex-col gap-px">
            <Section title={r.stage && r.stage !== "swiss" ? roundName(r.stage, r.number, numberOfRounds) : `Round ${r.number}`} />
            {[...r.matches]
              .sort((a, b) => Number(a.isBye) - Number(b.isBye) || (a.tableNumber ?? 0) - (b.tableNumber ?? 0))
              .map((m) => (
                <Row
                  key={m.id}
                  title={matchTitle(m, nameOf)}
                  detail={m.resultSource === "organizer" && !m.isBye ? "Set by organizer" : undefined}
                  value={roundValue(m)}
                  onClick={m.isBye ? undefined : () => onOpenMatch(m)}
                />
              ))}
          </div>
        ))}
    </>
  );
}

function roundValue(m: Match): string {
  if (m.isBye) return "2–0";
  if (m.status === "pending") return "—";
  return scoreText(m);
}
