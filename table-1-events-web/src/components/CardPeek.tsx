import { useEffect, useSyncExternalStore, type ReactNode } from "react";
import { useLocation } from "react-router-dom";
import { PEEK_W, peekPosition } from "../lib/desktop";

/* Desktop hover preview (contract/web-desktop-2026-10-22.md § Card preview): resting the pointer on a card's row
   or on a card in a stack shows the full card beside the pointer. The rows set it; one host draws it. */

interface Peek {
  node: ReactNode;
  x: number;
  y: number;
}

let current: Peek | null = null;
const subs = new Set<() => void>();
const emit = () => subs.forEach((f) => f());

export function showPeek(node: ReactNode, x: number, y: number) {
  current = { node, x, y };
  emit();
}

export function movePeek(x: number, y: number) {
  if (!current || (current.x === x && current.y === y)) return;
  current = { ...current, x, y };
  emit();
}

export function hidePeek() {
  if (!current) return;
  current = null;
  emit();
}

const subscribe = (f: () => void) => {
  subs.add(f);
  return () => subs.delete(f);
};

/** Draws the current preview. Mounted once by the shell; it clears on scroll and on navigation, since a row that
 *  scrolls away or unmounts never says the pointer left. */
export function CardPeekHost() {
  const peek = useSyncExternalStore(subscribe, () => current, () => null);
  const { pathname } = useLocation();
  useEffect(hidePeek, [pathname]);
  useEffect(() => {
    if (!peek) return;
    window.addEventListener("scroll", hidePeek, true);
    window.addEventListener("blur", hidePeek);
    return () => {
      window.removeEventListener("scroll", hidePeek, true);
      window.removeEventListener("blur", hidePeek);
    };
  }, [!!peek]);
  if (!peek) return null;
  const { left, top } = peekPosition(peek.x, peek.y, window.innerWidth, window.innerHeight);
  return (
    <div aria-hidden className="fixed z-40 pointer-events-none" style={{ left, top, width: PEEK_W }}>
      {peek.node}
    </div>
  );
}
