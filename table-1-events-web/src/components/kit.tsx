import { useEffect, useRef, useState, type ReactNode } from "react";
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

/** Tab bar icons (Figma 407:9333): Material, weight 300, in an 18 px box. */
const TAB_ICON = {
  events: "M13.4496 14.9207L10.6948 12.1802L13.4496 9.43987L14.2328 10.2302L12.8496 11.6179H16.125V12.7427H12.8496L14.2328 14.1302L13.4496 14.9207ZM1.875 14.625V9.73556H9.06487V14.625H1.875ZM3 13.5H7.93987V10.8606H3V13.5ZM4.55044 8.55281L3.76725 7.7625L5.15044 6.375H1.875V5.25H5.15044L3.76725 3.8625L4.55044 3.07931L7.30519 5.8125L4.55044 8.55281ZM8.93513 8.26444V3.375H16.125V8.26444H8.93513ZM10.0601 7.13944H15V4.5H10.0601V7.13944Z",
  collection: "M4.44255 10.3401L4.44255 13.6847L3.76173 13.7063L2.25011 2.325L10.4755 1.10344L10.6083 2.23838L3.51217 3.31725L4.44255 10.3401ZM6.04061 4.15388L14.4016 4.15388L14.4016 15.5481L6.04061 15.5481L6.04061 4.15388ZM7.16561 5.27888L7.16561 14.4231L13.2766 14.4231L13.2766 5.27888L7.16561 5.27888Z",
  insights: "M2.625 15.375V2.625H15.375V15.375H2.625ZM3.75 14.25H14.25V3.75H3.75V14.25ZM5.52412 12.5625H6.64894V9H5.52412V12.5625ZM11.3511 12.5625H12.4759V5.25H11.3511V12.5625ZM8.4375 12.5625H9.5625V10.5H8.4375V12.5625ZM8.4375 9H9.5625V7.5H8.4375V9Z",
  account: "M7.2735 8.8515C6.7995 8.37737 6.5625 7.80188 6.5625 7.125C6.5625 6.44813 6.7995 5.87262 7.2735 5.3985C7.74763 4.9245 8.32313 4.6875 9 4.6875C9.67687 4.6875 10.2524 4.9245 10.7265 5.3985C11.2005 5.87262 11.4375 6.44813 11.4375 7.125C11.4375 7.80188 11.2005 8.37737 10.7265 8.8515C10.2524 9.3255 9.67687 9.5625 9 9.5625C8.32313 9.5625 7.74763 9.3255 7.2735 8.8515ZM9.92662 8.05163C10.1839 7.7945 10.3125 7.48563 10.3125 7.125C10.3125 6.76437 10.1839 6.4555 9.92662 6.19838C9.6695 5.94113 9.36063 5.8125 9 5.8125C8.63937 5.8125 8.3305 5.94113 8.07337 6.19838C7.81612 6.4555 7.6875 6.76437 7.6875 7.125C7.6875 7.48563 7.81612 7.7945 8.07337 8.05163C8.3305 8.30887 8.63937 8.4375 9 8.4375C9.36063 8.4375 9.6695 8.30887 9.92662 8.05163ZM9 16.4351L2.625 12.5409V5.45906L9 1.56488L15.375 5.45906V12.5409L9 16.4351ZM9 15.1313L11.9366 13.3239C11.4875 13.0749 11.0142 12.8858 10.5167 12.7566C10.0191 12.6272 9.5135 12.5625 9 12.5625C8.4865 12.5625 7.98094 12.6272 7.48331 12.7566C6.98581 12.8858 6.5125 13.0749 6.06337 13.3239L9 15.1313ZM4.98037 12.6591C5.58125 12.2678 6.22231 11.9664 6.90356 11.7548C7.58481 11.5432 8.28362 11.4375 9 11.4375C9.71638 11.4375 10.4152 11.5432 11.0964 11.7548C11.7777 11.9664 12.4188 12.2678 13.0196 12.6591L14.25 11.925V6.09375L9 2.8875L3.75 6.09375V11.925L4.98037 12.6591Z",
};

const TABS = [
  { to: "/", end: true, title: "Events", icon: TAB_ICON.events },
  { to: "/library", end: false, title: "Collection", icon: TAB_ICON.collection },
  { to: "/insights", end: false, title: "Insights", icon: TAB_ICON.insights },
  { to: "/me", end: false, title: "Account", icon: TAB_ICON.account },
];

/** Events | Collection | Insights | Account along the bottom (Figma 407:9333), as in the apps: icon + label, the
 *  selected tab in text color under a 1 px accent line. Shown on the top-level screens once signed in, last in the
 *  screen's column wherever it's placed and pinned to the bottom of the window; a desktop window has the sidebar
 *  instead. */
export function TabNav() {
  return (
    <nav className="order-last mt-auto sticky bottom-0 z-10 shrink-0 flex bg-t1-bg pb-[env(safe-area-inset-bottom)] lg:hidden">
      {TABS.map((t) => (
        <NavLink key={t.to} to={t.to} end={t.end}
                 className={({ isActive }) =>
                   `group flex-1 min-w-0 flex flex-col items-center gap-1 pt-[10px] pb-2 border-t ${
                     isActive ? "border-t1-accent text-t1-text" : "border-transparent text-t1-muted hover:text-t1-text"
                   }`}>
          {({ isActive }) => (
            <>
              <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" fill="currentColor"><path d={t.icon} /></svg>
              <span className={`text-[9px] uppercase tracking-[1.5px] leading-[11px] truncate ${
                isActive ? "" : "text-t1-disabled group-hover:text-t1-text"}`}>{t.title}</span>
            </>
          )}
        </NavLink>
      ))}
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
  scroll,
}: {
  label?: string;
  options: { value: T; label: string; disabled?: boolean }[];
  value: T | null;
  onChange: (v: T) => void;
  /** Wrap into a grid with this many columns instead of one row. */
  columns?: number;
  /** One row of whole words that scrolls sideways when it doesn't fit (the picked option scrolled into view). */
  scroll?: boolean;
}) {
  const picked = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    if (scroll) picked.current?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [scroll, value]);
  return (
    <div className="bg-t1-surface flex flex-col">
      {label && <span className="t1-label px-4 pt-3 pb-2">{label}</span>}
      <div
        role="radiogroup"
        aria-label={label}
        className={columns ? "grid gap-px bg-t1-bg pt-px" : `flex gap-px bg-t1-bg pt-px${scroll ? " overflow-x-auto [scrollbar-width:none]" : ""}`}
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
              ref={on ? picked : undefined}
              disabled={o.disabled}
              onClick={() => onChange(o.value)}
              className={`${scroll ? "flex-[1_0_auto] whitespace-nowrap px-4" : "flex-1 min-w-0 px-2 break-words"} py-3 text-[11px] leading-[14px] uppercase tracking-[1px] disabled:opacity-40 ${
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
