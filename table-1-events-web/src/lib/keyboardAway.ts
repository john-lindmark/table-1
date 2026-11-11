import { capture } from "./telemetry";

/* Keyboards go away on a tap outside the text box (contract/keyboard-2026-11-11.md). Phone browsers keep the
   keyboard up when a tap lands on plain content (a row's label, a heading, a chart), and a button that doesn't take
   focus leaves it up too. Touch screens only: with a mouse, a click already moves focus the usual way. Leaving a
   screen unmounts its box, which takes the keyboard with it. */

const TEXT_INPUT = "input:not([type=checkbox]):not([type=radio]):not([type=button]):not([type=submit]):not([type=reset]):not([type=range]):not([type=file]):not([type=color]), textarea, select, [contenteditable=''], [contenteditable='true']";

/** A box that holds the keyboard. */
export function isTextBox(el: Element | null): boolean {
  return !!el && el.matches(TEXT_INPUT);
}

/** True when a tap on `target` should leave the keyboard up: in a text box, on its label (which focuses a box), or
 *  on something marked `data-keeps-keyboard` (an Add used while typing names). */
export function keepsKeyboard(target: Element | null): boolean {
  return !!target?.closest(`${TEXT_INPUT}, label, [data-keeps-keyboard]`);
}

/** Further than this between touch down and up is a drag (a scroll), not a tap. */
const SLOP = 10;

export function installKeyboardAway(doc: Document = document) {
  let start: { x: number; y: number } | null = null;
  doc.addEventListener("touchstart", (e) => {
    const t = e.touches[0];
    start = e.touches.length === 1 && t ? { x: t.clientX, y: t.clientY } : null;
  }, { passive: true, capture: true });
  doc.addEventListener("touchend", (e) => {
    const t = e.changedTouches[0];
    const from = start;
    start = null;
    if (!from || !t || Math.hypot(t.clientX - from.x, t.clientY - from.y) > SLOP) return;
    const active = doc.activeElement;
    if (!isTextBox(active)) return;
    const target = e.target as Element | null;
    if (keepsKeyboard(typeof target?.closest === "function" ? target : null)) return;
    (active as HTMLElement).blur();
    capture("keyboard_dismissed", { how: "tap" });
  }, { passive: true, capture: true });
}
