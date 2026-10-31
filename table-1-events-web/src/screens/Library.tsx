import { useCallback, useEffect, useMemo, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { Bar, Field, Menu, Notice, Row, SCREEN_WIDTH, Screen, Segmented, TabNav, type ScreenWidth } from "../components/kit";
import { capture } from "../lib/telemetry";
import { LAYOUTS, parseLayout, runStacks, type CardLayout } from "../lib/cardLayout";
import { GROUPING_KEY, GROUPING_TITLE, groupLabel, groupSections, groupingOptions, keysOf, useStoredGrouping, type Grouping } from "../lib/cardGrouping";
import { SORT_KEY, SORT_TITLE, applySort, sortKeyOf, sortOptions, useStoredSort, type CardSort, type SortScreen } from "../lib/cardSort";
import { SignInButtons } from "../components/SignInButtons";
import { errorMessage } from "../lib/api";
import {
  basicCardIds, cardImageUrl, cornerRatio, coverPrinting, formatName, loadCatalog, normName, type Catalog,
} from "../lib/catalog";
import {
  useCollection, type Finish, type Item,
} from "../lib/collection";
import { useSession } from "../lib/useSession";
import { isLibraryDemo, loadDemoLists } from "../lib/libraryDemo";
import { DEMO_USER, outboxNotice, type Condition } from "../lib/collection";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import { itemsIn, useBinders } from "../lib/binders";
import { entriesOf, useLists } from "../lib/lists";
import { followHref, followTitle, loadFollows, useFollows } from "../lib/follows";
import type { SectionKind } from "../lib/friends";
import { COLLAPSED, addPart, isOpen, priceRank, setAll, sortParts, toggleOne, type Disclosure, type Part } from "../lib/printings";
import { COLLECTION_SCOPE, heroPrintings, heroesOf, isHero, startDemoHeroes, useHeroes } from "../lib/heroes";
import { CardSearchBar, CardSearchStatus, useCardSearch } from "./CardSearch";
import { hasSyntax } from "../lib/cardQuery";
import { hidePeek, movePeek, showPeek } from "../components/CardPeek";
import { PEEK_W, useHoverPreview } from "../lib/desktop";
import { ShareButton } from "./Share";

export const CONDITIONS: Condition[] = ["NM", "LP", "MP", "HP", "DMG"];

/** Condition new copies go in as (remembered; card page, Add to collection). */
export function useAddCondition(): [Condition, (c: Condition) => void] {
  const [c, setC] = useState<Condition>(() => {
    try {
      const v = localStorage.getItem("table1.library.addCondition") as Condition | null;
      return v && CONDITIONS.includes(v) ? v : "NM";
    } catch {
      return "NM";
    }
  });
  const set = (next: Condition) => {
    setC(next);
    try {
      localStorage.setItem("table1.library.addCondition", next);
    } catch {
      /* storage blocked */
    }
  };
  return [c, set];
}
export const CONDITION_NAME: Record<Condition, string> = {
  NM: "Near mint", LP: "Lightly played", MP: "Moderately played", HP: "Heavily played", DMG: "Damaged",
};

/** The signed-in session, or (dev server, `?demo`) a stand-in account for the demo collection. */
export function useLibrarySession() {
  const real = useSession();
  if (import.meta.env.DEV && isLibraryDemo()) return { session: true, ready: true, userId: DEMO_USER, demo: true };
  return { ...real, demo: false };
}

/* Library (Collection tab), web. Progressive disclosure: the home screen is a summary; the list, a card's
   printings and its history are each one tap deeper. Built ahead of the Figma Library screens on the
   existing kit; restyle once those land. */

export function useCatalog() {
  const [catalog, setCatalog] = useState<Catalog | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    loadCatalog().then((c) => live && setCatalog(c), (e) => live && setError(errorMessage(e)));
    return () => {
      live = false;
    };
  }, []);
  return { catalog, error };
}

export const money = (n: number | null | undefined, cur: "USD" | "EUR") =>
  n == null ? "—" : new Intl.NumberFormat(undefined, { style: "currency", currency: cur, maximumFractionDigits: 0 }).format(n);
const FINISH_LABEL: Record<Finish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };

export function SignedOut({ title }: { title: string }) {
  return (
    <Screen>
      <Bar title={title} />
      <Notice tone="info">Sign in to keep your collection.</Notice>
      <SignInButtons returnTo="/library" />
    </Screen>
  );
}

export function Back({ onClick }: { onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} className="t1-label hover:text-t1-text px-2 py-1 -my-1">
      Back
    </button>
  );
}

const LAYOUT_TITLE: Record<CardLayout, string> = { list: "List", grid: "Grid", stacks: "Stacks" };

/** The layout saved for a screen family. `legacyGridKey` is the old List/Grid flag, read once so a saved grid stays. */
export function useStoredLayout(key: string, legacyGridKey: string): [CardLayout, (v: CardLayout) => void] {
  const [v, setV] = useState<CardLayout>(() => {
    try {
      return parseLayout(localStorage.getItem(key), localStorage.getItem(legacyGridKey));
    } catch {
      return "list";
    }
  });
  const set = (next: CardLayout) => {
    setV(next);
    try {
      localStorage.setItem(key, next);
    } catch {
      /* storage blocked: keep it for this visit */
    }
  };
  return [v, set];
}

/** The bar's "View" button: a menu of the three layouts, the current one marked, then expanding or collapsing every
 *  card's printings when the screen has them, then Group by (contract/shared-lists-grouping-2026-10-20.md §4), then
 *  Sort (contract/card-sort-2026-10-25.md). */
export function ViewButton({ layout, onChange, screen, printings, onPrintings, grouping, onGrouping, list = false, sort, onSort, sorts }: {
  layout: CardLayout; onChange: (v: CardLayout) => void; screen: "all_cards" | "deck" | "cube" | "binder" | `profile_${SectionKind}`;
  printings?: Disclosure; onPrintings?: (d: Disclosure) => void;
  grouping?: Grouping; onGrouping?: (g: Grouping) => void;
  /** A deck or cube: Group by has no None. */
  list?: boolean;
  sort?: CardSort; onSort?: (s: CardSort) => void; sorts?: SortScreen;
}) {
  const [open, setOpen] = useState(false);
  const all = !!printings?.all;
  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">View</button>
      {open && (
        <Menu title="View" onClose={() => setOpen(false)} items={[...LAYOUTS.map((l) => ({
          title: LAYOUT_TITLE[l],
          checked: l === layout,
          onClick: () => {
            if (l === layout) return;
            onChange(l);
            capture("card_layout_changed", { layout: l, screen });
          },
        })), ...(printings && onPrintings ? [{
          title: all ? "Collapse all printings" : "Expand all printings",
          detail: all ? "One row per card" : "Every printing and finish on its own row",
          onClick: () => {
            onPrintings(setAll(!all));
            capture("printings_toggled", { expanded: !all, all: true, screen: screen === "all_cards" || screen === "binder" ? screen : "list" });
          },
        }] : []), ...(grouping && onGrouping ? groupingOptions(list).map((g) => ({
          title: GROUPING_TITLE[g],
          checked: g === grouping,
          onClick: () => {
            if (g === grouping) return;
            onGrouping(g);
            capture("card_grouping_changed", { grouping: g, screen });
          },
        })) : []), ...(sort && onSort && sorts ? sortOptions(sorts).map((o) => ({
          title: SORT_TITLE[o],
          checked: o === sort,
          onClick: () => {
            if (o === sort) return;
            onSort(o);
            capture("card_sort_changed", { sort: o, screen });
          },
        })) : [])]} />
      )}
    </>
  );
}

