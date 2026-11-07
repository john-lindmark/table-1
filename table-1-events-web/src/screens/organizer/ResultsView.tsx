import { gameRecord, lastRoundNumber, matchTitle, nameLookup, scoreText } from "../../lib/organizer";
import { recordLabel } from "../../lib/standings";
import { playoffStandings } from "../../lib/playoffs";
import { roundName } from "../../lib/scheduledEvents";
import { computeTeamStandings, membersOf } from "../../lib/teams";
import { toTeams } from "../../lib/useEventExtras";
import type { Match } from "../../lib/types";
import { Notice, Row, Section, WinnerCard } from "../../components/kit";
import { StandingsBlock, type PhaseViewProps } from "./shared";
import { Avatar } from "../../components/Avatar";
import { useOpenProfile } from "../../lib/personLink";

const wld = (w: number, l: number, d: number) => (d > 0 ? `${w}-${l}-${d}` : `${w}-${l}`);

/** Results: Standings (winner card, final standings) | Rounds (newest first, tap to correct) | Players. */
export function ResultsView(props: PhaseViewProps) {
  const { bundle, tab, isTeam, teams, teamNames, onOpenMatch } = props;
  const { event, rounds, participants } = bundle;
  const cancelled = event.status === "cancelled";
  const nameOf = nameLookup(participants);
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
          {[...rounds]
            .sort((a, b) => b.number - a.number)
            .map((r) => (
              <div key={r.id} className="flex flex-col gap-px">
                <Section title={r.stage && r.stage !== "swiss" ? roundName(r.stage, r.number, event.numberOfRounds) : `Round ${r.number}`} />
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
          {rounds.length > 0 && (
            <Notice tone="info">Tap a match to correct its result. Standings and records update.</Notice>
          )}
        </>
      )}

      {tab === "players" && (
        <>
          <Section title="Players" count={participants.length} />
          {standings.map((s) => {
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
          })}
        </>
      )}
    </div>
  );
}

function roundValue(m: Match): string {
  if (m.isBye) return "2–0";
  if (m.status === "pending") return "—";
  return scoreText(m);
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
