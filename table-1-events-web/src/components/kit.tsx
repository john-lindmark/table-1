import { useEffect, useState, type ReactNode } from "react";
import { NavLink } from "react-router-dom";
import type { RoundWithMatches } from "../lib/types";

/* Shared primitives for the Table 1 look: hard rectangles, 1px hairline gaps,
   monospace uppercase labels, one teal accent. */

/** How wide a screen gets on a desktop window (contract/web-desktop-2026-10-22.md): `column` (default) is a
 *  centered column for lists and forms; `wide` for card grids, decks and running an event; `full` for the signed-out
 *  landing page. Phones fill the width either way. */
export type ScreenWidth = "column" | "wide" | "full";
export const SCREEN_WIDTH: Record<ScreenWidth, string> = {
  column: "lg:max-w-[960px] lg:mx-auto",
  wide: "lg:max-w-[1600px] lg:mx-auto",
  full: "",
};

export function Screen({ children, width = "column" }: { children: ReactNode; width?: ScreenWidth }) {
  return (
    <div className={`min-h-[100dvh] w-full bg-t1-bg text-t1-text flex flex-col gap-px ${SCREEN_WIDTH[width]}`}>
      {children}
    </div>
  );
}

/**
 * Two columns on a desktop window: the main content and a narrower aside (standings next to a round, Join next to
 * your events). On a phone they stack, main first. `at="xl"` waits for 1280 px, for a main column that needs the room
 * (the round clock).
 */
const COLUMNS_AT = {
  lg: { row: "lg:flex-row lg:items-start", main: "lg:flex-1", aside: "lg:shrink-0 lg:w-[var(--aside-w)]" },
  xl: { row: "xl:flex-row xl:items-start", main: "xl:flex-1", aside: "xl:shrink-0 xl:w-[var(--aside-w)]" },
};
export function Columns({ children, aside, asideWidth = 360, at = "lg" }: {
  children: ReactNode; aside?: ReactNode; asideWidth?: number; at?: "lg" | "xl";
}) {
  if (!aside) return <>{children}</>;
  const c = COLUMNS_AT[at];
  return (
    <div className={`flex flex-col gap-px ${c.row}`}>
      <div className={`min-w-0 flex flex-col gap-px ${c.main}`}>{children}</div>
      <div className={`min-w-0 flex flex-col gap-px ${c.aside}`} style={{ ["--aside-w" as string]: `${asideWidth}px` }}>
        {aside}
      </div>
    </div>
  );
}

/** Esc closes a dialog or menu on a keyboard. */
export function useEscape(onEscape: () => void) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onEscape();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
}

/** Material "arrow_left_alt" (weight 300) from the Figma Bar (node 95:11022). */
export function BackArrow({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 18 18" width={18} height={18} className={className} fill="currentColor" aria-hidden="true">
      <path d="M7.464 13.2403L3.2235 9L7.464 4.75969L8.25431 5.57306L5.38987 8.4375H14.7765V9.5625H5.38987L8.25431 12.4269L7.464 13.2403Z" />
    </svg>
  );
}

