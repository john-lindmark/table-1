import { useEffect, useState, type ReactNode } from "react";
import type { RoundWithMatches } from "../lib/types";

/* Shared primitives for the Table 1 look: hard rectangles, 1px hairline gaps,
   monospace uppercase labels, one teal accent. */

export function Screen({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-[100dvh] w-full bg-t1-bg text-t1-text flex flex-col gap-px">
      {children}
    </div>
  );
}

export function Bar({
  title,
  subtitle,
  right,
}: {
  title: string;
  subtitle?: string;
  right?: ReactNode;
}) {
  return (
    <div className="shrink-0 bg-t1-surface px-4 py-3 flex items-center justify-between gap-3">
      <div className="min-w-0">
        <p className="text-[13px] tracking-[0.5px] truncate">{title}</p>
        {subtitle && <p className="t1-label truncate">{subtitle}</p>}
      </div>
      {right}
    </div>
  );
}

export function Label({ children }: { children: ReactNode }) {
  return <p className="t1-label">{children}</p>;
}

export function BigAction({
  label,
  onClick,
  disabled,
  busy,
  tone = "primary",
}: {
  label: string;
  onClick: () => void;
  disabled?: boolean;
  busy?: boolean;
  tone?: "primary" | "accent";
}) {
  const off = disabled || busy;
  const base =
    tone === "accent"
      ? "bg-t1-accent text-t1-ink"
      : "bg-t1-text text-t1-bg";
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={off}
      className={`w-full px-4 py-7 flex items-center justify-center transition-colors ${
        off ? "bg-t1-disabled text-t1-ink" : base
      }`}
    >
      <span className="text-[17px] leading-6 text-center tracking-[5px] uppercase font-bold">
        {busy ? "Working…" : label}
      </span>
    </button>
  );
}

export function GhostAction({
  label,
  onClick,
  disabled,
}: {
  label: string;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="flex-1 bg-t1-surface hover:bg-t1-surface-hover disabled:opacity-40 px-4 py-3 text-[11px] uppercase tracking-[1px]"
    >
      {label}
    </button>
  );
}

export function Field({
  label,
  value,
  onChange,
  placeholder,
  type = "text",
  autoFocus,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
  autoFocus?: boolean;
}) {
  return (
    <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
      <span className="t1-label">{label}</span>
      <input
        type={type}
        value={value}
        autoFocus={autoFocus}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full"
      />
    </label>
  );
}

export function Notice({ tone, children }: { tone: "error" | "info"; children: ReactNode }) {
  return (
    <div
      className={`px-4 py-3 text-[12px] leading-[18px] ${
        tone === "error" ? "bg-t1-danger/15 text-t1-danger" : "bg-t1-surface text-t1-muted"
      }`}
    >
      {children}
    </div>
  );
}

/* ── timer ───────────────────────────────────────────────────────────────────
   Persisted as duration + remaining-at-last-change + a start timestamp, then
   reconstructed on the client. That is what makes the same clock appear on
   every phone at the table and survive a reload. */

export function computeRemaining(round: RoundWithMatches | null, now: number): number {
  if (!round) return 0;
  if (round.timerStatus === "running" && round.timerLastStartedAt) {
    const started = new Date(round.timerLastStartedAt).getTime();
    return round.timerRemainingAtChange - Math.floor((now - started) / 1000);
  }
  return round.timerRemainingAtChange;
}

export function formatClock(seconds: number): string {
  const negative = seconds < 0;
  const abs = Math.abs(seconds);
  const m = Math.floor(abs / 60);
  const s = abs % 60;
  return `${negative ? "−" : ""}${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export function useNow(active: boolean): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    const id = window.setInterval(() => setNow(Date.now()), 250);
    return () => window.clearInterval(id);
  }, [active]);
  return now;
}

export function ClockFace({
  round,
  size = "large",
}: {
  round: RoundWithMatches | null;
  size?: "large" | "small";
}) {
  const now = useNow(round?.timerStatus === "running");
  const remaining = computeRemaining(round, now);
  const overtime = remaining < 0;
  const warning = !overtime && remaining <= 300;
  const color = overtime ? "text-t1-danger" : warning ? "text-t1-warning" : "text-t1-text";
  return (
    <p
      role="timer"
      className={`tabular-nums leading-none tracking-[1px] text-center ${color}`}
      style={{ fontSize: size === "large" ? "clamp(56px, 18vw, 140px)" : "28px", fontWeight: 600 }}
    >
      {formatClock(remaining)}
    </p>
  );
}

export function TimerProgress({ round }: { round: RoundWithMatches | null }) {
  const now = useNow(round?.timerStatus === "running");
  const remaining = computeRemaining(round, now);
  const duration = round?.timerDurationSeconds ?? 1;
  const overtime = remaining < 0;
  const warning = !overtime && remaining <= 300;
  const progress = overtime ? 0 : Math.max(0, Math.min(remaining / duration, 1));
  return (
    <div className="relative h-[10px] w-full shrink-0 bg-t1-surface">
      {overtime ? (
        <div className="absolute inset-0 bg-t1-danger/50" />
      ) : (
        <div
          className={`absolute inset-y-0 left-0 ${warning ? "bg-t1-warning" : "bg-t1-accent/70"}`}
          style={{ width: `${progress * 100}%` }}
        />
      )}
    </div>
  );
}
