import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Bar, Field, GhostAction, Menu, Notice, Row, Screen, Section, Segmented, TopNav } from "../components/kit";
import { capture } from "../lib/telemetry";
import { LAYOUTS, parseLayout, runStacks, type CardLayout } from "../lib/cardLayout";
import { SignInButtons } from "../components/SignInButtons";
import { errorMessage } from "../lib/api";
import {
  FINISH_LETTER, RARITY_NAME, cardImageUrl, cornerRatio, coverPrinting, loadCatalog, normName, oracleIndexById, type Catalog,
} from "../lib/catalog";
import {
  applyOps, fetchHistory, undoBatch, useCollection, type Finish, type HistoryEntry, type Item,
} from "../lib/collection";
import { supabase } from "../lib/supabaseClient";
import { useSession } from "../lib/useSession";
import { isLibraryDemo, loadDemoLists } from "../lib/libraryDemo";
import { DEMO_USER, type Condition } from "../lib/collection";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import { useTrades } from "../lib/trades";
import { binderById, binderTotals, forTrade, liveWants, missingLines, placementText, useBinders } from "../lib/binders";
import { MoveCopies, UNSORTED, WantCardRow } from "./Binders";
import { ChangePrintingScreen, type PrintingTarget } from "./ChangePrinting";
import { printingPlaces } from "../lib/changePrinting";
import { BOARD_ORDER, boardTitle, entriesOf, finishOf, useLists, type Entry } from "../lib/lists";
import { TradeMatchesRow } from "./Friends";
import { COLLAPSED, addPart, isOpen, oldestFirst, priceRank, setAll, sortParts, toggleOne, type Disclosure, type Part } from "../lib/printings";
import { COLLECTION_SCOPE, heroPrintings, heroesOf, isHero, scopeOf, startDemoHeroes, toggleHero, useHeroes, HERO_LIMIT } from "../lib/heroes";
import { CardSearchBar, CardSearchStatus, useCardSearch } from "./CardSearch";
import { hasSyntax } from "../lib/cardQuery";
import { langForNew, storeAddLang, storedAddLang } from "../lib/languages";
import { NewCopiesLanguageRow, OwnedLanguageRow } from "./Languages";

export const CONDITIONS: Condition[] = ["NM", "LP", "MP", "HP", "DMG"];
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

function SignedOut({ title }: { title: string }) {
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
 *  card's printings when the screen has them. */
export function ViewButton({ layout, onChange, screen, printings, onPrintings }: {
  layout: CardLayout; onChange: (v: CardLayout) => void; screen: "all_cards" | "deck" | "cube" | "binder";
  printings?: Disclosure; onPrintings?: (d: Disclosure) => void;
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
        }] : [])]} />
      )}
    </>
  );
}

/** A full-height screen whose lists scroll inside it (Screen only sets a minimum height, which lets a list
 *  grow to its full length and defeats virtualization). */
