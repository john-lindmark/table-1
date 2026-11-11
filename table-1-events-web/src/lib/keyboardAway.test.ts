import { describe, expect, it } from "vitest";
import { installKeyboardAway } from "./keyboardAway";

// A tap outside a text box puts the phone keyboard away (John, 2026-11-11; contract/keyboard-2026-11-11.md).
// Node has no DOM: a stand-in document with elements that answer matches/closest by their kind.

type Kind = "input" | "label" | "text" | "button" | "keeps";
class El {
  blurred = false;
  constructor(readonly kind: Kind, readonly parent?: El) {}
  matches(sel: string) { return this.kind === "input" && sel.includes("input"); }
  closest(sel: string): El | null {
    for (let e: El | undefined = this; e; e = e.parent) {
      if (e.kind === "input" || (e.kind === "label" && sel.includes("label")) || (e.kind === "keeps" && sel.includes("data-keeps-keyboard"))) return e;
    }
    return null;
  }
  blur() { this.blurred = true; }
}

function page() {
  const listeners: Record<string, (e: unknown) => void> = {};
  const box = new El("input");
  const doc = {
    activeElement: box as El | null,
    addEventListener: (type: string, fn: (e: unknown) => void) => { listeners[type] = fn; },
  };
  installKeyboardAway(doc as unknown as Document);
  const tap = (target: El, move = 0) => {
    listeners.touchstart({ touches: [{ clientX: 10, clientY: 10 }] });
    listeners.touchend({ target, changedTouches: [{ clientX: 10, clientY: 10 + move }] });
  };
  return { box, doc, tap };
}

describe("keyboard away", () => {
  it("a tap on plain content puts it away", () => {
    const p = page();
    p.tap(new El("text"));
    expect(p.box.blurred).toBe(true);
  });

  it("a button tap puts it away too", () => {
    const p = page();
    p.tap(new El("button"));
    expect(p.box.blurred).toBe(true);
  });

  it("a tap in the box, on its label or on a kept button leaves it up", () => {
    const p = page();
    p.tap(p.box);
    p.tap(new El("text", new El("label")));
    p.tap(new El("text", new El("keeps")));
    expect(p.box.blurred).toBe(false);
  });

  it("a drag isn't a tap", () => {
    const p = page();
    p.tap(new El("text"), 40);
    expect(p.box.blurred).toBe(false);
  });

  it("does nothing when no box has the keyboard", () => {
    const p = page();
    const button = new El("button");
    p.doc.activeElement = button;
    p.tap(new El("text"));
    expect(button.blurred).toBe(false);
  });
});
