import type { ReactNode } from "react";

/* Bar icons for screens outside the Library chunk (the Events home, Find, a league, a board). No new icons: these are
   the paths already in the shared set (design guidance § 5: Material Symbols Sharp, weight 300, in an 18 px box):
   `search`, `add` and `arrow_right_alt` as in Library.tsx's ICON and iOS/Android T1Icon; `list` and `tune` as card
   detail draws them. Add a new icon to all three clients in one commit, never here alone. */
export const BAR_ICON = {
  plus: "M8.4375 9.5625H4.125V8.4375H8.4375V4.125H9.5625V8.4375H13.875V9.5625H9.5625V13.875H8.4375V9.5625Z",
  search: "M14.6567 15.4328L9.94613 10.722C9.57113 11.0316 9.13987 11.2739 8.65237 11.4489C8.16487 11.6239 7.66056 11.7114 7.13944 11.7114C5.85869 11.7114 4.77406 11.2673 3.88556 10.3789C2.99719 9.49038 2.553 8.40575 2.553 7.125C2.553 5.84425 2.99719 4.75963 3.88556 3.87113C4.77406 2.98275 5.85869 2.53856 7.13944 2.53856C8.42019 2.53856 9.50481 2.98275 10.3933 3.87113C11.2817 4.75963 11.7259 5.84425 11.7259 7.125C11.7259 7.66063 11.636 8.17219 11.4562 8.65969C11.2764 9.14719 11.0364 9.57119 10.7364 9.93169L15.447 14.6422L14.6567 15.4328ZM7.13944 10.5866C8.10581 10.5866 8.92431 10.2513 9.59494 9.5805C10.2657 8.90987 10.6011 8.09138 10.6011 7.125C10.6011 6.15862 10.2657 5.34012 9.59494 4.6695C8.92431 3.99875 8.10581 3.66337 7.13944 3.66337C6.17306 3.66337 5.35456 3.99875 4.68394 4.6695C4.01319 5.34012 3.67781 6.15862 3.67781 7.125C3.67781 8.09138 4.01319 8.90987 4.68394 9.5805C5.35456 10.2513 6.17306 10.5866 7.13944 10.5866Z",
  arrow: "M10.3847 13.2403L9.59419 12.4269L12.4586 9.5625H3.375V8.4375H12.4586L9.59419 5.57306L10.3847 4.75969L14.625 9L10.3847 13.2403Z",
};

export function Icon({ d }: { d: string }) {
  return <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" className="shrink-0"><path d={d} fill="currentColor" /></svg>;
}

/** Material `list`: the details flip (card detail's drawing). */
export function ListIcon() {
  return (
    <svg viewBox="0 0 18 18" width={18} height={18} fill="currentColor" aria-hidden="true" className="shrink-0">
      {[5.668, 8.4375, 11.207].map((y) => <g key={y}><rect x={5.495} y={y} width={9.88} height={1.125} /><circle cx={3.231} cy={y + 0.563} r={0.606} /></g>)}
    </svg>
  );
}

/** Material `tune`: settings for the thing on screen (card detail's drawing). */
export function TuneIcon() {
  const r = (x: number, y: number, w: number, h: number) => <rect key={`${x},${y}`} x={2.4375 + x} y={2.4375 + y} width={w} height={h} />;
  return (
    <svg viewBox="0 0 18 18" width={18} height={18} fill="currentColor" aria-hidden="true" className="shrink-0">
      {r(0, 1.5, 7.125, 1.125)}{r(9, 0, 1.125, 4.125)}{r(10.125, 1.5, 3, 1.125)}
      {r(0, 6, 3, 1.125)}{r(3, 4.5, 1.125, 4.125)}{r(6, 6, 7.125, 1.125)}
      {r(0, 10.5, 4.125, 1.125)}{r(6, 9, 1.125, 4.125)}{r(7.125, 10.5, 6, 1.125)}
    </svg>
  );
}

/** A bar's icon action: a 50 × 50 target around an 18 px icon (design guidance § Bar). */
export function IconButton({ label, onClick, children, on }: { label: string; onClick: () => void; children: ReactNode; on?: boolean }) {
  return (
    <button type="button" aria-label={label} title={label} onClick={onClick} aria-pressed={on}
            className={`shrink-0 w-[50px] h-[50px] -my-3 flex items-center justify-center hover:text-t1-accent ${on ? "outline outline-1 -outline-offset-[10px] outline-t1-accent" : ""}`}>
      {children}
    </button>
  );
}