export function LibScreen({ children }: { children: ReactNode }) {
  return <div className="h-[100dvh] w-full bg-t1-bg text-t1-text flex flex-col gap-px overflow-hidden">{children}</div>;
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

export function CardArt({ c, p, width, alt = "", finish = "nonfoil" }: { c: Catalog; p: number | null; width: number; alt?: string; finish?: CardFinish }) {
  const height = Math.round(width / ASPECT);
  const radius = p == null ? width * 0.0432 : width * cornerRatio(c.pSet[p]);
  if (p == null || c.pFaces[p] === 0) {
    return <div className="bg-t1-bg shrink-0" style={{ width, height, borderRadius: radius }} />;
  }
  const px = width * (typeof window === "undefined" ? 1 : window.devicePixelRatio || 1);
  const size = px <= 146 ? "small" : px <= 488 ? "normal" : "large";
  const img = (
    <img src={cardImageUrl(c, p, size)} alt={alt} width={width} height={height} loading="lazy" decoding="async"
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

/** The mark a hero card's row carries on its left edge (white, not the accent: teal means "the result"). */
function HeroEdge() {
  return <span aria-label="Hero card" className="absolute left-0 top-0 bottom-0 w-[2px] bg-t1-text" />;
}

/** A list row led by a card thumbnail; same type and spacing as Row. A hero card's row is a shade lighter with a
 *  white left edge. */
export function CardRow({ c, p, title, detail, value, warn, onClick, finish, hero, indent }: {
  c: Catalog; p: number | null; title: ReactNode; detail?: ReactNode; value?: ReactNode; warn?: boolean; onClick?: () => void;
  finish?: CardFinish; hero?: boolean;
  /** A printing row under its card. */
  indent?: boolean;
}) {
  return (
    <button type="button" onClick={onClick}
            className={`relative ${hero ? "bg-t1-surface-hover" : "bg-t1-surface hover:bg-t1-surface-hover"} ${indent ? "pl-10" : "pl-4"} pr-4 py-[5px] h-full flex items-center gap-3 text-left w-full`}>
      {hero && <HeroEdge />}
      <CardArt c={c} p={p} width={36} finish={finish} />
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        <span className="text-[13px] truncate">{title}</span>
        {detail && <span className="t1-label truncate">{detail}</span>}
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

/** A card grid that fills the width (three columns on a phone, more on wide screens) and renders only the
 *  rows in view. */
function VirtualGrid<T>({ items, cell }: { items: T[]; cell: (item: T, width: number) => ReactNode }) {
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
  const rows = Math.ceil(items.length / cols);
  const first = Math.max(0, Math.floor(top / rowH) - 2);
  const last = Math.min(rows, Math.ceil((top + box.h) / rowH) + 2);
  const out: ReactNode[] = [];
  for (let r = first; r < last; r++) {
    for (let k = 0; k < cols; k++) {
      const i = r * cols + k;
      if (i >= items.length) break;
      out.push(
        <div key={i} style={{ position: "absolute", top: r * rowH, left: k * (tile + 1), width: tile }}>{cell(items[i], tile)}</div>,
      );
    }
  }
  return (
    <div ref={ref} className="flex-1 min-h-0 overflow-y-auto" onScroll={(e) => setTop(e.currentTarget.scrollTop)}>
      <div style={{ height: rows * rowH, position: "relative" }}>{out}</div>
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
        <button key={x.key} type="button" onClick={x.onClick} aria-label={`${x.name}, ${x.qty}${x.hero ? ", hero card" : ""}`}
                className="relative block text-left" style={{ width, height, marginTop: i === 0 ? 0 : strip - height }}>
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
      ))}
    </div>
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

export function LibraryHome({ onAllCards, onAdd, onDecks, onCubes, onTrades, onImport, onBinders, onWants, onMatches }: {
  onAllCards: () => void; onAdd: () => void; onDecks: () => void; onCubes: () => void; onTrades: () => void; onImport: () => void;
  onBinders: () => void; onWants: () => void; onMatches: () => void;
}) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const decks = lists.lists.filter((l) => l.kind === "deck");
  const cubes = lists.lists.filter((l) => l.kind === "cube");
  const trades = useTrades();
  const openTrades = trades.trades.filter((t) => t.status === "draft").length;
  const binders = useBinders(userId);
  const totals = useMemo(() => binderTotals(col.items), [col.version, binders.version]);
  const forTradeCopies = binders.binders.filter((b) => b.for_trade).reduce((n, b) => n + (totals.byBinder.get(b.id) ?? 0), 0);
  const wanted = useMemo(() => liveWants().reduce((n, w) => n + w.qty, 0), [binders.version]);
  const missing = useMemo(() => {
    const owned = new Map<string, number>();
    for (const it of col.items.values()) owned.set(`${it.cardId}|${it.finish}`, (owned.get(`${it.cardId}|${it.finish}`) ?? 0) + it.qty);
    return missingLines(lists.lists, owned).reduce((n, m) => n + m.short, 0);
  }, [lists.lists, col.version]);
  const heroes = useLibraryHeroes();
  const { catalog } = useCatalog();
  const heroArt = useMemo(() => {
    if (!catalog) return [];
    const held = [...col.items.values()].sort((a, b) => b.qty - a.qty).map((it) => it.cardId);
    return heroPrintings(catalog, heroesOf(COLLECTION_SCOPE, heroes), held);
  }, [catalog, heroes, col.version]);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Collection" />;
  const s = col.summary;
  return (
    <Screen>
      <TopNav />
      <Bar title="Collection" subtitle={userId === DEMO_USER ? "Demo data" : col.syncing ? "Syncing…" : undefined} />
      {col.error && <Notice tone="error">{col.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-1">
          <p className="t1-label">Cards</p>
          <p className="text-[48px] tabular-nums tracking-[4px]">{s ? s.total_qty.toLocaleString() : col.ready ? "0" : "…"}</p>
          <p className="t1-label">
            {s ? `${s.unique_cards.toLocaleString()} distinct · ${money(s.value_usd, "USD")} · ${money(s.value_eur, "EUR")}` : " "}
          </p>
        </div>
        <HeroListRow c={catalog} heroes={heroArt} title="All cards" detail={s ? `${s.unique_printings.toLocaleString()} printings` : undefined}
                     value={s ? s.unique_cards.toLocaleString() : undefined} onClick={onAllCards} />
        <Row title="Add cards" detail="Search by name or Scryfall syntax" onClick={onAdd} />
        <Row title="Import and export" detail="CSV from ManaBox, Moxfield and others" onClick={onImport} />
        <Row title="Binders" value={binders.binders.length} onClick={onBinders}
             detail={binders.binders.length ? `${forTradeCopies.toLocaleString()} cards for trade · ${totals.unsorted.toLocaleString()} unsorted`
                                            : "Where your copies are, and what's for trade"} />
        <Row title="Wants" value={wanted} onClick={onWants}
             detail={`${wanted.toLocaleString()} wanted · ${missing.toLocaleString()} missing`} />
        <Row title="Decks" detail={decks.length ? decks.slice(0, 3).map((l) => l.name).join(" · ") : "Build and track decks"}
             value={decks.length} onClick={onDecks} />
        <Row title="Cubes" detail={cubes.length ? cubes.map((l) => l.name).join(" · ") : "Build and track cubes"}
             value={cubes.length} onClick={onCubes} />
        <TradeMatchesRow onClick={onMatches} />
        <Row title="Trades" detail={openTrades ? `${openTrades} open` : "Give and get, then confirm"}
             value={trades.loaded ? trades.trades.length : undefined} onClick={onTrades} />
      </div>
    </Screen>
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
  /** Owned printing id|finish pairs, for prices. */
  owned: [string, Finish][];
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
        qty: 0, printings: 0, lastSeq: 0, cover: null, coverQty: 0, owned: [], coverFinish: "nonfoil", parts: [],
      };
      by.set(key, g);
      seenPrinting.set(key, new Set());
    }
    g.qty += it.qty;
    g.lastSeq = Math.max(g.lastSeq, it.seq);
    g.owned.push([it.cardId, it.finish]);
    addPart(g.parts, it.cardId, it.finish, it.qty, p ?? null);
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

/** Renders only the rows in view; the list scrolls inside its own box. */
function VirtualList<T>({ rows, render }: { rows: T[]; render: (row: T) => ReactNode }) {
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
  const first = Math.max(0, Math.floor(top / ROW_H) - 8);
  const last = Math.min(rows.length, Math.ceil((top + height) / ROW_H) + 8);
  return (
    <div ref={ref} className="flex-1 min-h-0 overflow-y-auto" onScroll={(e) => setTop(e.currentTarget.scrollTop)}>
      <div style={{ height: rows.length * (ROW_H + 1), position: "relative" }}>
        {rows.slice(first, last).map((r, i) => (
          <div key={first + i} style={{ position: "absolute", top: (first + i) * (ROW_H + 1), left: 0, right: 0, height: ROW_H }}
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
  const [sort, setSortState] = useState<"recent" | "price" | "set">(() => {
    try {
      const v = localStorage.getItem("table1.library.allCards.sort");
      return v === "price" || v === "set" ? v : "recent";
    } catch {
      return "recent";
    }
  });
  const setSort = (v: "recent" | "price" | "set") => {
    setSortState(v);
    try {
      localStorage.setItem("table1.library.allCards.sort", v);
    } catch {
      /* storage blocked */
    }
  };
  const [layout, setLayout] = useStoredLayout("table1.library.allCards.layout", "table1.library.allCards.grid");
  const [stackBox, stackWidth] = useBoxWidth();
  const [printings, setPrintings] = useState<Disclosure>(COLLAPSED);
  const heroes = useLibraryHeroes();

  const groups = useMemo(() => (catalog ? groupItems(col.items, catalog) : []), [catalog, col.version]);
  const ids = useMemo(() => [...new Set([...col.items.values()].map((it) => it.cardId))], [col.version]);
  const pricesV = usePrices(ids);
  /** The most a single owned copy is worth (market, USD). */
  const priceOf = (g: Group) => {
    let best: number | null = null;
    for (const [id, f] of g.owned) {
      const p = usdPrice(id, f);
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
    } else if (sort === "set" && catalog) {
      // Newest set first; within a set, collector number order.
      const rel = (g: Group) => (g.cover == null ? "" : catalog.pReleased[g.cover] ?? "");
      const set = (g: Group) => (g.cover == null ? "" : catalog.pSet[g.cover]);
      const cn = (g: Group) => (g.cover == null ? Infinity : parseInt(catalog.pCn[g.cover], 10) || Infinity);
      list.sort((a, b) => (rel(a) !== rel(b) ? (rel(a) < rel(b) ? 1 : -1) : set(a) !== set(b) ? (set(a) < set(b) ? -1 : 1) : cn(a) - cn(b) || byName(a, b)));
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

  /** Grid and stacks: one card per Oracle card, or with every printing expanded, one per printing and finish. */
  const tiles = useMemo((): StackCardItem[] => shown.flatMap((g) => {
    const hero = isHero(g.key, COLLECTION_SCOPE, heroes);
    const onClick = () => g.oracle >= 0 && onOpen(g.key);
    if (!printings.all || g.parts.length < 2) return [{ key: g.key, p: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, hero, onClick }];
    return g.parts.map((pt) => ({ key: `${g.key}|${pt.cardId}|${pt.finish}`, p: pt.p, name: g.name, qty: pt.qty, finish: pt.finish, hero, onClick }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }), [shown, printings.all, heroes]);

  /** Stacks follow the sort: one per set when sorted by set, otherwise runs of ten in sort order. */
  const stacks = useMemo(() => {
    if (!catalog || layout !== "stacks") return [];
    const setOf = (t: StackCardItem) => (t.p == null ? "" : catalog.pSet[t.p]);
    const out: StackItem[] = runStacks(tiles, sort === "set", setOf, `${sort}|${printings.all}|`).map((r) => ({ key: r.key, title: r.title, cards: r.items }));
    return out;
  }, [tiles, catalog, layout, sort, printings.all]);

  /** List rows: each card, and under an open card one row per printing and finish. */
  type ListRowItem = { g: Group; part?: Part };
  const rows = useMemo((): ListRowItem[] => shown.flatMap((g) => {
    const head: ListRowItem = { g };
    return g.parts.length > 1 && isOpen(printings, g.key) ? [head, ...g.parts.map((part) => ({ g, part }))] : [head];
  }), [shown, printings]);

  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="All cards" />;
  return (
    <LibScreen>
      <Bar title="All cards" subtitle={col.summary ? `${col.summary.total_qty.toLocaleString()} cards` : undefined}
           onBack={onBack} right={<ViewButton layout={layout} onChange={setLayout} screen="all_cards" printings={printings} onPrintings={setPrintings} />} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
      <Field label="Search your cards" value={q} onChange={setQ} placeholder="Name or type" />
      <Segmented options={[{ value: "recent", label: "Recent" }, { value: "price", label: "Price" }, { value: "set", label: "Set" }]}
                 value={sort} onChange={setSort} />
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
        <VirtualGrid items={tiles} cell={(t, w) => (
          <CardTile c={catalog} p={t.p} name={t.name} qty={t.qty} width={w} finish={t.finish} hero={t.hero} onClick={t.onClick} />
        )} />
      ) : (
        <VirtualList rows={rows} render={({ g, part }) => part ? (
          <CardRow c={catalog} p={part.p} indent finish={part.finish}
                   title={[part.p == null ? null : `${catalog.pSet[part.p].toUpperCase()} #${catalog.pCn[part.p]}`, part.finish === "nonfoil" ? null : FINISH_LABEL[part.finish]].filter(Boolean).join(" · ")}
                   detail={usdText(usdPrice(part.cardId, part.finish)) || undefined}
                   value={part.qty} onClick={() => g.oracle >= 0 && onOpen(g.key)} />
        ) : (
          <CardGroupRow open={isOpen(printings, g.key)} parts={g.parts.length} hero={isHero(g.key, COLLECTION_SCOPE, heroes)}
                        onToggle={() => { setPrintings(toggleOne(printings, g.key)); capture("printings_toggled", { expanded: !isOpen(printings, g.key), all: false, screen: "all_cards" }); }}>
            <CardRow c={catalog} p={g.cover} title={g.name} detail={detail(g)} finish={g.coverFinish} hero={isHero(g.key, COLLECTION_SCOPE, heroes)}
                     value={g.qty} onClick={() => g.oracle >= 0 && onOpen(g.key)} />
          </CardGroupRow>
        )} />
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

export function AddCards({ onBack, onOpen }: { onBack: () => void; onOpen: (oracleId: string) => void }) {
  const { catalog, error } = useCatalog();
  const [q, setQ] = useState("");
  const found = useCardSearch(catalog, q);
  const hits = q.trim() ? found?.result.hits ?? [] : [];
  return (
    <LibScreen>
      <Bar title="Add cards" onBack={onBack} />
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
                     value={catalog.pCount[i]} onClick={() => onOpen(catalog.oId[i])} />
          </div>
        ))}
      </div>
    </LibScreen>
  );
}

/* ── card detail ──────────────────────────────────────────────────────── */

interface PrintingPrice { id: string; set_name: string | null; usd: number | null; usd_foil: number | null; eur: number | null; eur_foil: number | null }

function priceFor(pr: PrintingPrice | undefined, f: Finish) {
  if (!pr) return null;
  const usd = f === "nonfoil" ? pr.usd : pr.usd_foil;
  const eur = f === "nonfoil" ? pr.eur : pr.eur_foil;
  if (usd == null && eur == null) return null;
  return [usd != null ? `$${usd}` : null, eur != null ? `€${eur}` : null].filter(Boolean).join(" · ");
}

/** Where card detail was opened from: that deck/cube's lines or that binder's copies (or Unsorted's) come first, each
 *  with Change printing (contract/change-printing-2026-10-18.md). */
export interface CardContext { list?: string; binder?: string }

export function CardDetail({ oracleId, onBack, context }: { oracleId: string; onBack: () => void; context?: CardContext }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  /** The Change printing screen, over this one. */
  const [changing, setChanging] = useState<{ target: PrintingTarget; screen: string } | null>(null);
  const { catalog, error: catError } = useCatalog();
  const [prices, setPrices] = useState<Map<string, PrintingPrice>>(new Map());
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [last, setLast] = useState<{ batch: string; label: string } | null>(null);
  const [showAll, setShowAll] = useState(false);
  const [open, setOpen] = useState<string | null>(null);
  const [history, setHistory] = useState<HistoryEntry[] | null>(null);
  /** A printing tapped in the list, shown large in place of the owned one. */
  const [preview, setPreview] = useState<number | null>(null);
  /** Condition new copies go in as (remembered). */
  const [addCondition, setAddConditionState] = useState<Condition>(() => {
    try {
      const v = localStorage.getItem("table1.library.addCondition") as Condition | null;
      return v && CONDITIONS.includes(v) ? v : "NM";
    } catch {
      return "NM";
    }
  });
  const setAddCondition = (c: Condition) => {
    setAddConditionState(c);
    try {
      localStorage.setItem("table1.library.addCondition", c);
    } catch {
      /* storage blocked */
    }
  };
  /** Language new English-printing copies go in as (shared with binder adds and trades). */
  const [addLang, setAddLangState] = useState(storedAddLang);
  const setAddLang = (code: string) => { setAddLangState(code); storeAddLang(code); };
  /** Moving copies of one owned item to another condition, when there's more than one copy. */
  const [moving, setMoving] = useState<{ k: string; to: Condition } | null>(null);
  /** Moving copies of one owned item between binders. */
  const [sorting, setSorting] = useState<Item | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const binders = useBinders(userId);
  const heroes = useLibraryHeroes();

  const oi = catalog ? oracleIndexById(catalog, oracleId) : -1;
  useEffect(() => {
    supabase.rpc("card_printings", { p_oracle_id: oracleId }).then(({ data }) => {
      if (data) setPrices(new Map((data as PrintingPrice[]).map((p) => [p.id, p])));
    });
  }, [oracleId]);

  const owned = useMemo(() => {
    if (!catalog || oi < 0) return [];
    const ids = new Set<string>();
    for (let p = catalog.pFirst[oi]; p < catalog.pFirst[oi] + catalog.pCount[oi]; p++) ids.add(catalog.pId[p]);
    return [...col.items.values()].filter((it) => ids.has(it.cardId))
      .sort((a, b) => (a.cardId !== b.cardId ? oldestFirst(catalog, catalog.printingIndex.get(a.cardId)!, catalog.printingIndex.get(b.cardId)!) : 0) || a.k.localeCompare(b.k));
  }, [catalog, oi, col.version]);

  useEffect(() => {
    if (!open) return setHistory(null);
    setHistory(null);
    fetchHistory(open).then(setHistory, (e) => setError(errorMessage(e)));
  }, [open, col.version]);

  const change = async (key: string, label: string, op: Parameters<typeof applyOps>[0][number] | Parameters<typeof applyOps>[0]) => {
    setBusy(key);
    setError(null);
    setMoving(null);
    try {
      const res = await applyOps(Array.isArray(op) ? op : [op]);
      setLast({ batch: res.batch_id, label });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(null);
    }
  };
  const undo = async () => {
    if (!last) return;
    setBusy("undo");
    try {
      await undoBatch(last.batch);
      setLast(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(null);
    }
  };

  const moveCondition = (it: Item, p: number, to: Condition, n: number) => {
    const label = catalog ? `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}` : "card";
    void change(it.k, `Moved ${n} ${label} to ${to}`, [
      { card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: -n },
      { card_id: it.cardId, finish: it.finish, condition: to, lang: it.lang, delta: n },
    ]);
  };

  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Card" />;
  if (!catalog) {
    return (
      <Screen>
        <Bar title="Card" onBack={onBack} />
        {catError ? <Notice tone="error">{catError}</Notice> : <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      </Screen>
    );
  }
  if (oi < 0) {
    return (
      <Screen>
        <Bar title="Card" onBack={onBack} />
        <Notice tone="error">That card isn't in the card data.</Notice>
      </Screen>
    );
  }

  if (changing) {
    return <ChangePrintingScreen target={changing.target} screenName={changing.screen} onClose={() => setChanging(null)}
                                 onChanged={(batch, label) => { setLast({ batch, label }); setNote(null); setError(null); }} />;
  }

  const first = catalog.pFirst[oi];
  const count = catalog.pCount[oi];
  // Opened from a deck/cube: this card's lines there; from a binder (or Unsorted): this card's copies there.
  const ctxList = context?.list ? lists.lists.find((l) => l.id === context.list) : undefined;
  const ctxLines: { e: Entry; p: number }[] = ctxList
    ? entriesOf(ctxList).flatMap((e) => {
      const p = catalog.printingIndex.get(e.cardId);
      return p != null && catalog.pOracle[p] === oi ? [{ e, p }] : [];
    }).sort((a, b) => BOARD_ORDER.indexOf(a.e.board) - BOARD_ORDER.indexOf(b.e.board))
    : [];
  void binders.version;
  const ctxCopies = context?.binder
    ? owned.flatMap((it) => {
      const here = printingPlaces(it).find((pl) => pl.place === context.binder)?.qty ?? 0;
      return here > 0 ? [{ it, p: catalog.printingIndex.get(it.cardId)!, qty: here }] : [];
    })
    : [];
  const ctxPrinting = ctxLines[0]?.p ?? ctxCopies[0]?.p;
  const changeOwned = (it: Item, place: string | null) => setChanging({ target: { kind: "owned", item: it, place }, screen: "item_printing" });
  const heroP = preview ?? ctxPrinting ?? (owned.length ? catalog.printingIndex.get(owned[0].cardId)! : coverPrinting(catalog, oi));
  const total = owned.reduce((n, it) => n + it.qty, 0);
  const setLabel = (p: number) => `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  // Earliest first, most recent last (contract/library-polish-2026-10-19.md).
  const printings = Array.from({ length: count }, (_, i) => first + i).sort((a, b) => oldestFirst(catalog, a, b));

  return (
    <LibScreen>
      <Bar title={catalog.oName[oi]} subtitle={`${total} in collection`} onBack={onBack} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
      {note && !last && <Notice tone="info">{note}</Notice>}
      {sorting && (
        <MoveCopies item={sorting} label={setLabel(catalog.printingIndex.get(sorting.cardId)!)} onClose={() => setSorting(null)}
                    onMoved={(t) => { setSorting(null); setNote(t); setLast(null); }} />
      )}
      {last && (
        <div className="bg-t1-surface px-4 py-3 flex items-center justify-between gap-3">
          <span className="t1-label truncate">{last.label}</span>
          <button type="button" onClick={undo} disabled={busy === "undo"} className="t1-label hover:text-t1-text disabled:opacity-40">
            Undo
          </button>
        </div>
      )}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-4 flex gap-4 items-start">
          <CardArt key={heroP} c={catalog} p={heroP} width={146} alt={catalog.oName[oi]} />
          <div className="min-w-0 flex flex-col gap-1">
            <p className="text-[13px]">{catalog.oType[oi]}</p>
            {catalog.oCost[oi] && <p className="t1-label">{catalog.oCost[oi]}</p>}
            <p className="t1-label">{count} printings</p>
          </div>
        </div>

        {context?.list && (
          <>
            <Section title={`In ${ctxList?.name ?? "this list"}`} count={ctxLines.reduce((n, l) => n + l.e.qty, 0)} />
            {!ctxLines.length && <div className="bg-t1-surface px-4 py-4 t1-label">Not in this {ctxList?.kind === "cube" ? "cube" : "deck"} any more.</div>}
            {ctxList && ctxLines.map(({ e, p }) => (
              <div key={`${e.board}|${e.cardId}|${finishOf(e)}`} className="h-[60px] shrink-0">
                <CardRow c={catalog} p={p} title={`${setLabel(p)} · ${FINISH_LABEL[finishOf(e)]}`} detail={boardTitle(ctxList.kind, e.board)} finish={finishOf(e)}
                         value={<ChangeValue qty={e.qty} />}
                         onClick={() => setChanging({ target: { kind: "list", listId: ctxList.id, cardId: e.cardId, board: e.board, finish: finishOf(e) }, screen: "list_printing" })} />
              </div>
            ))}
          </>
        )}
        {context?.binder && (
          <>
            <Section title={`In ${context.binder === UNSORTED ? "Unsorted" : binderById(context.binder)?.name ?? "Binder"}`}
                     count={ctxCopies.reduce((n, c) => n + c.qty, 0)} />
            {!ctxCopies.length && <div className="bg-t1-surface px-4 py-4 t1-label">None here any more.</div>}
            {ctxCopies.map(({ it, p, qty }) => (
              <div key={`in|${it.k}`} className="h-[60px] shrink-0">
                <CardRow c={catalog} p={p} title={`${setLabel(p)} · ${FINISH_LABEL[it.finish]}`} finish={it.finish}
                         detail={[it.condition, it.lang === "en" ? null : it.lang.toUpperCase()].filter(Boolean).join(" · ")}
                         value={<ChangeValue qty={qty} />} onClick={() => changeOwned(it, context.binder!)} />
              </div>
            ))}
          </>
        )}
        <Section title="In collection" count={owned.length} />
        {owned.length === 0 && <div className="bg-t1-surface px-4 py-4 t1-label">None yet. Pick a printing below.</div>}
        {owned.map((it) => {
          const p = catalog.printingIndex.get(it.cardId)!;
          const price = priceFor(prices.get(it.cardId), it.finish);
          return (
            <div key={it.k} className="flex flex-col gap-px">
              <div className="bg-t1-surface flex items-stretch">
                <button type="button" onClick={() => { setOpen(open === it.cardId ? null : it.cardId); setPreview(p); }}
                        className="flex-1 min-w-0 px-4 py-[5px] flex items-center gap-3 text-left hover:bg-t1-surface-hover">
                  <CardArt c={catalog} p={p} width={36} finish={it.finish} />
                  <span className="min-w-0 flex flex-col gap-0.5">
                    <span className="text-[13px] truncate">{setLabel(p)} · {FINISH_LABEL[it.finish]}</span>
                    <span className="t1-label truncate">
                      {[prices.get(it.cardId)?.set_name, it.condition, it.lang.toUpperCase(), price].filter(Boolean).join(" · ")}
                    </span>
                    {binders.version >= 0 && placementText(it) && (
                      <span className={`t1-label truncate ${forTrade(it.k).qty > 0 ? "!text-t1-accent" : ""}`}>{placementText(it)}</span>
                    )}
                  </span>
                </button>
                <span className="px-3 flex items-center text-[17px] tabular-nums">{it.qty}</span>
                <button type="button" aria-label="Remove one" disabled={busy === it.k}
                        onClick={() => change(it.k, `Removed 1 ${setLabel(p)}`, { card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: -1 })}
                        className="w-14 bg-t1-bg hover:bg-t1-surface-hover text-[20px] disabled:opacity-30">−</button>
                <button type="button" aria-label="Add one" disabled={busy === it.k}
                        onClick={() => change(it.k, `Added 1 ${setLabel(p)}`, { card_id: it.cardId, finish: it.finish, condition: it.condition, lang: it.lang, delta: 1 })}
                        className="w-14 ml-px bg-t1-bg hover:bg-t1-surface-hover text-[20px] disabled:opacity-30">+</button>
              </div>
              {open === it.cardId && (
                <div className="flex flex-col gap-px">
                  <Segmented options={CONDITIONS.map((c) => ({ value: c, label: c }))} value={it.condition}
                             onChange={(c) => {
                               if (c === it.condition) return;
                               if (it.qty === 1) moveCondition(it, p, c, 1);
                               else setMoving({ k: it.k, to: c });
                             }} />
                  <OwnedLanguageRow item={it} label={setLabel(p)} onError={setError}
                                    onDone={(batch, text) => { setLast({ batch, label: text }); setNote(null); setError(null); }} />
                  <Row title="Change printing" detail="Or finish · keeps condition and binder" value={setLabel(p)} onClick={() => changeOwned(it, null)} />
                  <Row title="Move" detail={placementText(it) ?? `Unsorted ${it.qty}`} onClick={() => setSorting(it)} />
                  {moving?.k === it.k && (
                    <div className="flex gap-px">
                      <GhostAction label={`Move 1 copy to ${moving.to}`} onClick={() => moveCondition(it, p, moving.to, 1)} />
                      <GhostAction label={`Move all ${it.qty}`} onClick={() => moveCondition(it, p, moving.to, it.qty)} />
                    </div>
                  )}
                </div>
              )}
              {open === it.cardId && (
                <div className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
                  <span className="t1-label">History · {setLabel(p)}</span>
                  {history === null && <span className="t1-label">Loading…</span>}
                  {history?.map((h, i) => (
                    <span key={i} className={`text-[12px] tabular-nums ${h.undone ? "opacity-50 line-through" : ""}`}>
                      {new Date(h.at).toLocaleDateString()} · {h.delta > 0 ? `+${h.delta}` : h.delta} {FINISH_LABEL[h.finish]} · {h.source} → {h.qty_after}
                    </span>
                  ))}
                </div>
              )}
            </div>
          );
        })}

        <WantCardRow catalog={catalog} oi={oi} shown={preview ?? (owned.length ? catalog.printingIndex.get(owned[0].cardId)! : null)}
                     onAdded={(t) => { setNote(t); setLast(null); }} />
        <HeroToggleRow oracleId={catalog.oId[oi]} context={context} heroes={heroes} lists={lists.lists} onFull={setError} />
        <Section title="Add a printing" count={count} right={<span title={CONDITION_NAME[addCondition]}>Adds as {addCondition}</span>} />
        <Segmented options={CONDITIONS.map((c) => ({ value: c, label: c }))} value={addCondition} onChange={setAddCondition} />
        <NewCopiesLanguageRow lang={addLang} onChange={setAddLang} />
        {(showAll ? printings : printings.slice(0, 12)).map((p) => {
          const finishes = (["n", "f", "e"] as const).filter((l) => catalog.pFinishes[p].includes(l)).map((l) => FINISH_LETTER[l]) as Finish[];
          const pr = prices.get(catalog.pId[p]);
          return (
            <div key={p} className="bg-t1-surface flex items-stretch gap-px">
              {/* Tapping the art or name shows this printing large at the top. */}
              <button type="button" onClick={() => setPreview(p)}
                      className="flex-1 min-w-0 px-4 py-[5px] flex items-center gap-3 text-left hover:bg-t1-surface-hover">
                <CardArt c={catalog} p={p} width={36} />
                <span className="min-w-0 flex flex-col gap-0.5">
                  <span className="text-[13px] truncate">{setLabel(p)}{catalog.pLang[p] !== "en" ? ` · ${catalog.pLang[p].toUpperCase()}` : ""}</span>
                  <span className="t1-label truncate">
                    {[pr?.set_name, RARITY_NAME[catalog.pRarity[p]], catalog.pReleased[p]?.slice(0, 4)].filter(Boolean).join(" · ")}
                  </span>
                </span>
              </button>
              {finishes.map((f) => {
                const k = `${catalog.pId[p]}|${f}`;
                const lang = langForNew(catalog.pLang[p], addLang);
                return (
                  <button key={f} type="button" disabled={busy === k} title={priceFor(pr, f) ?? undefined}
                          onClick={() => change(k, `Added 1 ${setLabel(p)} ${FINISH_LABEL[f]} · ${addCondition}${lang === "en" ? "" : ` · ${lang.toUpperCase()}`}`,
                                                { card_id: catalog.pId[p], finish: f, condition: addCondition, lang, delta: 1 })}
                          className="px-3 bg-t1-bg hover:bg-t1-surface-hover text-[11px] uppercase tracking-[1px] disabled:opacity-30">
                    + {f === "nonfoil" ? "Card" : FINISH_LABEL[f]}
                  </button>
                );
              })}
            </div>
          );
        })}
        {!showAll && count > 12 && <Row title={`Show all ${count} printings`} onClick={() => setShowAll(true)} />}
      </div>
    </LibScreen>
  );
}

/** Makes the card a hero of where it was opened from: the deck or cube, the binder, or (from anywhere else) the
 *  collection. Unsorted has no heroes. */
function HeroToggleRow({ oracleId, context, heroes, lists, onFull }: {
  oracleId: string; context?: CardContext; heroes: Record<string, string[]>; lists: { id: string; name: string }[]; onFull: (e: string) => void;
}) {
  const scope = scopeOf(context, UNSORTED);
  if (!scope) return null;
  const on = isHero(oracleId, scope, heroes);
  const place = scope.kind === "collection" ? "your collection"
    : scope.kind === "list" ? lists.find((l) => l.id === scope.id)?.name ?? "this list"
    : binderById(scope.id)?.name ?? "this binder";
  return (
    <Row title={on ? `Hero of ${place}` : "Make it a hero"}
         detail={on ? "Tap to stop highlighting it" : `Highlighted in ${place} and where it's listed`}
         value={on ? <span className="t1-label !text-t1-text">Hero</span> : undefined}
         onClick={() => {
           if (!toggleHero(oracleId, scope)) onFull(`${place.charAt(0).toUpperCase()}${place.slice(1)} has ${HERO_LIMIT} hero cards already.`);
         }} />
  );
}

/** A context row's count, with "Change" so the row says what a tap does. */
function ChangeValue({ qty }: { qty: number }) {
  return <span className="flex items-center gap-3"><span className="t1-label !text-t1-text">Change</span><span>{qty}</span></span>;
}