/** A full-height screen whose lists scroll inside it (Screen only sets a minimum height, which lets a list
 *  grow to its full length and defeats virtualization). */
export function LibScreen({ children, width = "column" }: { children: ReactNode; width?: ScreenWidth }) {
  return <div className={`h-[100dvh] w-full bg-t1-bg text-t1-text flex flex-col gap-px overflow-hidden ${SCREEN_WIDTH[width]}`}>{children}</div>;
}

/* ── card images ──────────────────────────────────────────────────────
   Straight from Scryfall's CDN. The smallest rendition that covers the drawn pixels (small ≈ 10 KB for
   thumbnails), fixed width/height so nothing reflows, lazy + async decode, and the browser's HTTP cache
   for repeats. Virtualized lists unmount off-screen rows, which cancels their pending image loads. */

const ASPECT = 488 / 680;

export type CardFinish = "nonfoil" | "foil" | "etched";

/** A foil's rainbow sheen over the card image (contract/library-polish-2026-10-19.md § Foil): a diagonal spectrum
 *  blended into the art plus one soft highlight band. Etched foils are matte, so theirs is dimmer. */
const SPECTRUM = "linear-gradient(135deg, rgb(255,115,191), rgb(255,217,102), rgb(115,255,179), rgb(89,191,255), rgb(191,128,255), rgb(255,115,191))";
const HIGHLIGHT = "linear-gradient(135deg, transparent 30%, rgba(255,255,255,0.35) 45%, transparent 60%)";
function FoilSheen({ etched, radius }: { etched: boolean; radius: number }) {
  return (
    <>
      <span aria-hidden className="absolute inset-0 pointer-events-none"
            style={{ background: SPECTRUM, mixBlendMode: "overlay", opacity: etched ? 0.3 : 0.55, borderRadius: radius }} />
      <span aria-hidden className="absolute inset-0 pointer-events-none"
            style={{ background: HIGHLIGHT, mixBlendMode: "soft-light", opacity: etched ? 0.5 : 1, borderRadius: radius }} />
    </>
  );
}

export function CardArt({ c, p, width, alt = "", finish = "nonfoil", back = false }: {
  c: Catalog; p: number | null; width: number; alt?: string; finish?: CardFinish; /** A double-faced card's back. */ back?: boolean;
}) {
  const height = Math.round(width / ASPECT);
  const radius = p == null ? width * 0.0432 : width * cornerRatio(c.pSet[p]);
  if (p == null || c.pFaces[p] === 0) {
    return <div className="bg-t1-bg shrink-0" style={{ width, height, borderRadius: radius }} />;
  }
  const px = width * (typeof window === "undefined" ? 1 : window.devicePixelRatio || 1);
  const size = px <= 146 ? "small" : px <= 488 ? "normal" : "large";
  const img = (
    <img src={cardImageUrl(c, p, size, back && c.pFaces[p] > 1)} alt={alt} width={width} height={height} loading="lazy" decoding="async"
         draggable={false} className="bg-t1-bg shrink-0 object-cover block" style={{ width, height, borderRadius: radius }} />
  );
  if (finish === "nonfoil") return img;
  return (
    <span className="relative shrink-0 block isolate" style={{ width, height }}>
      {img}
      <FoilSheen etched={finish === "etched"} radius={radius} />
    </span>
  );
}

/** Pointer handlers that show a card large beside the pointer (desktop with a mouse only; contract/web-desktop-2026-10-22.md
 *  § Card preview). Spread onto the row or card. */
export function usePeek(c: Catalog, p: number | null, finish: CardFinish = "nonfoil") {
  const on = useHoverPreview();
  if (!on || p == null || c.pFaces[p] === 0) return {};
  return {
    onMouseEnter: (e: MouseEvent) => showPeek(<CardArt c={c} p={p} width={PEEK_W} finish={finish} />, e.clientX, e.clientY),
    onMouseMove: (e: MouseEvent) => movePeek(e.clientX, e.clientY),
    onMouseLeave: hidePeek,
    onMouseDown: hidePeek,
  };
}

/** The mark a hero card's row carries on its left edge (white, not the accent: teal means "the result"). */
function HeroEdge() {
  return <span aria-label="Hero card" className="absolute left-0 top-0 bottom-0 w-[2px] bg-t1-text" />;
}

/** A list row led by a card thumbnail; same type and spacing as Row. A hero card's row is a shade lighter with a
 *  white left edge. */
export function CardRow({ c, p, title, detail, note, noteAccent, value, warn, onClick, finish, hero, indent }: {
  c: Catalog; p: number | null; title: ReactNode; detail?: ReactNode; value?: ReactNode; warn?: boolean; onClick?: () => void;
  finish?: CardFinish; hero?: boolean;
  /** A second detail line (a want's price trend), in the accent when `noteAccent`. */
  note?: ReactNode; noteAccent?: boolean;
  /** A printing row under its card. */
  indent?: boolean;
}) {
  const peek = usePeek(c, p, finish);
  return (
    <button type="button" onClick={onClick} {...peek}
            className={`relative ${hero ? "bg-t1-surface-hover" : "bg-t1-surface hover:bg-t1-surface-hover"} ${indent ? "pl-10" : "pl-4"} pr-4 py-[5px] h-full flex items-center gap-3 text-left w-full`}>
      {hero && <HeroEdge />}
      <CardArt c={c} p={p} width={36} finish={finish} />
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        <span className="text-[13px] truncate">{title}</span>
        {detail && <span className="t1-label truncate">{detail}</span>}
        {note && <span className={`t1-label truncate ${noteAccent ? "!text-t1-accent" : ""}`}>{note}</span>}
      </span>
      {value != null && <span className={`shrink-0 text-[13px] tabular-nums ${warn ? "text-t1-error" : indent ? "text-t1-muted" : ""}`}>{value}</span>}
    </button>
  );
}

/** A hero card's outline in the grid and in stacks. */
function HeroFrame({ width }: { width: number }) {
  return <span aria-hidden className="absolute inset-0 pointer-events-none border-2 border-t1-text" style={{ borderRadius: width * 0.0432 }} />;
}

