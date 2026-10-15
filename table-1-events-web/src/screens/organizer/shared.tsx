import type { EventBundle } from "../../lib/api";
import type { OrganizerTab } from "../../lib/organizer";
import { toTeams } from "../../lib/useEventExtras";
import type { EventTeam, Match } from "../../lib/types";
import { Section } from "../../components/kit";
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
      <StandingsTable participants={bundle.participants} rounds={bundle.rounds} teamNames={isTeam ? teamNames : undefined} />
    </>
  );
}
