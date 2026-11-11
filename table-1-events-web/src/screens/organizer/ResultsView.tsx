import { gameRecord, lastRoundNumber } from "../../lib/organizer";
import { recordLabel } from "../../lib/standings";
import { playoffStandings } from "../../lib/playoffs";
import { computeTeamStandings, membersOf } from "../../lib/teams";
import { toTeams } from "../../lib/useEventExtras";
import { Notice, PodHeader, Row, Section, WinnerCard } from "../../components/kit";
import { playerSections, podRefs } from "../../lib/draftPods";
import { RoundsList, StandingsBlock, type PhaseViewProps } from "./shared";
import { Avatar } from "../../components/Avatar";
import { useOpenProfile } from "../../lib/personLink";

const wld = (w: number, l: number, d: number) => (d > 0 ? `${w}-${l}-${d}` : `${w}-${l}`);

/** Results: Standings (winner card, final standings) | Rounds (newest first, tap to correct) | Players. */
export function ResultsView(props: PhaseViewProps) {
  const { bundle, tab, isTeam, teams, teamNames, onOpenMatch } = props;
  const { event, rounds, participants } = bundle;
  const cancelled = event.status === "cancelled";
  const standings = playoffStandings(participants, rounds);
  const openProfile = useOpenProfile("event_players");

  return (
    <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
      {tab === "standings" &&
        (cancelled ? (
          <>
            <Notice tone="error">
              {event.cancelReason ? `Cancelled: ${event.cancelReason}` : "Cancelled by the organizer."}
            </Notice>
            <Section title={`Standings after round ${lastRoundNumber(rounds)}`} />
            <StandingsBlock bundle={bundle} isTeam={isTeam} teams={teams} teamNames={teamNames} />
            <Notice tone="info">Confirmed results count toward records. Unplayed rounds never do.</Notice>
          </>
        ) : (
          <>
            <Winner {...props} />
            <Section title="Final standings" />
            <StandingsBlock bundle={bundle} isTeam={isTeam} teams={teams} teamNames={teamNames} />
          </>
        ))}

      {tab === "rounds" && (
        <>
          {rounds.length === 0 && <Notice tone="info">No rounds were played.</Notice>}
          <RoundsList rounds={rounds} participants={participants} numberOfRounds={event.numberOfRounds} onOpenMatch={onOpenMatch}
                      pods={podRefs(event.formatName, bundle.pods)} />
          {rounds.length > 0 && (
            <Notice tone="info">Tap a match to correct its result. Standings and records update.</Notice>
          )}
        </>
      )}

      {tab === "players" && (
        <>
          {(() => {
            const row = (s: (typeof standings)[number]) => {
              const p = participants.find((x) => x.id === s.participantId);
              return (
                <Row
                  key={s.participantId}
                  title={s.displayName}
                  avatar={<Avatar name={s.displayName} userId={p?.userId} />}
                  onClick={openProfile(p?.userId)}
                  detail={p?.status === "dropped" ? `Dropped after round ${p.droppedInRound ?? lastRoundNumber(rounds)}` : undefined}
                  value={`${recordLabel(s)} · ${s.matchPoints} pts`}
                />
              );
            };
            const podOf = new Map(participants.map((p) => [p.id, p.podId]));
            // Drafts with 2+ pods: each pod's players in final order (overall places), as their own blocks.
            const sections = playerSections(standings, podRefs(event.formatName, bundle.pods), (s) => podOf.get(s.participantId), () => null);
            return sections ? sections.map((sec) => (
              <div key={sec.pod ?? sec.title} className="flex flex-col gap-px">
                <PodHeader title={sec.title} right={`${sec.items.length} player${sec.items.length === 1 ? "" : "s"}`} />
                {sec.items.map(row)}
              </div>
            )) : (
              <>
                <Section title="Players" count={participants.length} />
                {standings.map(row)}
              </>
            );
          })()}
        </>
      )}
    </div>
  );
}

/** WINNER (W-L-D · P points · games GW-GL) or, for team events, WINNING TEAM with its members. */
function Winner({ bundle, isTeam, teams }: PhaseViewProps) {
  const { participants, rounds } = bundle;
  if (isTeam) {
    const rows = computeTeamStandings(toTeams(teams ?? []), participants, rounds);
    const top = rows[0];
    if (!top) return null;
    const members = membersOf(top.teamId, participants, false).map((p) => p.displayName);
    return (
      <WinnerCard
        label="WINNING TEAM"
        name={top.name}
        caption={`${wld(top.wins, top.losses, top.draws)} · ${top.points} points · ${top.matchWins} match wins`}
        line={members.length ? members.join(", ") : null}
      />
    );
  }
  const top = playoffStandings(participants, rounds)[0];
  if (!top) return null;
  const games = gameRecord(top.participantId, rounds);
  return (
    <WinnerCard
      label="WINNER"
      name={top.displayName}
      caption={`${top.matchWins}-${top.matchLosses}-${top.matchDraws} · ${top.matchPoints} points · games ${games.won}-${games.lost}`}
    />
  );
}