/** One grid cell: the image with a count tag in the corner. */
export function CardTile({ c, p, name, qty, width, warn, onClick, finish, hero }: {
  c: Catalog; p: number | null; name: string; qty: number; width: number; warn?: boolean; onClick?: () => void; finish?: CardFinish; hero?: boolean;
}) {
  return (
    <button type="button" onClick={onClick} aria-label={`${name}, ${qty}${hero ? ", hero card" : ""}`} className="relative block" style={{ width }}>
      <CardArt c={c} p={p} width={width} alt={name} finish={finish} />
      {/* Inset past the rounded corner so the tag never gets clipped. */}
      <span className={`absolute px-1.5 py-0.5 text-[13px] tabular-nums ${warn ? "bg-t1-error text-t1-bg" : "bg-t1-bg text-t1-text"}`}
            style={{ right: Math.round(width * 0.05), bottom: Math.round(width * 0.05) }}>
        {qty}
      </span>
      {hero && <HeroFrame width={width} />}
    </button>
  );
}

/** The chevron column at the right of a card with several printings: opens or closes its printings. */
export function PrintingsChevron({ open, hero, onClick }: { open: boolean; hero?: boolean; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} aria-label={open ? "Hide printings" : "Show printings"} aria-expanded={open}
            className={`shrink-0 w-11 flex items-center justify-center text-t1-muted hover:text-t1-text ${hero ? "bg-t1-surface-hover" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>
      <svg width="12" height="8" viewBox="0 0 12 8" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden
           style={{ transform: open ? "rotate(180deg)" : undefined }}>
        <path d="M1 1.5 6 6.5 11 1.5" />
      </svg>
    </button>
  );
}

/** Up to three hero cards fanned at the left of a row that lists a deck, cube, binder or the collection. */
function HeroThumbs({ c, printings }: { c: Catalog; printings: number[] }) {
  const shown = printings.slice(0, 3);
  return (
    <span aria-hidden className="relative shrink-0 block" style={{ width: 36 + Math.max(0, shown.length - 1) * 10, height: Math.round(36 / ASPECT) }}>
      {shown.map((p, i) => (
        <span key={i} className="absolute top-0" style={{ left: i * 10 }}><CardArt c={c} p={p} width={36} /></span>
      ))}
    </span>
  );
}

/** A row for a deck, cube, binder or the collection: its heroes (when it has any) left of the title. */
export function HeroListRow({ c, heroes, title, detail, value, accentValue, onClick }: {
  c: Catalog | null; heroes: number[]; title: string; detail?: string; value?: ReactNode; accentValue?: boolean; onClick: () => void;
}) {
  if (!c || !heroes.length) return <Row title={title} detail={detail} value={value} accentValue={accentValue} onClick={onClick} />;
  return (
    <button type="button" onClick={onClick} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-2 flex items-center gap-3 text-left w-full">
      <HeroThumbs c={c} printings={heroes} />
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        <span className="text-[13px] truncate">{title}</span>
        {detail && <span className="t1-label truncate">{detail}</span>}
      </span>
      {value != null && value !== "" && <span className={`shrink-0 text-[13px] tabular-nums ${accentValue ? "text-t1-accent" : ""}`}>{value}</span>}
    </button>
  );
}

/** Height of a group's heading in the virtualized list and grid. */
const HEADING_H = 36;

/** A group's heading inside a virtualized list or grid ("Creatures · 12"). */
function GroupHeading({ title }: { title: string }) {
  return <div className="h-full bg-t1-surface px-4 flex items-center t1-label truncate">{title}</div>;
}

/** A card grid that fills the width (three columns on a phone, more on wide screens) and renders only the
 *  rows in view. With sections (Group by), each starts on a new row under its heading. */
function VirtualGrid<T>({ sections, cell }: { sections: { key: string; title?: string; items: T[] }[]; cell: (item: T, width: number) => ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [top, setTop] = useState(0);
  const [box, setBox] = useState({ w: 390, h: 800 });
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setBox({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const cols = Math.max(3, Math.floor(box.w / 180));
  const tile = Math.floor((box.w - (cols - 1)) / cols);
  const rowH = Math.round(tile / ASPECT) + 1;
  // Rows top to bottom: a heading, or up to `cols` cards of one section.
  type GridRow = { key: string; y: number; h: number; title?: string; items?: T[] };
  const rows: GridRow[] = [];
  let y = 0;
  for (const s of sections) {
    if (s.title) {
      rows.push({ key: `h|${s.key}`, y, h: HEADING_H + 1, title: s.title });
      y += HEADING_H + 1;
    }
    for (let i = 0; i < s.items.length; i += cols) {
      rows.push({ key: `r|${s.key}|${i}`, y, h: rowH, items: s.items.slice(i, i + cols) });
      y += rowH;
    }
  }
  const out: ReactNode[] = [];
  for (const r of rows) {
    if (r.y + r.h < top - 2 * rowH || r.y > top + box.h + 2 * rowH) continue;
    if (r.title) {
      out.push(<div key={r.key} style={{ position: "absolute", top: r.y, left: 0, right: 0, height: HEADING_H }}><GroupHeading title={r.title} /></div>);
      continue;
    }
    r.items!.forEach((it, k) => out.push(
      <div key={`${r.key}|${k}`} style={{ position: "absolute", top: r.y, left: k * (tile + 1), width: tile }}>{cell(it, tile)}</div>,
    ));
  }
  return (
    <div ref={ref} className="flex-1 min-h-0 overflow-y-auto" onScroll={(e) => setTop(e.currentTarget.scrollTop)}>
      <div style={{ height: y, position: "relative" }}>{out}</div>
    </div>
  );
}

/** One card in a stack. Only its top `STACK_PEEK` shows unless it's the last card. */
export interface StackCardItem {
  key: string;
  p: number | null;
  name: string;
  qty: number;
  warn?: boolean;
  finish?: CardFinish;
  hero?: boolean;
  onClick: () => void;
}
export interface StackItem { key: string; title?: string; cards: StackCardItem[] }

/** The share of a card's height left showing: the whole title bar (name and mana cost) on every modern frame. */
export const STACK_PEEK = 0.118;

/** Cards laid over each other, each showing just its title bar; the last shows in full. Later cards draw on
 *  top, so a click on a strip lands on that card. */
export function CardStack({ c, title, cards, width }: { c: Catalog; title?: string; cards: StackCardItem[]; width: number }) {
  const height = Math.round(width / ASPECT);
  const strip = Math.round(height * STACK_PEEK);
  return (
    <div className="flex flex-col" style={{ width }}>
      {title && <div className="t1-label truncate px-1 py-2">{title}</div>}
      {cards.map((x, i) => (
        <StackCard key={x.key} c={c} x={x} width={width} height={height} strip={strip} first={i === 0} />
      ))}
    </div>
  );
}

/** One card of a stack; on a desktop, resting the pointer on its strip shows the whole card. */
function StackCard({ c, x, width, height, strip, first }: { c: Catalog; x: StackCardItem; width: number; height: number; strip: number; first: boolean }) {
  const peek = usePeek(c, x.p, x.finish);
  return (
    <button type="button" onClick={x.onClick} aria-label={`${x.name}, ${x.qty}${x.hero ? ", hero card" : ""}`} {...peek}
            className="relative block text-left" style={{ width, height, marginTop: first ? 0 : strip - height }}>
      <CardArt c={c} p={x.p} width={width} alt="" finish={x.finish} />
      {x.hero && <HeroFrame width={width} />}
      {(x.p == null || c.pFaces[x.p] === 0) && (
        <span className="absolute left-0 right-0 top-0 px-2 flex items-center text-[12px] truncate border-t border-t1-surface"
              style={{ height: strip }}>{x.name}</span>
      )}
      {/* The count sits on the frame's left edge, clear of the name, and only when it says something. */}
      {(x.qty > 1 || x.warn) && (
        <span className="absolute left-0 top-0 flex items-center" style={{ height: strip }}>
          <span className={`px-1 text-[11px] leading-[14px] tabular-nums ${x.warn ? "bg-t1-error text-t1-bg" : "bg-t1-bg text-t1-text"}`}>
            {x.qty}
          </span>
        </span>
      )}
    </button>
  );
}

/** Stack width for a box: two to a row on a phone, more columns on wide screens. */
export function stackColumns(boxWidth: number) {
  const cols = Math.max(2, Math.floor(boxWidth / 220));
  return { cols, width: Math.floor((boxWidth - (cols - 1)) / cols) };
}

/** Stacks in rows, filling the width. */
export function StackRows({ c, stacks, boxWidth }: { c: Catalog; stacks: StackItem[]; boxWidth: number }) {
  const { cols, width } = stackColumns(boxWidth);
  return (
    <div className="grid items-start gap-x-px gap-y-4 pb-4" style={{ gridTemplateColumns: `repeat(${cols}, ${width}px)` }}>
      {stacks.map((s) => <CardStack key={s.key} c={c} title={s.title} cards={s.cards} width={width} />)}
    </div>
  );
}

/** Tracks an element's inner width (pass the callback as its ref), for layouts that size cards to it. */
export function useBoxWidth(): [(el: HTMLElement | null) => void, number] {
  const [w, setW] = useState(390);
  const ro = useRef<ResizeObserver | null>(null);
  const ref = useCallback((el: HTMLElement | null) => {
    ro.current?.disconnect();
    ro.current = null;
    if (!el) return;
    setW(el.clientWidth);
    ro.current = new ResizeObserver(() => setW(el.clientWidth));
    ro.current.observe(el);
  }, []);
  return [ref, w];
}

/* ── hero cards ───────────────────────────────────────────────────────── */

/** The account's hero cards (contract/library-heroes-2026-10-19.md). The dev demo seeds one per deck and cube (its
 *  first main-deck card by id) and the collection's two most-owned cards, as the iOS demo does. */
export function useLibraryHeroes(): Record<string, string[]> {
  const { userId, demo } = useLibrarySession();
  const state = useHeroes(userId, demo);
  const { catalog } = useCatalog();
  const lists = useLists(userId, demo ? loadDemoLists : undefined);
  const col = useCollection(userId);
  useEffect(() => {
    if (!demo || !userId || !catalog || !lists.ready || !col.ready || !col.items.size) return;
    const oracleOf = (cardId: string) => {
      const p = catalog.printingIndex.get(cardId);
      return p == null ? null : catalog.oId[catalog.pOracle[p]];
    };
    const seed: Record<string, string[]> = {};
    for (const l of lists.lists) {
      const first = entriesOf(l).filter((e) => e.board === "main").map((e) => e.cardId).sort()[0];
      const o = first ? oracleOf(first) : null;
      if (o) seed[`list:${l.id.toLowerCase()}`] = [o];
    }
    const top = [...col.items.values()].sort((a, b) => b.qty - a.qty || (a.cardId < b.cardId ? -1 : 1));
    const picked: string[] = [];
    for (const it of top) {
      if (picked.length >= 2) break;
      const o = oracleOf(it.cardId);
      if (o && !picked.includes(o)) picked.push(o);
    }
    if (picked.length) seed.collection = picked;
    startDemoHeroes(userId, seed);
  }, [demo, userId, catalog, lists.ready, col.ready, col.items.size > 0]);
  return state.heroes;
}

/* ── home ─────────────────────────────────────────────────────────────── */

/* Figma 325:10820's icons (Material, weight 300), drawn in an 18 px box. */
const ICON = {
  plus: "M8.4375 9.5625H4.125V8.4375H8.4375V4.125H9.5625V8.4375H13.875V9.5625H9.5625V13.875H8.4375V9.5625Z",
  search: "M14.6567 15.4328L9.94613 10.722C9.57113 11.0316 9.13987 11.2739 8.65237 11.4489C8.16487 11.6239 7.66056 11.7114 7.13944 11.7114C5.85869 11.7114 4.77406 11.2673 3.88556 10.3789C2.99719 9.49038 2.553 8.40575 2.553 7.125C2.553 5.84425 2.99719 4.75963 3.88556 3.87113C4.77406 2.98275 5.85869 2.53856 7.13944 2.53856C8.42019 2.53856 9.50481 2.98275 10.3933 3.87113C11.2817 4.75963 11.7259 5.84425 11.7259 7.125C11.7259 7.66063 11.636 8.17219 11.4562 8.65969C11.2764 9.14719 11.0364 9.57119 10.7364 9.93169L15.447 14.6422L14.6567 15.4328ZM7.13944 10.5866C8.10581 10.5866 8.92431 10.2513 9.59494 9.5805C10.2657 8.90987 10.6011 8.09138 10.6011 7.125C10.6011 6.15862 10.2657 5.34012 9.59494 4.6695C8.92431 3.99875 8.10581 3.66337 7.13944 3.66337C6.17306 3.66337 5.35456 3.99875 4.68394 4.6695C4.01319 5.34012 3.67781 6.15862 3.67781 7.125C3.67781 8.09138 4.01319 8.90987 4.68394 9.5805C5.35456 10.2513 6.17306 10.5866 7.13944 10.5866Z",
  arrow: "M10.3847 13.2403L9.59419 12.4269L12.4586 9.5625H3.375V8.4375H12.4586L9.59419 5.57306L10.3847 4.75969L14.625 9L10.3847 13.2403Z",
  decks: "M8.22295 9.81524L1.95395 6.56561L9.82163 2.36842L16.0979 5.61824L8.22295 9.81524ZM8.22295 12.7431L2.3852 9.73005L3.56345 9.08373L8.22295 11.4624L14.4883 8.13637L15.6667 8.78268L8.22295 12.7431ZM8.22295 15.6711L2.3852 12.6579L3.56345 12.0117L8.22295 14.3902L14.4883 11.0644L15.6667 11.7105L8.22295 15.6711ZM8.22295 8.53462L13.7527 5.61824L9.82163 3.64923L4.29901 6.56561L8.22295 8.53462Z",
  binders: "M5.14912 16.125C4.6635 16.125 4.24644 15.962 3.89794 15.636C3.54931 15.3101 3.375 14.9068 3.375 14.4259V4.18706C3.375 3.75531 3.51469 3.37237 3.79406 3.03825C4.07331 2.70412 4.42881 2.49188 4.86056 2.4015L11.8558 0.975V12.4558L4.98037 13.8879C4.84862 13.9178 4.73562 13.982 4.64137 14.0805C4.54712 14.1791 4.5 14.2943 4.5 14.4259C4.5 14.5923 4.56469 14.7296 4.69406 14.8378C4.82331 14.9459 4.975 15 5.14912 15H13.5V3.375H14.625V16.125H5.14912ZM6.51919 12.4343L10.7308 11.5586V2.35819L6.51919 3.21919V12.4343ZM5.39419 12.6621V3.44719L5.09138 3.51056C4.92025 3.54519 4.77887 3.62381 4.66725 3.74644C4.55575 3.86906 4.5 4.01594 4.5 4.18706V12.9218C4.57688 12.8823 4.65575 12.8483 4.73662 12.8199C4.81737 12.7916 4.89863 12.7687 4.98037 12.7515L5.39419 12.6621Z",
  cubes: "M8.4375 14.6769V9.32306L3.75 6.60863V11.9625L8.4375 14.6769ZM9.5625 14.6769L14.25 11.9625V6.60863L9.5625 9.32306V14.6769ZM9 8.35387L13.6313 5.67694L9 3L4.36875 5.67694L9 8.35387ZM2.625 12.6274V5.37262L9 1.70775L15.375 5.37262V12.6274L9 16.2923L2.625 12.6274Z",
};

function Icon({ d }: { d: string }) {
  return <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true" className="shrink-0"><path d={d} fill="currentColor" /></svg>;
}

/** A printing's art alone (Scryfall's art crop), filling its box. */
function ArtCrop({ c, p }: { c: Catalog | null; p: number | null }) {
  if (!c || p == null || c.pFaces[p] === 0) return <div className="absolute inset-0 bg-t1-surface" />;
  return <img src={cardImageUrl(c, p, "art_crop")} alt="" loading="lazy" decoding="async" draggable={false}
              className="absolute inset-0 w-full h-full object-cover bg-t1-surface" />;
}

/** A shelf tile's art: the place's heroes (in the printing it holds), topped up with the first cards it holds that
 *  aren't basic lands, up to `count`, one per card. */
export function shelfArt(c: Catalog, heroes: string[], held: string[], basics: Set<string>, count: number): number[] {
  const out = heroPrintings(c, heroes, held).slice(0, count);
  const seen = new Set(out.map((p) => c.pOracle[p]));
  for (const id of held) {
    if (out.length >= count) break;
    if (basics.has(id)) continue;
    const p = c.printingIndex.get(id);
    if (p == null || seen.has(c.pOracle[p])) continue;
    seen.add(c.pOracle[p]);
    out.push(p);
  }
  return out;
}

/** One deck, binder or cube on a shelf: its art under a scrim, name and a detail line at the bottom. */
function ShelfTile({ c, p, title, subtitle, note, onClick }: {
  c: Catalog | null; p: number | null; title: string; subtitle?: string | null; note?: string | null; onClick: () => void;
}) {
  return (
    <button type="button" onClick={onClick} className="relative shrink-0 w-[258px] h-[135px] text-left uppercase tracking-[1.5px] group">
      <ArtCrop c={c} p={p} />
      <span className="absolute inset-0 bg-t1-bg/60 group-hover:bg-t1-bg/40" />
      <span className="absolute inset-x-4 bottom-4 flex items-end gap-2">
        <span className="flex-1 min-w-0 flex flex-col">
          <span className="text-[11px] truncate">{title}</span>
          {subtitle && <span className="text-[9px] text-t1-muted truncate">{subtitle}</span>}
        </span>
        {note && <span className="text-[9px] text-t1-accent">{note}</span>}
      </span>
    </button>
  );
}

function Shelf({ icon, title, onOpen, children }: { icon: string; title: string; onOpen: () => void; children: ReactNode }) {
  return (
    <section className="pt-8 flex flex-col">
      <button type="button" onClick={onOpen} className="h-[50px] pl-4 flex items-center gap-2 text-left hover:text-t1-accent">
        <Icon d={icon} />
        <span className="flex-1 text-[12px] uppercase tracking-[2px] truncate">{title}</span>
        <span className="w-[50px] h-[50px] flex items-center justify-center"><Icon d={ICON.arrow} /></span>
      </button>
      <div className="flex gap-px overflow-x-auto overflow-y-hidden [scrollbar-width:none]">{children}</div>
    </section>
  );
}

/** The Collection tab (Figma 325:10820): the collection as a shelf of its hero art, then a shelf each of decks,
 *  binders and cubes (yours, then the ones you follow), with Trade · Wants · Import along the bottom. + adds cards or
 *  makes a deck, binder or cube; the magnifier searches every card. */
export function LibraryHome({ go, onNew }: {
  /** Opens a path in the app (/library/…, a follow's /u/… or /l/…). */
  go: (href: string) => void;
  /** New deck, cube or binder (the route shows its panel). */
  onNew: (kind: "deck" | "cube" | "binder") => void;
}) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const decks = lists.lists.filter((l) => l.kind === "deck");
  const cubes = lists.lists.filter((l) => l.kind === "cube");
  const binders = useBinders(userId);
  const follows = useFollows();
  const { catalog } = useCatalog();
  const heroes = useLibraryHeroes();
  const prices = usePrices(useMemo(() => [...col.items.values()].map((it) => it.cardId), [col.version]));
  const [menu, setMenu] = useState(false);
  useEffect(() => {
    if (session && !follows.items) void loadFollows();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session]);
  const art = useMemo(() => {
    const m = new Map<string, number[]>();
    if (!catalog) return m;
    const basics = basicCardIds(catalog);
    const items = [...col.items.values()].filter((it) => it.qty > 0);
    const byValue = items.slice().sort((a, b) => (usdPrice(b.cardId, b.finish) ?? 0) - (usdPrice(a.cardId, a.finish) ?? 0)).map((it) => it.cardId);
    m.set("collection", shelfArt(catalog, heroesOf(COLLECTION_SCOPE, heroes), byValue, basics, 2));
    for (const l of lists.lists) {
      const held = entriesOf(l).filter((e) => e.board !== "side" && e.board !== "maybe").sort((a, b) => b.qty - a.qty).map((e) => e.cardId);
      m.set(`list:${l.id}`, shelfArt(catalog, heroesOf({ kind: "list", id: l.id }, heroes), held, basics, 1));
    }
    for (const b of binders.binders) {
      const held = itemsIn(b.id, col.items).sort((x, y) => y.qty - x.qty).map((it) => it.cardId);
      m.set(`binder:${b.id}`, shelfArt(catalog, heroesOf({ kind: "binder", id: b.id }, heroes), held, basics, 1));
    }
    return m;
  }, [catalog, heroes, lists.lists, col.version, binders.version, prices]);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Collection" />;
  const s = col.summary;
  const tap = (target: string) => capture("collection_home_tap", { target });
  const followed = (kind: string) => (follows.items ?? []).filter((f) => f.kind === kind && f.available).map((f) => (
    <ShelfTile key={`f-${f.id}`} c={catalog} p={null} title={followTitle(f)} subtitle={f.owner?.display_name} note={f.unseen ? `${f.unseen} new` : null}
               onClick={() => { const href = followHref(f); if (href) go(href); }} />
  ));
  const action = (title: string, href: string) => (
    <button type="button" onClick={() => { tap(title.toLowerCase()); go(href); }}
            className="flex-1 h-[50px] bg-t1-bg text-[11px] uppercase tracking-[1.5px] hover:text-t1-accent">{title}</button>
  );
  return (
    <LibScreen width="wide">
      <TabNav />
      <div className="shrink-0 bg-t1-bg flex items-center gap-px">
        <h1 className="flex-1 pl-4 text-[12px] uppercase tracking-[2px] truncate">Collection</h1>
        <button type="button" aria-label="Add" onClick={() => { tap("add"); setMenu(true); }}
                className="w-[50px] h-[50px] flex items-center justify-center hover:text-t1-accent"><Icon d={ICON.plus} /></button>
        <button type="button" aria-label="Search cards" onClick={() => { tap("search"); go("/library/search"); }}
                className="w-[50px] h-[50px] flex items-center justify-center hover:text-t1-accent"><Icon d={ICON.search} /></button>
      </div>
      {col.error && <Notice tone="error">{col.error}</Notice>}
      {outboxNotice(col) && <Notice tone="info">{outboxNotice(col)}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto pb-16">
        <button type="button" onClick={() => go("/library/cards")} aria-label={`All cards, ${s?.total_qty ?? 0} cards`}
                className="relative w-full h-[179px] flex group">
          {(art.get("collection") ?? []).length
            ? (art.get("collection") ?? []).map((p) => <span key={p} className="relative flex-1 h-full"><ArtCrop c={catalog} p={p} /></span>)
            : <span className="flex-1 bg-t1-surface" />}
          <span className="absolute inset-0 bg-t1-bg/60 group-hover:bg-t1-bg/40" />
          <span className="absolute inset-x-4 bottom-4 flex text-[9px] uppercase tracking-[1.5px] text-t1-muted">
            <span className="flex-1 text-left">{s ? s.total_qty.toLocaleString() : col.ready ? "0" : "…"}</span>
            {s && <span>{money(s.value_usd, "USD")}</span>}
          </span>
        </button>
        <Shelf icon={ICON.decks} title="Decks" onOpen={() => go("/library/decks")}>
          {decks.map((l) => <ShelfTile key={l.id} c={catalog} p={art.get(`list:${l.id}`)?.[0] ?? null} title={l.name}
                                       subtitle={l.eventName ?? formatName(l.format)} onClick={() => go(`/library/list/${l.id}`)} />)}
          {followed("deck")}
          {!decks.length && <ShelfTile c={catalog} p={null} title="New deck" subtitle="Build or import" onClick={() => onNew("deck")} />}
        </Shelf>
        <Shelf icon={ICON.binders} title="Binders" onOpen={() => go("/library/binders")}>
          {binders.binders.map((b) => <ShelfTile key={b.id} c={catalog} p={art.get(`binder:${b.id}`)?.[0] ?? null} title={b.name}
                                                 onClick={() => go(`/library/binder/${b.id}`)} />)}
          {followed("binder")}
          {!binders.binders.length && <ShelfTile c={catalog} p={null} title="New binder" subtitle="Where your copies are" onClick={() => onNew("binder")} />}
        </Shelf>
        <Shelf icon={ICON.cubes} title="Cubes" onOpen={() => go("/library/cubes")}>
          {cubes.map((l) => <ShelfTile key={l.id} c={catalog} p={art.get(`list:${l.id}`)?.[0] ?? null} title={l.name}
                                       onClick={() => go(`/library/list/${l.id}`)} />)}
          {followed("cube")}
          {!cubes.length && <ShelfTile c={catalog} p={null} title="New cube" subtitle="Build or import" onClick={() => onNew("cube")} />}
        </Shelf>
      </div>
      <div className="shrink-0 flex gap-px">
        {action("Trade", "/library/trades")}
        {action("Wants", "/library/wants")}
        {action("Import", "/library/import")}
      </div>
      {menu && (
        <Menu items={[
          { title: "Add cards", detail: "Search by name or Scryfall syntax", onClick: () => go("/library/add") },
          { title: "New deck", onClick: () => onNew("deck") },
          { title: "New binder", onClick: () => onNew("binder") },
          { title: "New cube", onClick: () => onNew("cube") },
        ]} onClose={() => setMenu(false)} />
      )}
    </LibScreen>
  );
}

/* ── all cards ────────────────────────────────────────────────────────── */

interface Group {
  key: string;
  oracle: number; // -1 when the card is newer than the local catalog
  name: string;
  norm: string;
  type: string;
  qty: number;
  printings: number;
  lastSeq: number;
  /** The printing shown as the card's picture: the one owned most. */
  cover: number | null;
  coverQty: number;
  /** The finish of the copies shown as the picture. */
  coverFinish: Finish;
  /** Copies per printing and finish, oldest printing first: the rows a card opens into. */
  parts: Part[];
}

function groupItems(items: Map<string, Item>, c: Catalog): Group[] {
  const by = new Map<string, Group>();
  const seenPrinting = new Map<string, Set<string>>();
  for (const it of items.values()) {
    const p = c.printingIndex.get(it.cardId);
    const oi = p == null ? -1 : c.pOracle[p];
    const key = oi >= 0 ? c.oId[oi] : it.cardId;
    let g = by.get(key);
    if (!g) {
      g = {
        key, oracle: oi,
        name: oi >= 0 ? c.oName[oi] : "Card not in local data yet",
        norm: oi >= 0 ? c.oNorm[oi] : "",
        type: oi >= 0 ? c.oType[oi] : it.cardId,
        qty: 0, printings: 0, lastSeq: 0, cover: null, coverQty: 0, coverFinish: "nonfoil", parts: [],
      };
      by.set(key, g);
      seenPrinting.set(key, new Set());
    }
    g.qty += it.qty;
    g.lastSeq = Math.max(g.lastSeq, it.seq);
    addPart(g.parts, it.cardId, it.finish, it.qty, p ?? null, it.condition);
    if (p != null && it.qty > g.coverQty) {
      g.cover = p;
      g.coverQty = it.qty;
      g.coverFinish = it.finish;
    }
    const ps = seenPrinting.get(key)!;
    if (!ps.has(it.cardId)) {
      ps.add(it.cardId);
      g.printings++;
    }
  }
  for (const g of by.values()) sortParts(c, g.parts);
  return [...by.values()];
}

const ROW_H = 60;

/** Renders only the rows in view; the list scrolls inside its own box. Rows are 60 high unless `heightOf` says
 *  otherwise (group headings). */
function VirtualList<T>({ rows, render, heightOf }: { rows: T[]; render: (row: T) => ReactNode; heightOf?: (row: T) => number }) {
  const ref = useRef<HTMLDivElement>(null);
  const [top, setTop] = useState(0);
  const [height, setHeight] = useState(800);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setHeight(el.clientHeight));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const ys = useMemo(() => {
    const out = new Array<number>(rows.length + 1);
    out[0] = 0;
    for (let i = 0; i < rows.length; i++) out[i + 1] = out[i] + (heightOf ? heightOf(rows[i]) : ROW_H) + 1;
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows]);
  // First row ending below the top (binary search), then on until past the bottom.
  let lo = 0, hi = rows.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (ys[mid + 1] <= top) lo = mid + 1;
    else hi = mid;
  }
  const first = Math.max(0, lo - 8);
  let last = lo;
  while (last < rows.length && ys[last] < top + height) last++;
  last = Math.min(rows.length, last + 8);
  return (
    <div ref={ref} className="flex-1 min-h-0 overflow-y-auto" onScroll={(e) => setTop(e.currentTarget.scrollTop)}>
      <div style={{ height: ys[rows.length], position: "relative" }}>
        {rows.slice(first, last).map((r, i) => (
          <div key={first + i} style={{ position: "absolute", top: ys[first + i], left: 0, right: 0, height: ys[first + i + 1] - ys[first + i] - 1 }}
               className="overflow-hidden">
            {render(r)}
          </div>
        ))}
      </div>
    </div>
  );
}

export function AllCards({ onBack, onOpen, onAdd }: { onBack: () => void; onOpen: (oracleId: string) => void; onAdd: () => void }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const { catalog, error } = useCatalog();
  const [q, setQ] = useState("");
  const [sort, setSort] = useStoredSort(SORT_KEY.allCards, "allCards");
  const [layout, setLayout] = useStoredLayout("table1.library.allCards.layout", "table1.library.allCards.grid");
  const [grouping, setGrouping] = useStoredGrouping(GROUPING_KEY.allCards, "none", false);
  const [stackBox, stackWidth] = useBoxWidth();
  const [printings, setPrintings] = useState<Disclosure>(COLLAPSED);
  const heroes = useLibraryHeroes();

  const groups = useMemo(() => (catalog ? groupItems(col.items, catalog) : []), [catalog, col.version]);
  /** Each card's groups under Group by, worked out once per card. */
  const keys = useMemo(() => new Map(catalog ? groups.map((g) => [g.key, keysOf(catalog, g.oracle)]) : []), [groups, catalog]);
  const ids = useMemo(() => [...new Set([...col.items.values()].map((it) => it.cardId))], [col.version]);
  const pricesV = usePrices(ids);
  /** The most a single owned copy is worth (market in its condition, USD). */
  const priceOf = (g: Group) => {
    let best: number | null = null;
    for (const pt of g.parts) {
      const p = usdPrice(pt.cardId, pt.finish, pt.condition);
      if (p != null && (best == null || p > best)) best = p;
    }
    return best;
  };
  const shown = useMemo(() => {
    const n = normName(q);
    const list = n ? groups.filter((g) => g.norm.includes(n) || normName(g.type).includes(n)) : groups.slice();
    const byName = (a: Group, b: Group) => (a.norm < b.norm ? -1 : a.norm > b.norm ? 1 : 0);
    if (sort === "price") {
      // No price yet reads as the most valuable: those are the cards worth checking first.
      const p = new Map(list.map((g) => [g.key, priceRank(priceOf(g))]));
      list.sort((a, b) => (p.get(b.key)! === p.get(a.key)! ? 0 : p.get(b.key)! > p.get(a.key)! ? 1 : -1) || byName(a, b));
    } else if (sort === "name" || sort === "manaValue" || sort === "set") {
      // Newest set first, then collector number; spells by mana value, then lands; or by name.
      if (catalog) return applySort(list, sort, (g) => sortKeyOf(catalog, g.name, g.oracle, g.cover));
    } else list.sort((a, b) => b.lastSeq - a.lastSeq || byName(a, b));
    return list;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [groups, q, sort, pricesV, catalog]);
  const detail = (g: Group) => {
    const price = usdText(priceOf(g));
    if (sort === "set" && catalog && g.cover != null) {
      return [`${catalog.pSet[g.cover].toUpperCase()} #${catalog.pCn[g.cover]}`, price].filter(Boolean).join(" · ");
    }
    return [price, `${g.printings} printing${g.printings === 1 ? "" : "s"}`, g.type].filter(Boolean).join(" · ");
  };

  /** Group by: the sorted cards in sections, the sort kept inside each. */
  const sections = useMemo(() => groupSections(shown, grouping, (g) => keys.get(g.key)!), [shown, grouping, keys]);
  const sectionTitle = (sec: { key: string; items: Group[] }) =>
    grouping === "none" ? undefined : `${groupLabel(grouping, sec.key)} · ${sec.items.reduce((n, g) => n + g.qty, 0)}`;

  /** Grid and stacks: one card per Oracle card, or with every printing expanded, one per printing and finish. */
  const tilesOf = (gs: Group[]): StackCardItem[] => gs.flatMap((g) => {
    const hero = isHero(g.key, COLLECTION_SCOPE, heroes);
    const onClick = () => g.oracle >= 0 && onOpen(g.key);
    if (!printings.all || g.parts.length < 2) return [{ key: g.key, p: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, hero, onClick }];
    return g.parts.map((pt) => ({ key: `${g.key}|${pt.cardId}|${pt.finish}`, p: pt.p, name: g.name, qty: pt.qty, finish: pt.finish, hero, onClick }));
  });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const tileSections = useMemo(() => sections.map((sec) => ({ key: `${sec.key}|${sort}|${printings.all}`, title: sectionTitle(sec), items: tilesOf(sec.items) })),
                               [sections, printings.all, heroes]);

  /** Stacks follow Group by (one per group), else the sort: one per set when sorted by set, otherwise runs of ten
   *  in sort order. */
  const stacks = useMemo(() => {
    if (!catalog || layout !== "stacks") return [];
    if (grouping !== "none") return tileSections.map((t): StackItem => ({ key: `${grouping}|${t.key}`, title: t.title, cards: t.items }));
    const setOf = (t: StackCardItem) => (t.p == null ? "" : catalog.pSet[t.p]);
    const out: StackItem[] = runStacks(tileSections[0]?.items ?? [], sort === "set", setOf, `${sort}|${printings.all}|`).map((r) => ({ key: r.key, title: r.title, cards: r.items }));
    return out;
  }, [tileSections, catalog, layout, sort, printings.all, grouping]);

  /** List rows: each group's heading, each card, and under an open card one row per printing and finish. */
  type ListRowItem = { g: Group; part?: Part; heading?: undefined } | { heading: string; g?: undefined; part?: undefined };
  const rows = useMemo((): ListRowItem[] => sections.flatMap((sec) => {
    const title = sectionTitle(sec);
    const cards = sec.items.flatMap((g): ListRowItem[] => {
      const head: ListRowItem = { g };
      return g.parts.length > 1 && isOpen(printings, g.key) ? [head, ...g.parts.map((part) => ({ g, part }))] : [head];
    });
    return title ? [{ heading: title }, ...cards] : cards;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [sections, printings]);

  /** One list row: a group's heading, a card, or one of an open card's printings. */
  const listRow = (r: ListRowItem) => {
    if (r.heading != null) return <GroupHeading title={r.heading} />;
    const { g, part } = r;
    if (!catalog) return null;
    if (part) {
      return (
        <CardRow c={catalog} p={part.p} indent finish={part.finish}
                 title={[part.p == null ? null : `${catalog.pSet[part.p].toUpperCase()} #${catalog.pCn[part.p]}`, part.finish === "nonfoil" ? null : FINISH_LABEL[part.finish]].filter(Boolean).join(" · ")}
                 detail={usdText(usdPrice(part.cardId, part.finish, part.condition)) || undefined}
                 value={part.qty} onClick={() => g.oracle >= 0 && onOpen(g.key)} />
      );
    }
    return (
      <CardGroupRow open={isOpen(printings, g.key)} parts={g.parts.length} hero={isHero(g.key, COLLECTION_SCOPE, heroes)}
                    onToggle={() => { setPrintings(toggleOne(printings, g.key)); capture("printings_toggled", { expanded: !isOpen(printings, g.key), all: false, screen: "all_cards" }); }}>
        <CardRow c={catalog} p={g.cover} title={g.name} detail={detail(g)} finish={g.coverFinish} hero={isHero(g.key, COLLECTION_SCOPE, heroes)}
                 value={g.qty} onClick={() => g.oracle >= 0 && onOpen(g.key)} />
      </CardGroupRow>
    );
  };

  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="All cards" />;
  return (
    <LibScreen width={layout === "list" ? "column" : "wide"}>
      <Bar title="All cards" subtitle={col.summary ? `${col.summary.total_qty.toLocaleString()} cards` : undefined}
           onBack={onBack} right={<span className="flex gap-4">
             <ShareButton target={{ part: "all_cards", id: null, name: null }} from="all_cards" />
             <ViewButton layout={layout} onChange={setLayout} screen="all_cards" printings={printings} onPrintings={setPrintings}
                         grouping={grouping} onGrouping={setGrouping} sort={sort} onSort={setSort} sorts="allCards" />
           </span>} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
      <Field label="Search your cards" value={q} onChange={setQ} placeholder="Name or type" />
      <Segmented options={[{ value: "recent", label: "Recent" }, { value: "price", label: "Price" }, { value: "name", label: "Name" },
                           { value: "manaValue", label: "MV" }, { value: "set", label: "Set" }]}
                 value={sort} onChange={(v) => setSort(v as CardSort)} />
      {!catalog && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      {catalog && col.ready && groups.length === 0 && (
        <Row title="No cards yet" detail="Add your first card" onClick={onAdd} />
      )}
      {catalog && groups.length > 0 && shown.length === 0 && (
        <Row title="No matches" detail="Nothing in your collection by that name or type" />
      )}
      {catalog && shown.length > 0 && (layout === "stacks" ? (
        <div ref={stackBox} className="flex-1 min-h-0 overflow-y-auto">
          <StackRows c={catalog} stacks={stacks} boxWidth={stackWidth} />
        </div>
      ) : layout === "grid" ? (
        <VirtualGrid sections={tileSections} cell={(t, w) => (
          <CardTile c={catalog} p={t.p} name={t.name} qty={t.qty} width={w} finish={t.finish} hero={t.hero} onClick={t.onClick} />
        )} />
      ) : (
        <VirtualList rows={rows} heightOf={(r) => (r.heading ? HEADING_H : ROW_H)} render={listRow} />
      ))}
    </LibScreen>
  );
}

/** A card's collapsed row: the row, and a chevron when it has several printings or finishes. */
export function CardGroupRow({ open, parts, hero, onToggle, children }: {
  open: boolean; parts: number; hero?: boolean; onToggle: () => void; children: ReactNode;
}) {
  if (parts < 2) return <>{children}</>;
  return (
    <div className="flex items-stretch gap-px h-full">
      <div className="flex-1 min-w-0">{children}</div>
      <PrintingsChevron open={open} hero={hero} onClick={onToggle} />
    </div>
  );
}

/* ── add (search) ─────────────────────────────────────────────────────── */

export function AddCards({ onBack, onOpen, search = false }: {
  onBack: () => void; onOpen: (oracleId: string) => void;
  /** Search (the Collection home's magnifier): each card says how many you own. */
  search?: boolean;
}) {
  const { catalog, error } = useCatalog();
  const { userId } = useLibrarySession();
  const col = useCollection(search ? userId : null);
  const [q, setQ] = useState("");
  const found = useCardSearch(catalog, q);
  const hits = q.trim() ? found?.result.hits ?? [] : [];
  /** Copies owned per oracle index (search only). */
  const owned = useMemo(() => {
    const m = new Map<number, number>();
    if (!search || !catalog) return m;
    for (const it of col.items.values()) {
      const p = catalog.printingIndex.get(it.cardId);
      if (p != null) m.set(catalog.pOracle[p], (m.get(catalog.pOracle[p]) ?? 0) + it.qty);
    }
    return m;
  }, [search, catalog, col.version]);
  return (
    <LibScreen>
      <Bar title={search ? "Search" : "Add cards"} onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      <CardSearchBar label="Card" value={q} onChange={setQ} placeholder="Lightning Bolt, or t:dragon c:r" autoFocus
                     onSubmit={() => { if (hits[0] != null && catalog) onOpen(catalog.oId[hits[0]]); }} />
      <CardSearchStatus query={q} found={found} />
      {!catalog && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {catalog && found?.query === q && normName(q).length >= 2 && hits.length === 0 && !hasSyntax(q) && (
          <div className="bg-t1-surface px-4 py-4 t1-label">No card by that name</div>
        )}
        {catalog && hits.map((i) => (
          <div key={i} style={{ height: ROW_H }}>
            <CardRow c={catalog} p={found?.result.covers.get(i) ?? coverPrinting(catalog, i)} title={catalog.oName[i]}
                     detail={`${catalog.oType[i]}${catalog.oCost[i] ? ` · ${catalog.oCost[i]}` : ""}`}
                     value={search ? owned.get(i) || undefined : catalog.pCount[i]} onClick={() => onOpen(catalog.oId[i])} />
          </div>
        ))}
      </div>
    </LibScreen>
  );
}

/* Card detail lives in CardDetail.tsx (contract/card-detail-2026-10-23.md). */
