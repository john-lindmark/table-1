import { useEffect, useState } from "react";
import type { TimerState } from "../lib/types";
import { computeRemaining } from "./Timer";

interface StatusBarProps {
  timer: TimerState;
}

export function StatusBar({ timer }: StatusBarProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (timer.status !== "running") return;
    const id = setInterval(() => setNow(Date.now()), 250);
    return () => clearInterval(id);
  }, [timer.status]);

  const remaining = computeRemaining(timer, now);
  const overtime = remaining < 0;
  const warning = !overtime && remaining <= 300; // < 5:00

  // 1.0 = full (start of round), 0.0 = empty (00:00), stays 0 in overtime
  const progress = overtime ? 0 : Math.max(0, Math.min(remaining / timer.durationSeconds, 1));

  const fillColor = warning ? "bg-[#d97706] dark:bg-[#fbbf24]" : "bg-[#00ffd9]/70";

  return (
    <div className="shrink-0 relative h-[64px] w-full">
      {/* Track */}
      <div
        className={`absolute inset-0 transition-colors duration-500 ${
          overtime
            ? "bg-[var(--destructive)]/30"
            : warning
              ? "bg-[#fef3c7] dark:bg-[#292315]"
              : "bg-[#e8e8ed] dark:bg-[#282839]"
        }`}
      />
      {/* Fill — drains left-to-right, teal normally, amber under 5 minutes */}
      {!overtime && (
        <div
          className={`absolute inset-y-0 left-0 transition-colors duration-500 ${fillColor}`}
          style={{ width: `${progress * 100}%` }}
        />
      )}
      {/* Overtime accent */}
      {overtime && (
        <div className="absolute inset-y-0 left-0 w-full bg-[var(--destructive)]/50" />
      )}
    </div>
  );
}
