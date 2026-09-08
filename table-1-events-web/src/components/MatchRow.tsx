import type { Match, Participant } from "../lib/types";

/** 0-0 is "not started", equal-and-above-zero is a draw, 2-2 is invalid. */
export type MatchState = "not_started" | "decisive" | "draw" | "invalid";

export function matchState(match: Match): { state: MatchState; winnerSide: 0 | 1 | null } {
  if (match.isBye) return { state: "decisive", winnerSide: 0 };
  const a = match.sides.find((s) => s.side === 0)?.gameWins ?? 0;
  const b = match.sides.find((s) => s.side === 1)?.gameWins ?? 0;
  if (a > 2 || b > 2 || (a === 2 && b === 2)) return { state: "invalid", winnerSide: null };
  if (a === 0 && b === 0) return { state: "not_started", winnerSide: null };
  if (a === b) return { state: "draw", winnerSide: null };
  return { state: "decisive", winnerSide: a > b ? 0 : 1 };
}

function Dots({ count, onAccent }: { count: number; onAccent: boolean }) {
  if (count <= 0) return null;
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <span
          key={i}
          className={`size-[8px] shrink-0 ${onAccent ? "bg-t1-ink" : "bg-t1-accent"}`}
        />
      ))}
    </>
  );
}

function Half({
  name,
  gameWins,
  isWinner,
  align,
  canEdit,
  onTap,
}: {
  name: string;
  gameWins: number;
  isWinner: boolean;
  align: "left" | "right";
  canEdit: boolean;
  onTap: () => void;
}) {
  return (
    <button
      type="button"
      disabled={!canEdit}
      onClick={onTap}
      aria-label={`${name}: ${gameWins} game wins. Tap to cycle.`}
      className={`flex-1 min-w-0 text-left transition-colors ${
        isWinner
          ? "bg-t1-accent text-t1-ink"
          : "bg-t1-surface text-t1-text hover:bg-t1-surface-hover"
      }`}
    >
      <div
        className={`flex items-center gap-[6px] px-4 py-4 ${
          align === "right" ? "flex-row-reverse" : "flex-row"
        }`}
      >
        <span
          className={`flex-1 min-w-0 truncate text-[13px] tracking-[0.2px] ${
            align === "right" ? "text-right" : "text-left"
          }`}
        >
          {name}
        </span>
        <Dots count={gameWins} onAccent={isWinner} />
      </div>
    </button>
  );
}

export function MatchRow({
  match,
  participants,
  canEdit,
  onCycle,
}: {
  match: Match;
  participants: Map<string, Participant>;
  canEdit: boolean;
  onCycle: (side: 0 | 1) => void;
}) {
  const { state, winnerSide } = matchState(match);
  const side0 = match.sides.find((s) => s.side === 0);
  const side1 = match.sides.find((s) => s.side === 1);
  const nameOf = (id: string | null | undefined) =>
    (id && participants.get(id)?.displayName) || "—";

  if (match.isBye) {
    return (
      <div className="flex flex-col gap-px">
        <div className="flex gap-px">
          <div className="flex-1 bg-t1-accent text-t1-ink px-4 py-4 text-[13px] truncate">
            {nameOf(side0?.participantId)}
          </div>
          <div className="flex-1 bg-t1-surface px-4 py-4 text-[13px] text-right t1-label">
            Bye · 2–0
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-px">
      <div className="flex gap-px items-stretch">
        <Half
          name={nameOf(side0?.participantId)}
          gameWins={side0?.gameWins ?? 0}
          isWinner={state === "decisive" && winnerSide === 0}
          align="left"
          canEdit={canEdit}
          onTap={() => onCycle(0)}
        />
        <Half
          name={nameOf(side1?.participantId)}
          gameWins={side1?.gameWins ?? 0}
          isWinner={state === "decisive" && winnerSide === 1}
          align="right"
          canEdit={canEdit}
          onTap={() => onCycle(1)}
        />
      </div>
      {state === "invalid" && (
        <p className="px-4 py-2 text-[10px] tracking-[0.2px] text-t1-danger bg-t1-danger/10">
          2–2 is not a valid result — adjust before recording.
        </p>
      )}
      {state === "draw" && (
        <p className="px-4 py-2 text-[10px] tracking-[1px] uppercase text-t1-muted bg-t1-surface">
          Draw
        </p>
      )}
    </div>
  );
}
