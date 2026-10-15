import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Bar, Field, GhostAction, Notice, Row, Screen, Section, Segmented, TopNav } from "../components/kit";
import { SignInButtons } from "../components/SignInButtons";
import { errorMessage } from "../lib/api";
import {
  FINISH_LETTER, RARITY_NAME, cardImageUrl, cornerRatio, coverPrinting, loadCatalog, normName, oracleIndexById, searchCatalog, type Catalog,
} from "../lib/catalog";
import {
  applyOps, fetchHistory, undoBatch, useCollection, type ApplyResult, type Finish, type HistoryEntry, type Item,
} from "../lib/collection";
import { supabase } from "../lib/supabaseClient";
import { useSession } from "../lib/useSession";
import { isLibraryDemo, loadDemoLists } from "../lib/libraryDemo";
import { useLists } from "../lib/lists";
import { DEMO_USER, type Condition } from "../lib/collection";
import { usdPrice, usdText, usePrices } from "../lib/prices";
import { useTrades } from "../lib/trades";

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

export function BarToggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <button type="button" onClick={() => onChange(!on)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">
      {on ? "List" : "Grid"}
    </button>
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

export function CardArt({ c, p, width, alt = "" }: { c: Catalog; p: number | null; width: number; alt?: string }) {
  const height = Math.round(width / ASPECT);
  const radius = p == null ? width * 0.0432 : width * cornerRatio(c.pSet[p]);
  if (p == null || c.pFaces[p] === 0) {
    return <div className="bg-t1-bg shrink-0" style={{ width, height, borderRadius: radius }} />;
  }
  const px = width * (typeof window === "undefined" ? 1 : window.devicePixelRatio || 1);
  const size = px <= 146 ? "small" : px <= 488 ? "normal" : "large";
  return (
    <img src={cardImageUrl(c, p, size)} alt={alt} width={width} height={height} loading="lazy" decoding="async"
         draggable={false} className="bg-t1-bg shrink-0 object-cover block" style={{ width, height, borderRadius: radius }} />
  );
}

/** A list row led by a card thumbnail; same type and spacing as Row. */
export function CardRow({ c, p, title, detail, value, warn, onClick }: {
  c: Catalog; p: number | null; title: ReactNode; detail?: ReactNode; value?: ReactNode; warn?: boolean; onClick?: () => void;
}) {
  return (
    <button type="button" onClick={onClick}
            className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-[5px] h-full flex items-center gap-3 text-left w-full">
      <CardArt c={c} p={p} width={36} />
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        <span className="text-[13px] truncate">{title}</span>
        {detail && <span className="t1-label truncate">{detail}</span>}
      </span>
      {value != null && <span className={`shrink-0 text-[13px] tabular-nums ${warn ? "text-t1-error" : ""}`}>{value}</span>}
    </button>
  );
}

/** One grid cell: the image with a count tag in the corner. */
export function CardTile({ c, p, name, qty, width, warn, onClick }: {
  c: Catalog; p: number | null; name: string; qty: number; width: number; warn?: boolean; onClick?: () => void;
}) {
  return (
    <button type="button" onClick={onClick} aria-label={`${name}, ${qty}`} className="relative block" style={{ width }}>
      <CardArt c={c} p={p} width={width} alt={name} />
      {/* Inset past the rounded corner so the tag never gets clipped. */}
      <span className={`absolute px-1.5 py-0.5 text-[13px] tabular-nums ${warn ? "bg-t1-error text-t1-bg" : "bg-t1-bg text-t1-text"}`}
            style={{ right: Math.round(width * 0.05), bottom: Math.round(width * 0.05) }}>
        {qty}
      </span>
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

export function useStoredFlag(key: string): [boolean, (v: boolean) => void] {
  const [v, setV] = useState(() => {
    try {
      return localStorage.getItem(key) === "1";
    } catch {
      return false;
    }
  });
  const set = (next: boolean) => {
    setV(next);
    try {
      localStorage.setItem(key, next ? "1" : "0");
    } catch {
      /* storage blocked: keep it for this visit */
    }
  };
  return [v, set];
}

/* ── home ─────────────────────────────────────────────────────────────── */

export function LibraryHome({ onAllCards, onAdd, onDecks, onCubes, onTrades }: {
  onAllCards: () => void; onAdd: () => void; onDecks: () => void; onCubes: () => void; onTrades: () => void;
}) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const decks = lists.lists.filter((l) => l.kind === "deck");
  const cubes = lists.lists.filter((l) => l.kind === "cube");
  const trades = useTrades();
  const openTrades = trades.trades.filter((t) => t.status === "draft").length;
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="Library" />;
  const s = col.summary;
  return (
    <Screen>
      <TopNav />
      <Bar title="Library" subtitle={userId === DEMO_USER ? "Demo data" : col.syncing ? "Syncing…" : undefined} />
      {col.error && <Notice tone="error">{col.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-1">
          <p className="t1-label">Cards</p>
          <p className="text-[48px] tabular-nums tracking-[4px]">{s ? s.total_qty.toLocaleString() : col.ready ? "0" : "…"}</p>
          <p className="t1-label">
            {s ? `${s.unique_cards.toLocaleString()} distinct · ${money(s.value_usd, "USD")} · ${money(s.value_eur, "EUR")}` : " "}
          </p>
        </div>
        <Row title="All cards" detail={s ? `${s.unique_printings.toLocaleString()} printings` : undefined}
             value={s ? s.unique_cards.toLocaleString() : undefined} onClick={onAllCards} />
        <Row title="Add cards" detail="Search by name" onClick={onAdd} />
        <Row title="Decks" detail={decks.length ? decks.slice(0, 3).map((l) => l.name).join(" · ") : "Build and track decks"}
             value={decks.length} onClick={onDecks} />
        <Row title="Cubes" detail={cubes.length ? cubes.map((l) => l.name).join(" · ") : "Build and track cubes"}
             value={cubes.length} onClick={onCubes} />
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
        qty: 0, printings: 0, lastSeq: 0, cover: null, coverQty: 0, owned: [],
      };
      by.set(key, g);
      seenPrinting.set(key, new Set());
    }
    g.qty += it.qty;
    g.lastSeq = Math.max(g.lastSeq, it.seq);
    g.owned.push([it.cardId, it.finish]);
    if (p != null && it.qty > g.coverQty) {
      g.cover = p;
      g.coverQty = it.qty;
    }
    const ps = seenPrinting.get(key)!;
    if (!ps.has(it.cardId)) {
      ps.add(it.cardId);
      g.printings++;
    }
  }
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
  const [grid, setGrid] = useStoredFlag("table1.library.allCards.grid");

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
      const p = new Map(list.map((g) => [g.key, priceOf(g) ?? -1]));
      list.sort((a, b) => p.get(b.key)! - p.get(a.key)! || byName(a, b));
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

  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <SignedOut title="All cards" />;
  return (
    <LibScreen>
      <Bar title="All cards" subtitle={col.summary ? `${col.summary.total_qty.toLocaleString()} cards` : undefined}
           onBack={onBack} right={<BarToggle on={grid} onChange={setGrid} />} />
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
      {catalog && shown.length > 0 && (grid ? (
        <VirtualGrid items={shown} cell={(g, w) => (
          <CardTile c={catalog} p={g.cover} name={g.name} qty={g.qty} width={w} onClick={() => g.oracle >= 0 && onOpen(g.key)} />
        )} />
      ) : (
        <VirtualList rows={shown} render={(g) => (
          <CardRow c={catalog} p={g.cover} title={g.name} detail={detail(g)}
                   value={g.qty} onClick={() => g.oracle >= 0 && onOpen(g.key)} />
        )} />
      ))}
    </LibScreen>
  );
}

/* ── add (search) ─────────────────────────────────────────────────────── */

export function AddCards({ onBack, onOpen }: { onBack: () => void; onOpen: (oracleId: string) => void }) {
  const { catalog, error } = useCatalog();
  const [q, setQ] = useState("");
  const hits = useMemo(() => (catalog ? searchCatalog(catalog, q, 40) : []), [catalog, q]);
  return (
    <LibScreen>
      <Bar title="Add cards" onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      <Field label="Card name" value={q} onChange={setQ} placeholder="Lightning Bolt" autoFocus />
      {!catalog && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {catalog && q.trim().length >= 2 && hits.length === 0 && (
          <div className="bg-t1-surface px-4 py-4 t1-label">No card by that name</div>
        )}
        {catalog && hits.map((i) => (
          <div key={i} style={{ height: ROW_H }}>
            <CardRow c={catalog} p={coverPrinting(catalog, i)} title={catalog.oName[i]}
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

export function CardDetail({ oracleId, onBack }: { oracleId: string; onBack: () => void }) {
  const { session, ready, userId } = useLibrarySession();
  const col = useCollection(userId);
  const { catalog, error: catError } = useCatalog();
  const [prices, setPrices] = useState<Map<string, PrintingPrice>>(new Map());
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [last, setLast] = useState<{ res: ApplyResult; label: string } | null>(null);
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
  /** Moving copies of one owned item to another condition, when there's more than one copy. */
  const [moving, setMoving] = useState<{ k: string; to: Condition } | null>(null);

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
      .sort((a, b) => (catalog.printingIndex.get(a.cardId)! - catalog.printingIndex.get(b.cardId)!) || a.k.localeCompare(b.k));
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
      setLast({ res, label });
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
      await undoBatch(last.res.batch_id);
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

  const first = catalog.pFirst[oi];
  const count = catalog.pCount[oi];
  const heroP = preview ?? (owned.length ? catalog.printingIndex.get(owned[0].cardId)! : coverPrinting(catalog, oi));
  const total = owned.reduce((n, it) => n + it.qty, 0);
  const setLabel = (p: number) => `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  // The original paper printing (the default for adds) first, then newest first.
  const orig = catalog.oOriginal[oi];
  const printings = Array.from({ length: count }, (_, i) => first + i).sort((a, b) => Number(b === orig) - Number(a === orig));

  return (
    <LibScreen>
      <Bar title={catalog.oName[oi]} subtitle={`${total} in collection`} onBack={onBack} />
      {(error || col.error) && <Notice tone="error">{error ?? col.error}</Notice>}
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
                  <CardArt c={catalog} p={p} width={36} />
                  <span className="min-w-0 flex flex-col gap-0.5">
                    <span className="text-[13px] truncate">{setLabel(p)} · {FINISH_LABEL[it.finish]}</span>
                    <span className="t1-label truncate">
                      {[prices.get(it.cardId)?.set_name, it.condition, it.lang.toUpperCase(), price].filter(Boolean).join(" · ")}
                    </span>
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

        <Section title="Add a printing" count={count} right={<span title={CONDITION_NAME[addCondition]}>Adds as {addCondition}</span>} />
        <Segmented options={CONDITIONS.map((c) => ({ value: c, label: c }))} value={addCondition} onChange={setAddCondition} />
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
                return (
                  <button key={f} type="button" disabled={busy === k} title={priceFor(pr, f) ?? undefined}
                          onClick={() => change(k, `Added 1 ${setLabel(p)} ${FINISH_LABEL[f]} · ${addCondition}`, { card_id: catalog.pId[p], finish: f, condition: addCondition, delta: 1 })}
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
