import { useEffect, useRef, useState, type PointerEvent } from "react";
import { Bar, BigAction, GhostAction, Segmented, Stepper } from "../components/kit";
import { capture } from "../lib/telemetry";
import { LIFE_CHOICES, PLAYER_CHOICES, lastSetup } from "../lib/trackerTable";
import {
  CHOOSER_MIN_FINGERS,
  CHOOSER_RETURN_MS,
  DICE_SIDES,
  MAX_DICE,
  chooserDown,
  chooserMove,
  chooserProgress,
  chooserTick,
  chooserUp,
  diceBreakdown,
  emptyChooser,
  rollDice,
} from "../lib/trackerTools";

const LABEL = "text-[11px] leading-4 tracking-[1.5px] uppercase";

/** A panel rising from the bottom over a scrim; tapping the scrim closes it. */
function BottomPanel({ label, onClose, children }: { label: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-40 flex flex-col justify-end" role="dialog" aria-modal="true" aria-label={label}>
      <div className="absolute inset-0 bg-black/60" onClick={onClose} />
      <div className="relative bg-t1-bg">{children}</div>
    </div>
  );
}

/**
 * Options (Figma 231:9191): Chooser, Roll dice, History, New match (local trackers: back to Setup), Leave tracker.
 * Each row closes the panel first.
 */
export function TrackerOptionsPanel({
  onClose,
  onChooser,
  onDice,
  onHistory,
  onNewMatch,
  onLeave,
}: {
  onClose: () => void;
  onChooser: () => void;
  onDice: () => void;
  onHistory: () => void;
  onNewMatch?: () => void;
  onLeave: () => void;
}) {
  const row = (title: string, run: () => void) => (
    <button
      key={title}
      onClick={() => {
        onClose();
        run();
      }}
      className="w-full px-2 py-4 text-[12px] leading-[18px] tracking-[1.5px] uppercase text-t1-disabled text-center bg-t1-bg active:bg-t1-surface transition-colors duration-150"
    >
      {title}
    </button>
  );
  return (
    <BottomPanel label="Options" onClose={onClose}>
      <div className="p-4 pb-[max(64px,calc(16px+env(safe-area-inset-bottom)))] flex flex-col">
        {row("Chooser", onChooser)}
        {row("Roll dice", onDice)}
        {row("History", onHistory)}
        {onNewMatch && row("New match", onNewMatch)}
        {row("Leave tracker", onLeave)}
      </div>
    </BottomPanel>
  );
}

const DICE_KEY = "table1.lifeTracker.dice";

function readDice(): { sides: number; count: number } {
  try {
    const d = JSON.parse(localStorage.getItem(DICE_KEY) ?? "null") as { sides?: number; count?: number } | null;
    return {
      sides: DICE_SIDES.includes(d?.sides as (typeof DICE_SIDES)[number]) ? d!.sides! : 20,
      count: typeof d?.count === "number" ? Math.min(Math.max(d.count, 1), MAX_DICE) : 1,
    };
  } catch {
    return { sides: 20, count: 1 };
  }
}

/** Pick a die and how many, then Roll: the total in accent (the result), each die under it. Tapping the
 *  total rolls again. The choice of die is remembered on this device. */
