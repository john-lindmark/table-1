import { slotLetter } from "../lib/formats";
import { formatPct } from "../lib/standings";
import { computeTeamStandings, type Team } from "../lib/teams";
import type { Participant, RoundWithMatches } from "../lib/types";

const wld = (w: number, l: number, d: number) => (d > 0 ? `${w}-${l}-${d}` : `${w}-${l}`);

/** Team table: rank · name · points · W-L-D · match wins, members under each team. Same rules as the server. */
export function TeamStandingsTable({
  teams,
  participants,
  rounds,
  highlightParticipantId,
}: {
  teams: Team[];
  participants: Participant[];
  rounds: RoundWithMatches[];
  highlightParticipantId?: string | null;
}) {
  if (!teams.length) return <div className="bg-t1-surface px-4 py-6 t1-label">No teams yet</div>;
  const rows = computeTeamStandings(teams, participants, rounds);
  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-2 flex items-center gap-3 t1-label">
        <span className="w-6 shrink-0">#</span>
        <span className="flex-1">Team</span>
        <span className="w-12 text-right">Rec</span>
        <span className="w-8 text-right">Pts</span>
      </div>
      {rows.map((t) => {
        const mine = t.members.some((m) => m.participantId === highlightParticipantId);
        return (
          <div key={t.teamId} className="flex flex-col">
            <div className={`px-4 py-3 flex items-center gap-3 text-[13px] tabular-nums ${mine ? "bg-t1-accent text-t1-ink" : "bg-t1-surface"}`}>
              <span className={`w-6 shrink-0 ${mine ? "" : "text-t1-muted"}`}>{t.rank}</span>
              <span className="flex-1 min-w-0 flex flex-col">
                <span className="truncate">{t.name}</span>
                <span className={`t1-label ${mine ? "text-t1-ink!" : ""}`}>
                  {t.matchWins} match win{t.matchWins === 1 ? "" : "s"}
                  {t.byes ? ` · ${t.byes} bye${t.byes === 1 ? "" : "s"}` : ""} · GW {formatPct(t.gameWinPct)}
                </span>
              </span>
              <span className="w-12 text-right">{wld(t.wins, t.losses, t.draws)}</span>
              <span className="w-8 text-right font-bold">{t.points}</span>
            </div>
            {t.members.map((m) => (
              <div
                key={m.participantId}
                className={`pl-13 pr-4 py-1.5 flex items-center gap-3 text-[11px] tabular-nums bg-t1-bg ${
                  m.participantId === highlightParticipantId ? "text-t1-accent" : "text-t1-muted"
                }`}
              >
                <span className="w-4">{slotLetter(m.slot)}</span>
                <span className={`flex-1 truncate ${m.status === "dropped" ? "line-through opacity-60" : ""}`}>{m.displayName}</span>
                <span>
                  {m.matchWins} win{m.matchWins === 1 ? "" : "s"}
                </span>
              </div>
            ))}
          </div>
        );
      })}
      <div className="bg-t1-surface px-4 py-3 text-[10px] leading-[15px] text-t1-muted">
        Team match: the team whose players win more of their matches takes it (win 3, draw 1). Ordered by team points,
        then members' total match wins, then game-win %.
      </div>
    </div>
  );
}
