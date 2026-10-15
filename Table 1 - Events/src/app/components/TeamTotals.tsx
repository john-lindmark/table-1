import type { EventState } from "../lib/types";
import { computeScores } from "../lib/scoring";

const MONO = "var(--font-sf-mono)";

export function TeamTotals({ event }: { event: EventState }) {
  const scores = computeScores(event);
  const a = scores[event.teams[0].id];
  const b = scores[event.teams[1].id];

  return (
    <div className="flex gap-px items-center w-full">
      <div className="flex-[1_0_0] min-w-px px-[16px] py-[12px] flex items-baseline gap-[10px]">
        <p
          className="leading-[16px] text-[#171725] dark:text-white text-[12px] tracking-[0.2px]"
          style={{ fontFamily: MONO }}
        >
          {event.teams[0].name}
        </p>
        <p
          className="text-[#545461] dark:text-[#c4c4ca] text-[11px] tabular-nums tracking-[0.2px]"
          style={{ fontFamily: MONO }}
        >
          {a.recorded}
          <span className="opacity-60"> + {a.pending} pending</span> = {a.total}
        </p>
      </div>
      <div className="flex-[1_0_0] min-w-px px-[16px] py-[12px] flex items-baseline justify-end gap-[10px]">
        <p
          className="text-[#545461] dark:text-[#c4c4ca] text-[11px] tabular-nums tracking-[0.2px]"
          style={{ fontFamily: MONO }}
        >
          {b.total} = {b.recorded}
          <span className="opacity-60"> + {b.pending} pending</span>
        </p>
        <p
          className="leading-[16px] text-[#171725] dark:text-white text-[12px] text-right tracking-[0.2px]"
          style={{ fontFamily: MONO }}
        >
          {event.teams[1].name}
        </p>
      </div>
    </div>
  );
}