export function TrackerDicePanel({ onClose }: { onClose: () => void }) {
  const [choice, setChoice] = useState(readDice);
  const [rolls, setRolls] = useState<number[]>([]);
  const [rolledAs, setRolledAs] = useState<{ sides: number; count: number } | null>(null);

  useEffect(() => {
    try {
      localStorage.setItem(DICE_KEY, JSON.stringify(choice));
    } catch {
      /* private mode: forgotten next time */
    }
  }, [choice]);

  function roll() {
    const r = rollDice(choice.sides, choice.count);
    setRolls(r);
    setRolledAs({ sides: choice.sides, count: r.length });
    navigator.vibrate?.(10);
    capture("tracker_dice_rolled", { sides: choice.sides, count: r.length });
  }

  const total = rolls.reduce((a, b) => a + b, 0);
  const caption = rolledAs
    ? [`${rolledAs.count > 1 ? rolledAs.count : ""}D${rolledAs.sides}`, diceBreakdown(rolls)].filter(Boolean).join(" · ")
    : "Tap roll";

  return (
    <BottomPanel label="Roll dice" onClose={onClose}>
      <div className="flex flex-col gap-px bg-t1-surface pb-[env(safe-area-inset-bottom)]">
        <div className="bg-t1-bg flex items-center">
          <span className={`${LABEL} flex-1 px-4 text-t1-disabled`}>Roll dice</span>
          <button onClick={onClose} className={`${LABEL} h-12 px-4 bg-t1-bg active:bg-t1-surface text-t1-text`}>
            Done
          </button>
        </div>
        <button
          onClick={roll}
          aria-label={rolls.length ? `Rolled ${total}` : "Not rolled yet"}
          className="h-[180px] bg-t1-bg active:bg-t1-surface flex flex-col items-center justify-center gap-2"
        >
          <span
            className={`text-[96px] leading-none font-semibold tracking-[-2.4px] tabular-nums ${
              rolls.length ? "text-t1-accent" : "text-t1-disabled"
            }`}
          >
            {rolls.length ? total : "–"}
          </span>
          <span className={`${LABEL} text-t1-disabled`}>{caption}</span>
        </button>
        <Segmented
          options={DICE_SIDES.map((s) => ({ value: s, label: `D${s}` }))}
          value={choice.sides}
          onChange={(sides) => setChoice((c) => ({ ...c, sides }))}
        />
        <Stepper label="Dice" value={choice.count} min={1} max={MAX_DICE} onChange={(count) => setChoice((c) => ({ ...c, count }))} />
        <BigAction label="Roll" onClick={roll} />
      </div>
    </BottomPanel>
  );
}

/** Covers the screen. Everyone puts a finger down; when the fingers have stayed put for two seconds one is
 *  picked at random and turns accent, and the tracker comes back CHOOSER_RETURN_MS later (Done leaves sooner). */
