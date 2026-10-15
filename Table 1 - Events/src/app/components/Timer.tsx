import { useEffect, useState } from "react";
import svgPaths from "../../imports/Main/svg-2lsqwhwzs3";
import type { TimerState } from "../lib/types";

const MONO = "var(--font-sf-mono)";

// Reconstruct the visible remaining seconds from the persisted timer state.
export function computeRemaining(timer: TimerState, now: number): number {
  if (timer.status === "running" && timer.lastStartedAt != null) {
    const elapsed = Math.floor((now - timer.lastStartedAt) / 1000);
    return timer.remainingSecondsAtChange - elapsed;
  }
  return timer.remainingSecondsAtChange;
}

function format(seconds: number): string {
  const neg = seconds < 0;
  const abs = Math.abs(seconds);
  const m = Math.floor(abs / 60);
  const s = abs % 60;
  return `${neg ? "−" : ""}${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 24 24" className="size-[16px] fill-current" aria-hidden>
      <path d="M8 5v14l11-7z" />
    </svg>
  );
}

function PauseIcon() {
  return (
    <div className="relative size-[16px]">
      <div className="absolute inset-[22.92%]">
        <svg className="block size-full" fill="none" viewBox="0 0 8.66667 8.66667">
          <path d={svgPaths.p3cea0000} fill="currentColor" />
        </svg>
      </div>
    </div>
  );
}

function GearIcon() {
  return (
    <div className="relative size-[16px]">
      <div className="absolute inset-[10.42%_10.85%]">
        <svg className="block size-full" fill="none" viewBox="0 0 12.528 12.6667">
          <path d={svgPaths.pa715d00} fill="currentColor" />
        </svg>
      </div>
    </div>
  );
}

interface TimerProps {
  timer: TimerState;
  canEdit: boolean;
  onToggle: () => void;
  onOpenSettings: () => void;
}

export function Timer({ timer, canEdit, onToggle, onOpenSettings }: TimerProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (timer.status !== "running") return;
    const id = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(id);
  }, [timer.status]);

  const remaining = computeRemaining(timer, now);
  const overtime = remaining < 0;
  const warning = !overtime && remaining <= 300; // < 5:00
  const running = timer.status === "running";

  return (
    <div className="flex-[1_0_0] min-h-0 flex flex-col gap-px w-full">
      <div className="flex-[1_0_0] min-h-0 w-full flex items-center justify-center p-[32px]">
        <p
          className={`leading-none whitespace-nowrap tracking-[0.2px] tabular-nums ${
            overtime
              ? "text-[var(--destructive)]"
              : warning
                ? "text-[#d97706] dark:text-[#fbbf24]"
                : "text-[#171725] dark:text-white"
          }`}
          style={{ fontFamily: MONO, fontSize: "clamp(64px, 20vw, 158px)", fontWeight: 600 }}
          role="timer"
          aria-live="off"
        >
          {format(remaining)}
        </p>
      </div>

      <div className="flex gap-px items-center w-full">
        <div className="flex flex-[1_0_0] items-center min-w-px">
          <button
            type="button"
            onClick={onToggle}
            disabled={!canEdit}
            aria-label={running ? "Pause timer" : "Resume timer"}
            className="p-[12px] text-[#171725] dark:text-white disabled:opacity-40 focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#171725] dark:focus-visible:outline-white"
          >
            {running ? <PauseIcon /> : <PlayIcon />}
          </button>
        </div>
        <div className="flex flex-[1_0_0] items-center justify-end min-w-px">
          <button
            type="button"
            onClick={onOpenSettings}
            aria-label="Open event management"
            className="p-[12px] text-[#171725] dark:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-[#171725] dark:focus-visible:outline-white"
          >
            <GearIcon />
          </button>
        </div>
      </div>
    </div>
  );
}