export function Bar({
  title,
  subtitle,
  right,
  onBack,
}: {
  title: string;
  subtitle?: string;
  right?: ReactNode;
  /** Screens pushed above a tab's main view lead with the back arrow. */
  onBack?: () => void;
}) {
  return (
    <div className={`shrink-0 bg-t1-surface ${onBack ? "pr-4" : "px-4"} py-3 flex items-center justify-between gap-3`}>
      {onBack && (
        <button type="button" onClick={onBack} aria-label="Back"
                className="shrink-0 w-[50px] h-[50px] -my-3 -mr-3 flex items-center justify-center hover:text-t1-accent">
          <BackArrow />
        </button>
      )}
      <div className="min-w-0 flex-1">
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
  onBlur,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  type?: string;
  autoFocus?: boolean;
  /** Commit point for fields that save as you go. */
  onBlur?: () => void;
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
        onBlur={onBlur}
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

export function useNow(active: boolean, intervalMs = 250): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    setNow(Date.now());
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [active, intervalMs]);
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

/* ── brand ───────────────────────────────────────────────────────────────────
   The Table 1 mark: eleven tiles on a 6 × 3 grid, from the library's "Table 1 Logo"
   vector (393 × 192.69). Fills with the current text color. */

const TILES: [number, number][] = [
  [0, 0], [1, 0], [2, 0], [3, 0], [4, 0],
  [1, 1], [4, 1],
  [1, 2], [3, 2], [4, 2], [5, 2],
];

export function T1Logo({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 393 192.69" className={className} role="img" aria-label="Table 1" fill="currentColor">
      {TILES.map(([c, r]) => (
        <rect key={`${c}-${r}`} x={c * 65.8036} y={r * 64.8302} width={63.982} height={63.0294} />
      ))}
    </svg>
  );
}

/** Events | Collection | Account. Shown on the top-level screens once signed in; a desktop window has the
 *  sidebar instead. */
export function TopNav() {
  const tab = ({ isActive }: { isActive: boolean }) =>
    `flex-1 py-3 text-center text-[11px] uppercase tracking-[1.5px] ${
      isActive ? "bg-t1-accent text-t1-ink" : "bg-t1-surface hover:bg-t1-surface-hover text-t1-text"
    }`;
  return (
    <nav className="shrink-0 flex gap-px items-stretch lg:hidden">
      <div className="bg-t1-surface px-4 flex items-center">
        <T1Logo className="h-4 w-auto" />
      </div>
      <NavLink to="/" end className={tab}>
        Events
      </NavLink>
      <NavLink to="/library" className={tab}>
        Collection
      </NavLink>
      <NavLink to="/insights" className={tab}>
        Insights
      </NavLink>
      <NavLink to="/me" className={tab}>
        Account
      </NavLink>
    </nav>
  );
}

/** Counts down to a fixed end time (ISO or epoch seconds), or shows a paused clock. */
export function Countdown({
  endsAt,
  paused,
  size = 56,
}: {
  endsAt?: string | number | null;
  paused?: number | null;
  size?: number;
}) {
  const end = endsAt == null ? null : typeof endsAt === "number" ? endsAt * 1000 : new Date(endsAt).getTime();
  const now = useNow(end != null);
  if (end == null) {
    if (paused == null) return null;
    return (
      <p className="tabular-nums text-t1-muted" style={{ fontSize: size, letterSpacing: size / 14 }}>
        {formatClock(paused)}
      </p>
    );
  }
  const left = Math.max(0, Math.floor((end - now) / 1000));
  return (
    <p
      role="timer"
      className={`tabular-nums ${left === 0 ? "text-t1-danger" : "text-t1-text"}`}
      style={{ fontSize: size, letterSpacing: size / 14 }}
    >
      {left === 0 ? "TIME" : formatClock(left)}
    </p>
  );
}

export function Stat({ label, value, accent, end }: { label: string; value: string; accent?: boolean; end?: boolean }) {
  return (
    <div className={`flex-1 min-w-0 flex flex-col gap-0.5 ${end ? "items-end text-right" : ""}`}>
      <span className="t1-label">{label}</span>
      <span className={`text-[17px] truncate ${accent ? "text-t1-accent" : ""}`}>{value}</span>
    </div>
  );
}

export function shortWhen(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

/* ── form controls ─────────────────────────────────────────────────────── */

/** One-of-n picker: a labelled row of hairline-separated buttons. */
export function Segmented<T extends string | number>({
  label,
  options,
  value,
  onChange,
  columns,
}: {
  label?: string;
  options: { value: T; label: string; disabled?: boolean }[];
  value: T | null;
  onChange: (v: T) => void;
  /** Wrap into a grid with this many columns instead of one row. */
  columns?: number;
}) {
  return (
    <div className="bg-t1-surface flex flex-col">
      {label && <span className="t1-label px-4 pt-3 pb-2">{label}</span>}
      <div
        role="radiogroup"
        aria-label={label}
        className={columns ? "grid gap-px bg-t1-bg pt-px" : "flex gap-px bg-t1-bg pt-px"}
        style={columns ? { gridTemplateColumns: `repeat(${columns}, minmax(0, 1fr))` } : undefined}
      >
        {options.map((o) => {
          const on = o.value === value;
          return (
            <button
              key={String(o.value)}
              type="button"
              role="radio"
              aria-checked={on}
              disabled={o.disabled}
              onClick={() => onChange(o.value)}
              className={`flex-1 min-w-0 px-2 py-3 text-[11px] leading-[14px] uppercase tracking-[1px] break-words disabled:opacity-40 ${
                on ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover text-t1-text"
              }`}
            >
              {o.label}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/** − value + with bounds. */
export function Stepper({
  label,
  value,
  onChange,
  min,
  max,
  suffix,
  step = 1,
}: {
  label: string;
  value: number;
  onChange: (v: number) => void;
  min: number;
  max: number;
  suffix?: string;
  step?: number;
}) {
  const btn = "w-14 self-stretch bg-t1-bg hover:bg-t1-surface-hover text-[20px] disabled:opacity-30";
  return (
    <div className="bg-t1-surface flex items-stretch">
      <span className="flex-1 px-4 py-3 flex flex-col gap-0.5">
        <span className="t1-label">{label}</span>
        <span className="text-[17px] tabular-nums">
          {value}
          {suffix ? <span className="t1-label ml-2">{suffix}</span> : null}
        </span>
      </span>
      <button type="button" aria-label={`Fewer ${label.toLowerCase()}`} className={btn} disabled={value <= min} onClick={() => onChange(Math.max(min, value - step))}>
        −
      </button>
      <button type="button" aria-label={`More ${label.toLowerCase()}`} className={`${btn} ml-px`} disabled={value >= max} onClick={() => onChange(Math.min(max, value + step))}>
        +
      </button>
    </div>
  );
}

/** A settings row with an on/off switch. */
export function SwitchRow({
  label,
  detail,
  on,
  onChange,
  disabled,
}: {
  label: string;
  detail?: string;
  on: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      disabled={disabled}
      onClick={() => onChange(!on)}
      className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3 text-left w-full disabled:opacity-50"
    >
      <span className="flex-1 min-w-0 flex flex-col">
        <span className="text-[13px]">{label}</span>
        {detail && <span className="t1-label truncate">{detail}</span>}
      </span>
      <span className={`relative w-10 h-5 shrink-0 ${on ? "bg-t1-accent" : "bg-t1-bg"}`}>
        <span className={`absolute top-0.5 size-4 transition-all ${on ? "left-[22px] bg-t1-ink" : "left-0.5 bg-t1-muted"}`} />
      </span>
    </button>
  );
}

/** Centered dialog over a dimmed page. */
export function Modal({
  title,
  children,
  onClose,
}: {
  title?: string;
  children: ReactNode;
  onClose: () => void;
}) {
  useEscape(onClose);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true" aria-label={title}>
      <div className="absolute inset-0 bg-black/70" onClick={onClose} />
      <div className="relative bg-t1-bg w-[90%] max-w-[380px] p-6 flex flex-col gap-4 border border-t1-surface">
        {title && <p className="text-[15px]">{title}</p>}
        {children}
      </div>
    </div>
  );
}

export interface MenuItem {
  title: string;
  detail?: string;
  checked?: boolean;
  onClick: () => void;
}

/** The T1 menu (iOS T1MenuPanel): hairline rows rising from the bottom over a scrim, then Cancel; centered on a
 *  desktop window. The item's action runs after the menu closes. */
export function Menu({ title, items, onClose }: { title?: string; items: MenuItem[]; onClose: () => void }) {
  useEscape(onClose);
  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end lg:justify-center" role="dialog" aria-modal="true" aria-label={title}>
      <div className="absolute inset-0 bg-black/60" onClick={onClose} />
      <div className="relative bg-t1-bg pt-px flex flex-col gap-px w-full max-w-[480px] mx-auto lg:max-w-[420px] lg:max-h-[80dvh] lg:overflow-y-auto lg:p-px">
        {title && <div className="bg-t1-surface px-4 py-3 t1-label">{title}</div>}
        {items.map((it) => (
          <button key={it.title} type="button" role="menuitemradio" aria-checked={!!it.checked}
                  onClick={() => { onClose(); it.onClick(); }}
                  className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 flex items-center gap-3 text-left w-full">
            <span className="flex-1 min-w-0 flex flex-col gap-0.5">
              <span className="text-[15px] truncate">{it.title}</span>
              {it.detail && <span className="t1-label truncate">{it.detail}</span>}
            </span>
            {it.checked && <span className="t1-label !text-t1-accent">Selected</span>}
          </button>
        ))}
        <button type="button" onClick={onClose} className="bg-t1-surface-hover py-[18px] t1-label !text-t1-text">Cancel</button>
      </div>
    </div>
  );
}

/**
 * The T1 alert dialog (the web's stand-in for a native alert): title, message, optional body
 * (e.g. a reason field), a cancel button and one action. Never use window.confirm/alert.
 */
export function Dialog({
  title,
  message,
  children,
  cancelLabel,
  confirmLabel,
  busyLabel,
  onCancel,
  onConfirm,
  busy,
  error,
  tone = "primary",
}: {
  title: string;
  message?: ReactNode;
  children?: ReactNode;
  cancelLabel: string;
  confirmLabel: string;
  busyLabel?: string;
  onCancel: () => void;
  onConfirm: () => void;
  busy?: boolean;
  error?: string | null;
  tone?: "primary" | "danger";
}) {
  return (
    <Modal title={title} onClose={() => !busy && onCancel()}>
      {message && <p className="text-[12px] leading-[18px] text-t1-muted">{message}</p>}
      {children}
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex gap-px">
        <GhostAction label={cancelLabel} onClick={onCancel} disabled={busy} />
        <button
          type="button"
          onClick={onConfirm}
          disabled={busy}
          className={`flex-1 px-4 py-3 text-[11px] uppercase tracking-[1px] disabled:opacity-60 ${
            tone === "danger" ? "bg-t1-danger text-white" : "bg-t1-text text-t1-bg"
          }`}
        >
          {busy ? busyLabel ?? "Working…" : confirmLabel}
        </button>
      </div>
    </Modal>
  );
}

/** A list section header: "Players · 8". */
export function Section({ title, count, right }: { title: string; count?: number; right?: ReactNode }) {
  return (
    <div className="shrink-0 bg-t1-surface px-4 py-2 flex items-center justify-between gap-3 t1-label">
      <span className="truncate">{count == null ? title : `${title} · ${count}`}</span>
      {right}
    </div>
  );
}

/**
 * A list row: title, optional detail line, and a value on the right. With `onClick` the whole row is
 * tappable; with `action` a separate button sits at the right edge instead of the value. `avatar` sits left of the
 * title.
 */
export function Row({
  title,
  detail,
  value,
  onClick,
  action,
  dim,
  accentValue,
  avatar,
}: {
  title: ReactNode;
  detail?: ReactNode;
  value?: ReactNode;
  onClick?: () => void;
  action?: { label: string; onClick: () => void; disabled?: boolean };
  dim?: boolean;
  accentValue?: boolean;
  /** A player's tile left of the name. */
  avatar?: ReactNode;
}) {
  const body = (
    <>
      {avatar}
      <span className={`flex-1 min-w-0 flex flex-col gap-0.5 ${dim ? "opacity-60" : ""}`}>
        <span className="text-[13px] truncate">{title}</span>
        {detail && <span className="t1-label truncate">{detail}</span>}
      </span>
      {value != null && value !== "" && (
        <span className={`shrink-0 text-[13px] tabular-nums ${accentValue ? "text-t1-accent" : ""}`}>{value}</span>
      )}
    </>
  );
  if (onClick) {
    return (
      <button
        type="button"
        onClick={onClick}
        className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3 text-left w-full"
      >
        {body}
      </button>
    );
  }
  return (
    <div className="bg-t1-surface px-4 py-3 flex items-center gap-3">
      {body}
      {action && (
        <button
          type="button"
          onClick={action.onClick}
          disabled={action.disabled}
          className="shrink-0 t1-label hover:text-t1-text disabled:opacity-40 px-2 py-1 -my-1"
        >
          {action.label}
        </button>
      )}
    </div>
  );
}

/** A row of tabs; the selected one is inverted. */
export function TabBar<T extends string>({
  tabs,
  value,
  onChange,
  labels,
}: {
  tabs: T[];
  value: T;
  onChange: (t: T) => void;
  labels: Record<T, string>;
}) {
  return (
    <div role="tablist" className="flex gap-px shrink-0">
      {tabs.map((t) => (
        <button
          key={t}
          type="button"
          role="tab"
          aria-selected={value === t}
          onClick={() => onChange(t)}
          className={`flex-1 min-w-0 px-2 py-3 text-[11px] uppercase tracking-[1px] truncate ${
            value === t ? "bg-t1-text text-t1-bg" : "bg-t1-surface text-t1-muted hover:bg-t1-surface-hover"
          }`}
        >
          {labels[t]}
        </button>
      ))}
    </div>
  );
}

/** Big Number style: the round clock on the organizer's Live view. */
export function BigNumber({ children, tone = "normal" }: { children: ReactNode; tone?: "normal" | "warning" | "danger" | "muted" }) {
  const color =
    tone === "danger" ? "text-t1-danger" : tone === "warning" ? "text-t1-warning" : tone === "muted" ? "text-t1-muted" : "text-t1-text";
  return (
    <p
      role="timer"
      className={`tabular-nums leading-none tracking-[1px] text-center ${color}`}
      style={{ fontSize: "clamp(56px, 18vw, 140px)", fontWeight: 600 }}
    >
      {children}
    </p>
  );
}

/** The winner at the top of final standings: small accent label, the name, a caption, optional members line. */
export function WinnerCard({
  label,
  name,
  caption,
  line,
}: {
  label: string;
  name: string;
  caption: string;
  line?: string | null;
}) {
  return (
    <div className="bg-t1-surface px-4 py-5 flex flex-col gap-1.5">
      <span className="text-[10px] uppercase tracking-[2px] text-t1-accent font-bold">{label}</span>
      <span className="text-[22px] leading-[28px] tracking-[0.5px] break-words">{name}</span>
      <span className="t1-label">{caption}</span>
      {line && <span className="text-[12px] leading-[18px] text-t1-muted">{line}</span>}
    </div>
  );
}