export function TrackerChooser({ onClose }: { onClose: () => void }) {
  const [state, setState] = useState(emptyChooser);
  const [now, setNow] = useState(() => performance.now());
  const surface = useRef<HTMLDivElement>(null);
  const waiting = state.winner == null && state.fingers.length >= CHOOSER_MIN_FINGERS;

  useEffect(() => capture("tracker_chooser_opened"), []);

  // Animate the rings and pick on time while enough fingers are down.
  useEffect(() => {
    if (!waiting) return;
    let frame = 0;
    const step = () => {
      const t = performance.now();
      setNow(t);
      setState((s) => chooserTick(s, t));
      frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [waiting]);

  const picked = state.winner != null;
  const fingers = state.fingers.length;
  useEffect(() => {
    if (!picked) return;
    navigator.vibrate?.(30);
    capture("tracker_chooser_picked", { fingers });
    const back = setTimeout(onClose, CHOOSER_RETURN_MS);
    return () => clearTimeout(back);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once per pick
  }, [picked]);

  const at = (e: PointerEvent) => {
    const r = surface.current!.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top] as const;
  };
  const progress = chooserProgress(state, now) ?? 0;

  return (
    <div className="fixed inset-0 z-40 bg-t1-bg select-none" role="dialog" aria-modal="true" aria-label="Chooser">
      <div
        ref={surface}
        className="absolute inset-0"
        style={{ touchAction: "none" }}
        onPointerDown={(e) => {
          try {
            e.currentTarget.setPointerCapture(e.pointerId); // a mouse keeps its finger even off the surface
          } catch {
            /* a pointer that's already gone */
          }
          const [x, y] = at(e);
          setState((s) => chooserDown(s, e.pointerId, x, y, performance.now()));
        }}
        onPointerMove={(e) => {
          const [x, y] = at(e);
          setState((s) => chooserMove(s, e.pointerId, x, y));
        }}
        onPointerUp={(e) => setState((s) => chooserUp(s, e.pointerId, performance.now()))}
        onPointerCancel={(e) => setState((s) => chooserUp(s, e.pointerId, performance.now()))}
      >
        {state.fingers.map((f) => {
          const mark = state.winner == null ? "waiting" : f.id === state.winner ? "picked" : "lost";
          const size = mark === "picked" ? 132 : 96;
          return (
            <svg
              key={f.id}
              width={size}
              height={size}
              viewBox="0 0 100 100"
              className="absolute pointer-events-none transition-[width,height] duration-200"
              style={{ left: f.x - size / 2, top: f.y - size / 2 }}
            >
              {mark === "picked" ? (
                <circle cx="50" cy="50" r="50" className="fill-t1-accent" />
              ) : mark === "lost" ? (
                <circle cx="50" cy="50" r="49" fill="none" strokeWidth="2" className="stroke-t1-disabled" />
              ) : (
                <>
                  <circle cx="50" cy="50" r="49" fill="none" strokeWidth="2" className="stroke-t1-surface" />
                  <circle
                    cx="50"
                    cy="50"
                    r="49"
                    fill="none"
                    strokeWidth="2"
                    className="stroke-t1-text"
                    pathLength={1}
                    strokeDasharray={`${progress} 1`}
                    transform="rotate(-90 50 50)"
                  />
                </>
              )}
            </svg>
          );
        })}
        {state.winner == null && state.fingers.length < CHOOSER_MIN_FINGERS && (
          <span className={`${LABEL} absolute inset-0 flex items-center justify-center text-t1-disabled pointer-events-none`}>
            {state.fingers.length ? "One more finger" : "Everyone put a finger down"}
          </span>
        )}
      </div>
      <button
        onClick={onClose}
        className={`${LABEL} absolute bottom-[env(safe-area-inset-bottom)] left-1/2 -translate-x-1/2 h-12 px-4 bg-t1-bg active:bg-t1-surface text-t1-text`}
      >
        Done
      </button>
    </div>
  );
}

/**
 * A local tracker's first screen (contract/life-tracker-commander-2026-11-03.md): how many players and their
 * starting life, then Start (the chooser opens next). Continue reopens the saved table as it was.
 */
export function TrackerSetup({
  canContinue,
  onStart,
  onContinue,
  onClose,
}: {
  canContinue: boolean;
  onStart: (players: number, life: number) => void;
  onContinue: () => void;
  onClose: () => void;
}) {
  const [pick, setPick] = useState(lastSetup);
  return (
    <div className="fixed inset-0 bg-t1-bg text-t1-text flex flex-col gap-px">
      <Bar title="Life tracker" onBack={onClose} />
      <div className="bg-t1-bg p-4 flex flex-col gap-2">
        <span className={`${LABEL} text-t1-disabled`}>Players</span>
        <Segmented
          options={PLAYER_CHOICES.map((n) => ({ value: n, label: String(n) }))}
          value={pick.players}
          onChange={(players) => setPick((p) => ({ ...p, players }))}
        />
      </div>
      <div className="bg-t1-bg p-4 flex flex-col gap-2">
        <span className={`${LABEL} text-t1-disabled`}>Starting life</span>
        <Segmented
          options={LIFE_CHOICES.map((n) => ({ value: n, label: String(n) }))}
          value={pick.life}
          onChange={(life) => setPick((p) => ({ ...p, life }))}
        />
      </div>
      <div className="flex-1" />
      {canContinue && (
        <div className="flex">
          <GhostAction label="Continue" onClick={onContinue} />
        </div>
      )}
      <div className="pb-[env(safe-area-inset-bottom)] bg-t1-text">
        <BigAction label="Start" onClick={() => onStart(pick.players, pick.life)} />
      </div>
    </div>
  );
}
