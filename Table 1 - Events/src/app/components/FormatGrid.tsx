import type { EventState, Pairing, Player } from "../lib/types";
import { resolveCurrent, resultsEnteredForFormat } from "../lib/scoring";
import type { PairingResolution } from "../lib/scoring";

interface FormatGridProps {
  event: EventState;
  canEdit: boolean;
  onCycleWins: (pairingId: string, side: "a" | "b") => void;
}

const MONO = "var(--font-sf-mono)";

// Win dots — teal on non-winner, dark on winner bg.
function WinDots({ count, onWinner }: { count: number; onWinner: boolean }) {
  if (count <= 0) return null;
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <div
          key={i}
          className={onWinner ? "bg-[#171725] shrink-0 size-[8px]" : "bg-[#00ffd9] shrink-0 size-[8px]"}
        />
      ))}
    </>
  );
}

// Hover-only affordance:
//   0–1 wins → dim "+"
//   2 wins   → outlined reset circle (communicates click will cycle back to 0)
function HoverAffordance({ gameWins }: { gameWins: number }) {
  if (gameWins < 2) {
    return (
      <span
        className="opacity-0 group-hover:opacity-100 transition-opacity text-[#545461] text-[14px] leading-none shrink-0 select-none"
        aria-hidden
      >
        +
      </span>
    );
  }
  return (
    <svg
      viewBox="0 0 10 10"
      className="size-[10px] shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"
      fill="none"
      aria-hidden
    >
      <circle cx="5" cy="5" r="4" stroke="#545461" strokeWidth="1.2" />
    </svg>
  );
}

function PlayerCell({
  player,
  isWinner,
  gameWins,
  align,
  canEdit,
  onClick,
}: {
  player: Player;
  isWinner: boolean;
  gameWins: number;
  align: "left" | "right";
  canEdit: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      disabled={!canEdit}
      onClick={onClick}
      aria-label={`${player.name}: ${gameWins} game win${gameWins !== 1 ? "s" : ""}. Tap to cycle.`}
      className={`group flex-[1_0_0] min-w-px relative text-left transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#171725] dark:focus-visible:outline-white ${
        isWinner
          ? "bg-[#00ffd9]"
          : "bg-[#f5f5f6] dark:bg-[#282839] hover:bg-[#ececf0] dark:hover:bg-[#33334a]"
      } ${canEdit ? "cursor-pointer" : "cursor-default"}`}
    >
      <div
        className={`flex items-center gap-[6px] px-[16px] py-[12px] ${
          align === "right" ? "flex-row-reverse" : "flex-row"
        }`}
      >
        <p
          className={`[word-break:break-word] flex-[1_0_0] leading-[16px] min-w-px text-[12px] tracking-[0.2px] ${
            align === "right" ? "text-right" : "text-left"
          } ${isWinner ? "text-[#171725]" : "text-[#171725] dark:text-white"}`}
          style={{ fontFamily: MONO }}
        >
          {player.name}
        </p>

        {/* Static dots */}
        <WinDots count={gameWins} onWinner={isWinner} />

        {/* Hover affordance — only when canEdit and not on the winning (teal) cell */}
        {canEdit && !isWinner && <HoverAffordance gameWins={gameWins} />}
      </div>
    </button>
  );
}

function FormatColumn({
  event,
  formatId,
  pairings,
  resolutions,
  canEdit,
  onCycleWins,
}: {
  event: EventState;
  formatId: string;
  pairings: Pairing[];
  resolutions: Record<string, PairingResolution>;
  canEdit: boolean;
  onCycleWins: FormatGridProps["onCycleWins"];
}) {
  const format = event.formats.find((f) => f.id === formatId)!;
  const players = event.players;
  const p = (id: string) => players.find((x) => x.id === id)!;
  const { entered, total } = resultsEnteredForFormat(event, formatId);

  return (
    <div className="flex flex-[1_0_0] flex-col gap-px items-start min-w-px">
      <div className="bg-[#f5f5f6] dark:bg-[#282839] w-full px-[16px] py-[8px] flex items-center">
        <p
          className="[word-break:break-word] leading-[16px] text-[#545461] dark:text-[#c4c4ca] text-[12px] tracking-[0.2px]"
          style={{ fontFamily: MONO }}
        >
          {format.name}
        </p>
      </div>
      <div className="flex flex-col gap-px items-start w-full">
        {pairings.map((pair) => {
          const res = resolutions[pair.id];
          const invalid = res?.status === "invalid";
          return (
            <div key={pair.id} className="flex flex-col gap-px w-full">
              <div className="flex gap-px items-stretch w-full">
                <PlayerCell
                  player={p(pair.teamAPlayerId)}
                  isWinner={res?.winner === "a" && res?.status === "decisive"}
                  gameWins={pair.teamAGameWins ?? 0}
                  align="left"
                  canEdit={canEdit}
                  onClick={() => onCycleWins(pair.id, "a")}
                />
                <PlayerCell
                  player={p(pair.teamBPlayerId)}
                  isWinner={res?.winner === "b" && res?.status === "decisive"}
                  gameWins={pair.teamBGameWins ?? 0}
                  align="right"
                  canEdit={canEdit}
                  onClick={() => onCycleWins(pair.id, "b")}
                />
              </div>
              {invalid && (
                <p
                  className="w-full px-[16px] py-[6px] text-[10px] leading-[14px] text-[var(--destructive)] tracking-[0.2px] bg-[var(--destructive)]/10"
                  style={{ fontFamily: MONO }}
                >
                  2–2 is not a valid result — adjust before recording.
                </p>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

export function FormatGrid({ event, canEdit, onCycleWins }: FormatGridProps) {
  const resolutions = resolveCurrent(event);
  return (
    <div className="flex gap-px items-start w-full">
      {event.formats.map((fmt) => (
        <FormatColumn
          key={fmt.id}
          event={event}
          formatId={fmt.id}
          pairings={event.currentPairings.filter((p) => p.formatId === fmt.id)}
          resolutions={resolutions}
          canEdit={canEdit}
          onCycleWins={onCycleWins}
        />
      ))}
    </div>
  );
}
