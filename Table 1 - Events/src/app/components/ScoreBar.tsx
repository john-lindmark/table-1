import type { EventState } from "../lib/types";
import { computeScores } from "../lib/scoring";

// Total matchup wins available per side across the whole event:
// sum of (players per team per format) × number of rounds.
function totalSlotsForEvent(event: EventState): number {
  const teamAId = event.teams[0]?.id;
  const matchupsPerRound = event.formats.reduce((sum, fmt) => {
    return (
      sum + event.players.filter((p) => p.teamId === teamAId && p.formatId === fmt.id).length
    );
  }, 0);
  return Math.max(1, event.numberOfRounds * matchupsPerRound);
}

function Side({
  recorded,
  pending,
  slots,
  reverse,
}: {
  recorded: number;
  pending: number;
  slots: number;
  reverse: boolean;
}) {
  const filledRecorded = Math.min(recorded, slots);
  const filledPending = Math.min(pending, slots - filledRecorded);

  const segs = Array.from({ length: slots }).map((_, i) => {
    let cls = "bg-[#f5f5f6] dark:bg-[#282839]";
    if (i < filledRecorded) cls = "bg-[#00ffd9]";
    else if (i < filledRecorded + filledPending) cls = "bg-[#00ffd9] opacity-60";
    return <div key={i} className={`flex-[1_0_0] h-full min-w-px ${cls}`} />;
  });

  return (
    <div className="flex flex-[1_0_0] gap-px h-full items-center min-w-px">
      {reverse ? segs.reverse() : segs}
    </div>
  );
}

export function ScoreBar({ event }: { event: EventState }) {
  const scores = computeScores(event);
  const a = scores[event.teams[0].id];
  const b = scores[event.teams[1].id];
  const slots = totalSlotsForEvent(event);
  return (
    <div
      className="flex gap-px h-[40px] items-center w-full"
      role="img"
      aria-label={`Total recorded match wins. ${event.teams[0].name}: ${a.total}. ${event.teams[1].name}: ${b.total}. ${slots} possible wins per side.`}
    >
      <Side recorded={a.recorded} pending={a.pending} slots={slots} reverse />
      <div className="bg-[#171725] dark:bg-white h-full w-[16px]" />
      <Side recorded={b.recorded} pending={b.pending} slots={slots} reverse={false} />
    </div>
  );
}
