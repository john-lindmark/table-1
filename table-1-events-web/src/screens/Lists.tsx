import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Field, GhostAction, Modal, Notice, Row, Screen, Section, Segmented } from "../components/kit";
import { CANLANDER_POINT_LIMIT, basicCardIds, coverPrinting, formatName, legalityOf, type Catalog } from "../lib/catalog";
import { DEMO_USER, useCollection } from "../lib/collection";
import { loadDemoLists } from "../lib/libraryDemo";
import {
  EXPORT_DETAIL, EXPORT_FILE, exportFileName, exportFormats, exportLines, renderList, type ExportFormat,
} from "../lib/listExport";
import { GROUPING_KEY, groupLabel, keyFor, keysOf, sortGroups, useStoredGrouping, type GroupKeys, type Grouping } from "../lib/cardGrouping";
import { SORT_KEY, applySort, sortKeyOf, useStoredSort, type CardSort } from "../lib/cardSort";
import {
  boardTitle, boardsOf, countOf, createList, finishOf, ownKey, type ListFinish, current, deleteList, diff, duplicateList, editList, entriesOf, missingIn, restoreList,
  sectionsFor, useLists, type Board, type CardList, type Entry, type ListKind,
} from "../lib/lists";
import { cardMatches, matchingLines } from "../lib/librarySearch";
import { capture } from "../lib/telemetry";
import { useSearchUsed } from "./Binders";
import {
  CardGroupRow, CardRow, CardTile, HeroListRow, LibScreen, StackRows, ViewButton, useCatalog, useLibraryHeroes, useLibrarySession, useStoredLayout,
  type StackCardItem, type StackItem,
} from "./Library";
import { COLLAPSED, isOpen, lineGroups, toggleOne, type Disclosure, type LineGroup } from "../lib/printings";
import { HERO_LIMIT, heroPrintings, heroesOf, isHero, toggleHero, type HeroScope } from "../lib/heroes";
import { CardSearchBar, CardSearchStatus, useCardSearch } from "./CardSearch";
import { ListStatsRow } from "./ListStats";
import { RankingsRow } from "./Rankings";
import { DeckImageScreen } from "./DeckImage";
import { ListToCollectionScreen } from "./ListToCollection";
import { ShareRow } from "./Share";

/* Decks and cubes on the web (contract/lists-2026-10-15.md): the same lists, sections, groups and version
   history as iOS, read from and written to the database, so a deck built on one device is here too. */

export function useListsData() {
  const { session, ready, userId } = useLibrarySession();
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const col = useCollection(userId);
  const owned = useMemo(() => {
    const m = new Map<string, number>();
    // Per printing and finish: a foil line is covered only by foil copies of that printing.
    for (const it of col.items.values()) m.set(ownKey(it.cardId, it.finish), (m.get(ownKey(it.cardId, it.finish)) ?? 0) + it.qty);
    return m;
  }, [col.version]);
  return { session, ready, lists, owned };
}

const fmtDate = (epoch: number) => new Date(epoch * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });

/* ── grouping: lib/cardGrouping (decks start on Type, cubes on Color; Group by in the View menu) ── */

export interface Line {
  cardId: string;
  p: number | null;
  oracleId: string | null;
  name: string;
  /** The heading it sits under: type for decks, color for cubes, or the Group by picked. */
  group: string;
  /** Its group under each grouping. */
  keys: GroupKeys;
  board: Board;
  qty: number;
  oi: number;
  finish: ListFinish;
  points: number;
  basic: boolean;
  type: string;
}

const FINISH_NAME: Record<ListFinish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };
const lineKey = (x: Line) => `${x.board}|${x.cardId}|${x.finish}`;

function linesOf(l: CardList, c: Catalog): Line[] {
  return resolveLines(entriesOf(l), l.kind, c);
}

/** A list's entries as lines with card details, by name; grouped by type (decks) or color (cubes) to start. */
export function resolveLines(entries: Entry[], kind: ListKind, c: Catalog): Line[] {
  return entries.map((e) => {
    const p = c.printingIndex.get(e.cardId) ?? null;
    const oi = p == null ? -1 : c.pOracle[p];
    const type = oi >= 0 ? c.oType[oi].split(" // ")[0] : "";
    const keys = keysOf(c, oi);
    return { cardId: e.cardId, p, oracleId: oi >= 0 ? c.oId[oi] : null, name: oi >= 0 ? c.oName[oi] : "Unknown card", group: keys[kind === "deck" ? "type" : "color"], keys,
             board: e.board, qty: e.qty, oi, finish: finishOf(e),
             points: oi >= 0 ? c.oPoints[oi] : 0, basic: type.includes("Basic"), type: oi >= 0 ? c.oType[oi] : "" };
  }).sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Why each card can't be played in the deck's format, by oracle id: banned, not legal, or a restricted card
 * with more than one copy across the main deck and sideboard. Cubes and unchecked formats have none.
 */
function issuesOf(lines: Line[], l: CardList, c: Catalog): Map<string, string> {
  const out = new Map<string, string>();
  if (l.kind !== "deck") return out;
  const copies = new Map<string, number>();
  for (const x of lines) if (x.board !== "maybe") copies.set(x.oracleId ?? x.cardId, (copies.get(x.oracleId ?? x.cardId) ?? 0) + x.qty);
  for (const x of lines) {
    if (x.oi < 0) continue;
    const key = x.oracleId ?? x.cardId;
    const legal = legalityOf(c, x.oi, l.format);
    if (legal === "banned") out.set(key, "Banned");
    else if (legal === "not_legal") out.set(key, "Not legal");
    else if (legal === "restricted" && (copies.get(key) ?? 0) > 1) out.set(key, "Restricted to 1");
    else if (l.format === "canlander" && !x.basic && (copies.get(key) ?? 0) > 1) out.set(key, "Singleton");
  }
  return out;
}

/** Canadian Highlander points in the main deck and sideboard (Considering doesn't count), highest first. */
function pointsOf(lines: Line[]): { total: number; cards: [string, number][] } {
  const by = new Map<string, number>();
  for (const x of lines) if (x.board !== "maybe" && x.points > 0) by.set(x.name, (by.get(x.name) ?? 0) + x.points * x.qty);
  const cards = [...by].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  return { total: cards.reduce((n, [, p]) => n + p, 0), cards };
}

export const groupsOf = (lines: { group: string }[], by: Grouping): string[] => sortGroups(by, lines.map((x) => x.group));

/** The lines under another grouping. */
export const regrouped = <T extends { group: string; keys: GroupKeys }>(lines: T[], by: Grouping): T[] => lines.map((x) => ({ ...x, group: keyFor(x.keys, by) }));

/** Group by for decks or cubes, shared between your own and the ones shared with you. */
export function useListGrouping(kind: ListKind | null | undefined): [Grouping, (g: Grouping) => void] {
  const deck = useStoredGrouping(GROUPING_KEY.deck, "type", true);
  const cube = useStoredGrouping(GROUPING_KEY.cube, "color", true);
  return kind === "cube" ? cube : deck;
}

/** Sort for decks or cubes, shared between your own and the ones shared with you (both start on Name). */
export function useListSort(kind: ListKind | null | undefined): [CardSort, (s: CardSort) => void] {
  const deck = useStoredSort(SORT_KEY.deck, "list");
  const cube = useStoredSort(SORT_KEY.cube, "list");
  return kind === "cube" ? cube : deck;
}

/** Lines in a sort (they're resolved by name). */
export const sortLines = <T extends { name: string; oi: number; p: number | null }>(lines: T[], by: CardSort, c: Catalog): T[] =>
  applySort(lines, by, (x) => sortKeyOf(c, x.name, x.oi, x.p));

export function BoardHeader({ title, count }: { title: string; count: number }) {
  return (
    <div className="bg-t1-surface-hover px-4 py-3.5 flex items-center justify-between">
      <span className="text-[13px] uppercase tracking-[2px]">{title}</span>
      <span className="text-[15px] tabular-nums">{count}</span>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex-1 flex flex-col items-center gap-0.5">
      <span className="t1-label">{label}</span>
      <span className="text-[22px] tabular-nums">{value}</span>
    </div>
  );
}

/* ── lists of one kind ────────────────────────────────────────────────── */

const DECK_FORMATS = ["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "canlander", "other"];
const CUBE_FORMATS = ["vintage", "legacy", "pauper", "peasant", "other"];

export function ListsScreen({ kind, onBack, onOpen, onFind, onImport, onRankings }: {
  kind: ListKind; onBack: () => void; onOpen: (id: string) => void; onFind: () => void; onImport: () => void;
  /** Cubes: every ranking of yours (contract/cube-rankings-2026-10-21.md). */
  onRankings?: () => void;
}) {
  const { session, ready, lists, owned } = useListsData();
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [format, setFormat] = useState(kind === "deck" ? "modern" : "vintage");
  const [busy, setBusy] = useState(false);
  const mine = lists.lists.filter((l) => l.kind === kind);
  const heroes = useLibraryHeroes();
  const { catalog } = useCatalog();
  /** Each list's hero cards, as the printings it holds. */
  const heroArt = useMemo(() => {
    const m = new Map<string, number[]>();
    if (!catalog) return m;
    for (const l of mine) {
      const h = heroesOf({ kind: "list", id: l.id }, heroes);
      if (h.length) m.set(l.id, heroPrintings(catalog, h, entriesOf(l).slice().sort((a, b) => b.qty - a.qty).map((e) => e.cardId)));
    }
    return m;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, heroes, lists.lists, kind]);
  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <Screen><Bar title={kind === "deck" ? "Decks" : "Cubes"} /><Notice tone="info">Sign in to keep decks and cubes.</Notice></Screen>;

  const create = async () => {
    setBusy(true);
    try {
      const id = await createList(kind, name.trim().slice(0, 60), format);
      setCreating(false);
      setName("");
      onOpen(id);
    } finally {
      setBusy(false);
    }
  };

  return (
    <LibScreen>
      <Bar title={kind === "deck" ? "Decks" : "Cubes"} subtitle={`${mine.length}`} onBack={onBack} />
      {lists.error && <Notice tone="error">{lists.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Row title={kind === "deck" ? "New deck" : "New cube"} detail="Name it, then add cards" onClick={() => setCreating(true)} />
        {kind === "cube" && onRankings && <Row title="Rankings" detail="Yours, and friends' cubes you can rank" onClick={onRankings} />}
        {mine.map((l) => {
          const miss = missingIn(l, owned, basicCardIds(catalog));
          const side = countOf(l, "side"), maybe = countOf(l, "maybe");
          const detail = [formatName(l.format), side ? `${side} sideboard` : null, maybe ? `${maybe} considering` : null,
                          l.eventId ? `From ${l.eventName ?? "an event"}` : miss ? `${miss} missing` : "All owned", `v${current(l).number}`].filter(Boolean).join(" · ");
          return <HeroListRow key={l.id} c={catalog} heroes={heroArt.get(l.id) ?? []} title={l.name} detail={detail} value={countOf(l, "main")} onClick={() => onOpen(l.id)} />;
        })}
      </div>
      {creating && (
        <Modal title={kind === "deck" ? "New deck" : "New cube"} onClose={() => setCreating(false)}>
          <Field label="Name" value={name} onChange={setName} autoFocus />
          <Segmented options={(kind === "deck" ? DECK_FORMATS : CUBE_FORMATS).map((f) => ({ value: f, label: f }))}
                     value={format} onChange={setFormat} columns={4} />
          <BigAction label={kind === "deck" ? "Create deck" : "Create cube"} onClick={create} disabled={!name.trim()} busy={busy} />
          <Row title="Import from a link or list" detail={kind === "deck" ? "Moxfield, ManaBox, Archidekt, MTGGoldfish" : "Cube Cobra, or a pasted list"}
               onClick={() => { setCreating(false); onImport(); }} />
          {kind === "deck" && <Row title="Find a deck online" detail="Describe it; we load a recent tournament list"
                                   onClick={() => { setCreating(false); onFind(); }} />}
        </Modal>
      )}
    </LibScreen>
  );
}

/* ── one list ─────────────────────────────────────────────────────────── */

const EXPORT_SHORT: Record<ExportFormat, string> = { text: "Text", arena: "Arena", moxfield: "Moxfield", mtgo: "MTGO", cubecobra: "Cube Cobra" };

function download(text: string, name: string) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type: name.endsWith(".csv") ? "text/csv;charset=utf-8" : "text/plain;charset=utf-8" }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
}

/** The Clipboard API, or where a browser refuses it (no permission, an embedded frame), a selected text area. */
async function writeClipboard(text: string) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (e) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.cssText = "position:fixed;top:0;left:0;opacity:0";
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    if (!ok) throw e;
  }
}

/**
 * Export for a deck or cube (contract/shared-lists-grouping-2026-10-20.md §2), over the page: a format picker, the list
 * as selectable text in that format, then the ways out: to Arena (copied: Arena imports from the clipboard) and MTGO
 * (a .txt file) for decks, to Cube Cobra (a CSV file) for cubes, and Download / Copy of the text shown. Your own lists
 * and decks or cubes shared with you on a profile use the same screen. Output is listExport's, unchanged.
 */
export function ExportScreen({ name, kind, entries, catalog, from, onClose }: {
  name: string; kind: ListKind; entries: Entry[]; catalog: Catalog; from: "own" | "profile"; onClose: () => void;
}) {
  const formats: ExportFormat[] = ["text", ...exportFormats(kind).filter((f) => f !== "text")];
  const [format, setFormat] = useState<ExportFormat>("text");
  const [note, setNote] = useState<string | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  const { texts, cards, left } = useMemo(() => {
    const { lines, left } = exportLines(catalog, entries);
    return { texts: new Map(formats.map((f) => [f, renderList(lines, kind, f)])), cards: lines.reduce((n, l) => n + l.qty, 0), left };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [catalog, entries, kind]);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);
  const sent = (f: ExportFormat, how: "copy" | "download") => capture("list_exported", { kind, format: f, cards, left, from, how });
  const copy = async (f: ExportFormat, done: string) => {
    try {
      await writeClipboard(texts.get(f)!);
      setNote(done);
      setFail(null);
      sent(f, "copy");
    } catch {
      setFail("Couldn't copy here. Select the text and copy it, or download it.");
    }
  };
  const save = (f: ExportFormat) => {
    const file = exportFileName(name, kind, f);
    download(texts.get(f)!, file);
    setNote(`Downloaded ${file}.`);
    setFail(null);
    sent(f, "download");
  };
  const leftNote = left ? `${left} card${left === 1 ? "" : "s"} newer than the card data ${left === 1 ? "was" : "were"} left out.` : null;
  const accent = "flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px] text-t1-accent";
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={`Export ${name}`}>
      <Bar title="Export" subtitle={name} onBack={onClose} />
      <Segmented options={formats.map((f) => ({ value: f, label: EXPORT_SHORT[f] }))} value={format}
                 onChange={(f) => { setFormat(f); setNote(null); setFail(null); }} />
      <Notice tone="info">{EXPORT_DETAIL[format]}</Notice>
      <pre className="flex-1 min-h-0 overflow-auto bg-t1-surface p-4 m-0 text-[13px] leading-[19px] whitespace-pre select-text font-[inherit]">
        {texts.get(format)}
      </pre>
      {fail && <Notice tone="error">{fail}</Notice>}
      {(note ?? leftNote) && <Notice tone="info">{note ?? leftNote}</Notice>}
      <div className="shrink-0 flex gap-px">
        {kind === "deck" ? (<>
          <button type="button" className={accent} onClick={() => void copy("arena", "Copied for MTG Arena. In Arena: Decks → Import.")}>To Arena</button>
          <button type="button" className={accent} onClick={() => save("mtgo")}>To MTGO</button>
        </>) : (
          <button type="button" className={accent} onClick={() => save("cubecobra")}>To Cube Cobra</button>
        )}
      </div>
      <div className="shrink-0 flex gap-px pb-px">
        <GhostAction label={`Download .${EXPORT_FILE[format] ?? "txt"}`} onClick={() => save(format)} />
        <GhostAction label="Copy text" onClick={() => void copy(format, "Copied.")} />
      </div>
    </div>
  );
}

export function ListScreen({ id, onBack, onCard, onAdd, onVersions, onOpen, onPrinting, onStats, onRankings }: {
  id: string; onBack: () => void; onCard: (oracleId: string) => void; onAdd: () => void; onVersions: () => void;
  onOpen: (listId: string) => void; onPrinting: (cardId: string, board: Board, finish: ListFinish) => void; onStats: () => void;
  /** Cubes: the Rankings row. */
  onRankings?: () => void;
}) {
  const { session, ready, lists, owned } = useListsData();
  const { catalog, error } = useCatalog();
  const [layout, setLayout] = useStoredLayout("table1.library.list.layout", "table1.library.list.grid");
  const [editing, setEditing] = useState(false);
  const [moving, setMoving] = useState<Line | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [imaging, setImaging] = useState(false);
  const [adding, setAdding] = useState(false);
  const [q, setQ] = useState("");
  const [printings, setPrintings] = useState<Disclosure>(COLLAPSED);
  const [heroFull, setHeroFull] = useState<string | null>(null);
  const heroes = useLibraryHeroes();
  const list = lists.lists.find((l) => l.id === id) ?? null;
  const [grouping, setGrouping] = useListGrouping(list?.kind);
  const [sort, setSort] = useListSort(list?.kind);
  const heroScope: HeroScope = { kind: "list", id };
  useSearchUsed(q, list?.kind === "deck" ? "deck" : "cube");
  const lines = useMemo(() => (list && catalog ? sortLines(regrouped(linesOf(list, catalog), grouping), sort, catalog) : []), [list, catalog, grouping, sort]);
  const issues = useMemo(() => (list && catalog ? issuesOf(lines, list, catalog) : new Map<string, string>()), [lines, list, catalog]);
  const boxRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(390);
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, [list?.id]);

  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) return <Screen><Bar title="List" /><Notice tone="info">Sign in to keep decks and cubes.</Notice></Screen>;
  if (!list) {
    return (
      <Screen>
        <Bar title="List" onBack={onBack} />
        <Notice tone="info">{lists.ready ? "That list isn't here anymore." : "Loading…"}</Notice>
      </Screen>
    );
  }
  const searching = q.trim().length > 0;
  const shown = searching ? lines.filter((x) => cardMatches(q, x.name, x.type)) : lines;
  const cols = Math.max(3, Math.floor(width / 180));
  const tile = Math.floor((width - (cols - 1)) / cols);
  const v = current(list);

  const lineRow = (x: Line, sub = false) => {
    const have = owned.get(ownKey(x.cardId, x.finish)) ?? 0;
    const fin = x.finish === "nonfoil" ? null : FINISH_NAME[x.finish];
    const pts = x.points > 0 && list.format === "canlander" ? `${x.points} pt${x.points === 1 ? "" : "s"}` : null;
    const considering = x.board === "maybe";
    const short = !considering && !list.eventId && !x.basic && have < x.qty; // basics are never missing
    const issue = issues.get(x.oracleId ?? x.cardId);
    if (editing) {
      return (
        <div key={lineKey(x)} className="flex items-stretch gap-px h-[60px]">
          <div className="flex-1 min-w-0">
            <CardRow c={catalog!} p={x.p} title={x.name} detail={[fin, "Tap to move, change or remove"].filter(Boolean).join(" · ")}
                     finish={x.finish} hero={isHero(x.oracleId, heroScope, heroes)} value={x.qty} onClick={() => setMoving(x)} />
          </div>
          <button type="button" aria-label="Remove one" className="w-14 bg-t1-surface-hover text-[20px]"
                  onClick={() => editList(list.id, [{ card_id: x.cardId, board: x.board, finish: x.finish, delta: -1 }])}>−</button>
          <button type="button" aria-label="Add one" className="w-14 bg-t1-surface-hover text-[20px]"
                  onClick={() => editList(list.id, [{ card_id: x.cardId, board: x.board, finish: x.finish, delta: 1 }])}>+</button>
        </div>
      );
    }
    return (
      <div key={lineKey(x)} className="h-[60px] shrink-0">
        <CardRow c={catalog!} p={x.p} value={x.qty} warn={short || !!issue} finish={x.finish} indent={sub}
                 title={sub && x.p != null ? `${catalog!.pSet[x.p].toUpperCase()} #${catalog!.pCn[x.p]}` : x.name}
                 hero={!sub && isHero(x.oracleId, heroScope, heroes)}
                 detail={[issue && !sub ? issue : null, pts, fin,
                          considering ? (have ? `Owned ${have}` : "Not owned") : short ? `Owned ${have} · missing ${x.qty - have}` : x.basic && !have ? null : `Owned ${have}`]
                         .filter(Boolean).join(" · ")}
                 onClick={() => x.oracleId && onCard(x.oracleId)} />
      </div>
    );
  };

  /** A card with one line is that line's row; with several, a summary row with a chevron that opens one row per
   *  printing and finish. */
  const groupRows = (cg: LineGroup<Line>) => {
    if (cg.lines.length === 1) return lineRow(cg.lines[0]);
    const lead = cg.lines[0];
    const open = isOpen(printings, cg.id);
    const hero = isHero(lead.oracleId, heroScope, heroes);
    const considering = lead.board === "maybe";
    const issue = issues.get(lead.oracleId ?? lead.cardId);
    // Basics are never missing (contract/basics-2026-10-24.md).
    const short = lead.basic ? 0 : cg.lines.reduce((n, l) => n + Math.max(0, l.qty - (owned.get(ownKey(l.cardId, l.finish)) ?? 0)), 0);
    const have = cg.lines.reduce((n, l) => n + (owned.get(ownKey(l.cardId, l.finish)) ?? 0), 0);
    const haveText = list.eventId ? null : considering ? (have ? `Owned ${have}` : "Not owned")
      : lead.basic ? (have ? `Owned ${have}` : null) : short ? `Missing ${short}` : "All owned";
    return (
      <div key={cg.id} className="flex flex-col gap-px">
        <div className="h-[60px] shrink-0">
          <CardGroupRow open={open} parts={cg.lines.length} hero={hero}
                        onToggle={() => { setPrintings(toggleOne(printings, cg.id)); capture("printings_toggled", { expanded: !open, all: false, screen: "list" }); }}>
            <CardRow c={catalog!} p={lead.p} title={lead.name} value={cg.qty} warn={(!considering && short > 0 && !list.eventId) || !!issue}
                     finish={lead.finish} hero={hero}
                     detail={[issue, `${cg.lines.length} printings`, haveText].filter(Boolean).join(" · ")}
                     onClick={() => lead.oracleId && onCard(lead.oracleId)} />
          </CardGroupRow>
        </div>
        {open && cg.lines.map((l) => lineRow(l, true))}
      </div>
    );
  };

  /** Grid and stack cards for one group: one per card, or with every printing expanded, one per line. */
  const tiles = (inGroup: Line[]): StackCardItem[] => lineGroups(inGroup).flatMap((cg) => {
    const lead = cg.lines[0];
    const hero = isHero(lead.oracleId, heroScope, heroes);
    const onClick = () => lead.oracleId && onCard(lead.oracleId);
    const warn = (ls: Line[]) => (lead.board !== "maybe" && ls.some((l) => (owned.get(ownKey(l.cardId, l.finish)) ?? 0) < l.qty)) || issues.has(lead.oracleId ?? lead.cardId);
    if (!printings.all || cg.lines.length < 2) {
      return [{ key: cg.id, p: lead.p, name: lead.name, qty: cg.qty, warn: warn(cg.lines), finish: lead.finish, hero, onClick }];
    }
    return cg.lines.map((l) => ({ key: lineKey(l), p: l.p, name: l.name, qty: l.qty, warn: warn([l]), finish: l.finish, hero, onClick }));
  });

  return (
    <LibScreen width="wide">
      <Bar title={list.name} subtitle={list.eventId ? `From ${list.eventName ?? "an event"} · v${v.number}` : `${formatName(list.format)} ${list.kind} · v${v.number}`} onBack={onBack}
           right={<span className="flex gap-4">
             <button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => setEditing(!editing)}>{editing ? "Done" : "Edit"}</button>
             {!editing && <ViewButton layout={layout} onChange={setLayout} screen={list.kind === "cube" ? "cube" : "deck"} printings={printings} onPrintings={setPrintings}
                                      grouping={grouping} onGrouping={setGrouping} list sort={sort} onSort={setSort} sorts="list" />}
           </span>} />
      {(lists.error || error || heroFull) && <Notice tone="error">{lists.error ?? error ?? heroFull}</Notice>}
      {entriesOf(list).length > 0 && <Field label={list.kind === "cube" ? "Search this cube" : "Search this deck"} value={q} onChange={setQ} placeholder="Name or type" />}
      <div ref={boxRef} className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {/* While searching, matches come first. */}
        {!searching && <>
        {(() => {
          // Considering cards are flagged on their rows but don't make the deck unplayable.
          const bad = [...new Set(lines.filter((x) => x.board !== "maybe" && issues.has(x.oracleId ?? x.cardId)).map((x) => x.name))].sort();
          if (!bad.length) return null;
          const names = bad.slice(0, 3).join(", ") + (bad.length > 3 ? ` and ${bad.length - 3} more` : "");
          const fmt = formatName(list.format);
          return <Notice tone="error">{bad.length === 1 ? "1 card isn't" : `${bad.length} cards aren't`} legal in {fmt}: {names}</Notice>;
        })()}
        {list.kind === "deck" && list.format === "canlander" && (() => {
          const pts = pointsOf(lines);
          const detail = pts.cards.slice(0, 6).map(([n, p]) => `${n} ${p}`).join(", ") + (pts.cards.length > 6 ? ", …" : "");
          const main = countOf(list, "main");
          return (
            <>
              {pts.total > CANLANDER_POINT_LIMIT && <Notice tone="error">Over the points limit: {pts.total} of {CANLANDER_POINT_LIMIT}. {detail}</Notice>}
              {pts.total > 0 && pts.total <= CANLANDER_POINT_LIMIT && <Notice tone="info">Points: {pts.total} of {CANLANDER_POINT_LIMIT}. {detail}</Notice>}
              {main < 100 && <Notice tone="info">Canadian Highlander decks need at least 100 cards: {main} so far.</Notice>}
            </>
          );
        })()}
        {/* Desktop: the screen's actions three across. */}
        <div className="flex flex-col gap-px lg:grid lg:grid-cols-3">
        {editing && <Row title={list.kind === "deck" ? "Duplicate deck" : "Duplicate cube"} detail="A new list with these cards"
                         onClick={() => { void duplicateList(list).then((copy) => { setEditing(false); onOpen(copy); }); }} />}
        {editing && <Row title={list.kind === "deck" ? "Delete deck" : "Delete cube"} detail="From every device" onClick={() => setConfirmDelete(true)} />}
        {!editing && catalog && <ListStatsRow list={list} catalog={catalog} onOpen={onStats} />}
        {!editing && list.kind === "cube" && onRankings && entriesOf(list).length > 0 && <RankingsRow listId={list.id} onOpen={onRankings} />}
        <Row title="Add, remove or replace" detail={list.kind === "deck" ? "Main deck, sideboard or considering" : "Search the catalog, or this cube's own cards"} onClick={onAdd} />
        <Row title="Version history" detail={`v${v.number} · ${v.note} · ${fmtDate(v.at)}`} value={list.versions.length} onClick={onVersions} />
        {!editing && !list.eventId && (
          <ShareRow target={{ part: list.kind, id: list.id, name: list.name }} from={list.kind}
                    onExport={entriesOf(list).length > 0 && catalog ? () => setExporting(true) : undefined}
                    onImage={entriesOf(list).length > 0 && catalog && list.kind === "deck" ? () => setImaging(true) : undefined} />
        )}
        {entriesOf(list).length > 0 && !editing && catalog &&
          <Row title="Export" detail={list.kind === "deck" ? "Text, Arena, MTGO, download or copy" : "Text, Cube Cobra, download or copy"}
               onClick={() => setExporting(true)} />}
        {entriesOf(list).length > 0 && !editing && catalog && list.kind === "deck" &&
          <Row title="Deck image" detail="The cards as a picture, to save or share" onClick={() => setImaging(true)} />}
        {/* A roto deck's cards are the cube's, not yours to add. */}
        {entriesOf(list).length > 0 && !editing && catalog && !list.eventId && (() => {
          const miss = missingIn(list, owned, basicCardIds(catalog));
          return <Row title="Add to collection" detail={miss ? `Missing ${miss} · or every card` : "You own every card · add more copies"} onClick={() => setAdding(true)} />;
        })()}
        {entriesOf(list).length === 0 && <Row title="No cards yet" detail="Add cards to start this list" />}
        </div>
        </>}
        {searching && catalog && !shown.length && <Row title="No cards match" />}
        {!catalog && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
        {catalog && boardsOf(list).filter((bd) => !searching || shown.some((x) => x.board === bd)).map((board) => {
          const inBoard = shown.filter((x) => x.board === board);
          return (
            <div key={board} className="flex flex-col gap-px">
              <BoardHeader title={boardTitle(list.kind, board)} count={inBoard.reduce((n, x) => n + x.qty, 0)} />
              {/* Stacks keep the list's organization: a stack per type (decks) or color (cubes). */}
              {layout === "stacks" && !editing ? (
                <StackRows c={catalog} boxWidth={width} stacks={groupsOf(inBoard, grouping).map((g): StackItem => {
                  const inGroup = inBoard.filter((x) => x.group === g);
                  return {
                    key: `${grouping}|${g}|${printings.all}`,
                    title: `${groupLabel(grouping, g)} · ${inGroup.reduce((n, x) => n + x.qty, 0)}`,
                    cards: tiles(inGroup),
                  };
                })} />
              ) : (
                // Rows (not the grid): on a desktop the groups flow into columns, as on a deck site.
                <div className={layout === "grid" && !editing ? "flex flex-col gap-px" : "flex flex-col gap-px lg:block lg:columns-[340px] lg:gap-x-px"}>
                {groupsOf(inBoard, grouping).map((g) => {
                const inGroup = inBoard.filter((x) => x.group === g);
                return (
                  <div key={g} className="flex flex-col gap-px lg:break-inside-avoid lg:mb-px">
                    <Section title={groupLabel(grouping, g)} count={inGroup.reduce((n, x) => n + x.qty, 0)} />
                    {layout === "grid" && !editing ? (
                      <div className="grid gap-px" style={{ gridTemplateColumns: `repeat(${cols}, ${tile}px)` }}>
                        {tiles(inGroup).map((t) => (
                          <CardTile key={t.key} c={catalog} p={t.p} name={t.name} qty={t.qty} width={tile} warn={t.warn}
                                    finish={t.finish} hero={t.hero} onClick={t.onClick} />
                        ))}
                      </div>
                    ) : editing ? inGroup.map((x) => lineRow(x)) : lineGroups(inGroup).map(groupRows)}
                  </div>
                );
                })}
                </div>
              )}
            </div>
          );
        })}
      </div>
      {moving && (
        <Modal title={moving.name} onClose={() => setMoving(null)}>
          <div className="flex flex-col gap-px">
            {sectionsFor(list.kind).filter((b) => b !== moving.board).map((b) => (
              <Row key={b} title={`Move to ${boardTitle(list.kind, b)}`}
                   onClick={() => { void editList(list.id, [{ card_id: moving.cardId, finish: moving.finish, from: moving.board, to: b }]); setMoving(null); }} />
            ))}
            <Row title="Change printing or finish" detail="Or split copies between finishes"
                 onClick={() => { const m = moving; setMoving(null); onPrinting(m.cardId, m.board, m.finish); }} />
            {moving.oracleId && (() => {
              const on = isHero(moving.oracleId, heroScope, heroes);
              return (
                <Row title={on ? "Not a hero card" : "Make it a hero card"}
                     detail={on ? "Stop highlighting it" : `Highlighted here and in your ${list.kind === "deck" ? "decks" : "cubes"}`}
                     onClick={() => {
                       if (!toggleHero(moving.oracleId!, heroScope)) setHeroFull(`${list.name} has ${HERO_LIMIT} hero cards already.`);
                       setMoving(null);
                     }} />
              );
            })()}
            <Row title={`Remove from ${boardTitle(list.kind, moving.board)}`}
                 onClick={() => { void editList(list.id, [{ card_id: moving.cardId, board: moving.board, finish: moving.finish, qty: 0 }]); setMoving(null); }} />
          </div>
        </Modal>
      )}
      {exporting && catalog && <ExportScreen name={list.name} kind={list.kind} entries={entriesOf(list)} catalog={catalog} from="own" onClose={() => setExporting(false)} />}
      {adding && catalog && <ListToCollectionScreen list={list} catalog={catalog} owned={owned} onClose={() => setAdding(false)} />}
      {imaging && catalog && <DeckImageScreen name={list.name} format={list.format} entries={entriesOf(list)} catalog={catalog} owner={null} from="own" onClose={() => setImaging(false)} />}
      {confirmDelete && (
        <Modal title={`Delete ${list.name}?`} onClose={() => setConfirmDelete(false)}>
          <p className="text-[12px] text-t1-muted">It goes from every device. This can't be undone.</p>
          <BigAction label="Delete" onClick={() => { void deleteList(list.id).then(onBack); }} />
        </Modal>
      )}
    </LibScreen>
  );
}

/* ── adding cards to a list ───────────────────────────────────────────── */

/**
 * Add, remove or replace, like Cube Cobra's edit panel (contract/library-polish-2026-10-19.md): an Add box (the catalog or
 * Scryfall syntax) and a Remove or replace box (only the list's own cards) on one screen. Pick a card in either box; with
 * only Remove picked the button removes one copy, with both picked it replaces that copy with the added card in the same
 * section, as one edit (so the history shows a swap). Each card goes in as its original paper printing unless a search
 * named another; change it from the card page.
 */
export function ListAddScreen({ id, onDone }: { id: string; onDone: () => void; onCard?: (oracleId: string) => void }) {
  const { lists } = useListsData();
  const { catalog } = useCatalog();
  const [addQuery, setAddQuery] = useState("");
  const [removeQuery, setRemoveQuery] = useState("");
  const [board, setBoard] = useState<Board>("main");
  const [addPick, setAddPick] = useState<{ oi: number; p: number } | null>(null);
  const [removePick, setRemovePick] = useState<Line | null>(null);
  /** Which box was typed in last: the list below follows it. */
  const [focus, setFocus] = useState<"add" | "remove">("add");
  const [note, setNote] = useState<string | null>(null);
  const addInput = useRef<HTMLInputElement>(null);
  const removeInput = useRef<HTMLInputElement>(null);
  const list = lists.lists.find((l) => l.id === id);
  const found = useCardSearch(catalog, addPick ? "" : addQuery);
  const lines = useMemo(() => (list && catalog ? linesOf(list, catalog) : []), [list, catalog]);
  if (!list) return <Screen><Bar title="Add cards" onBack={onDone} /></Screen>;
  const showingRemove = !removePick && focus === "remove";
  const removeHits = matchingLines(lines, removeQuery);
  const finishFor = (p: number): ListFinish => (["nonfoil", "foil", "etched"] as ListFinish[]).find((f) => catalog?.pFinishes[p]?.includes(f[0])) ?? "nonfoil";
  const title = (b: Board) => boardTitle(list.kind, b);

  const reset = () => {
    setAddPick(null);
    setRemovePick(null);
    setAddQuery("");
    setRemoveQuery("");
    setFocus("add");
    addInput.current?.focus();
  };
  const pickAdd = (oi: number, p: number) => {
    setAddPick({ oi, p });
    setAddQuery(catalog!.oName[oi]);
  };
  const pickRemove = (x: Line) => {
    setRemovePick(x);
    setRemoveQuery(x.name);
    setFocus("add");
  };
  const add = () => {
    if (!addPick || !catalog) return;
    void editList(list.id, [{ card_id: catalog.pId[addPick.p], board, finish: finishFor(addPick.p), delta: 1 }]);
    capture("list_card_added", { kind: list.kind, from: "edit" });
    setNote(`Added 1 ${catalog.oName[addPick.oi]} to ${title(board)}`);
    reset();
  };
  const removeOrReplace = () => {
    if (!removePick || !catalog) return;
    const r = removePick;
    if (addPick) {
      void editList(list.id, [{ card_id: r.cardId, board: r.board, finish: r.finish, to_card_id: catalog.pId[addPick.p],
                                to_finish: finishFor(addPick.p), qty: 1, swap: true }]);
      capture("list_card_replaced", { kind: list.kind });
      setNote(`Replaced ${r.name} with ${catalog.oName[addPick.oi]} in ${title(r.board)}`);
    } else {
      void editList(list.id, [{ card_id: r.cardId, board: r.board, finish: r.finish, delta: -1 }]);
      capture("list_card_removed", { kind: list.kind });
      setNote(`Removed 1 ${r.name} from ${title(r.board)}`);
    }
    reset();
  };
  const action = (label: string, enabled: boolean, run: () => void) => (
    <button type="button" disabled={!enabled} onClick={run}
            className={`flex-1 py-4 text-[13px] font-bold uppercase tracking-[3px] text-t1-ink ${enabled ? "bg-t1-text" : "bg-t1-disabled"}`}>
      {label}
    </button>
  );
  /** A picked card in place of its box, with Clear. */
  const picked = (p: number | null, name: string, detail: string, clear: () => void, finish?: ListFinish) => (
    <div className="shrink-0 h-[60px] flex items-stretch gap-px">
      <div className="flex-1 min-w-0"><CardRow c={catalog!} p={p} title={name} detail={detail} finish={finish} /></div>
      <button type="button" onClick={clear} className="bg-t1-surface hover:bg-t1-surface-hover px-4 t1-label !text-t1-text">Clear</button>
    </div>
  );
  const hits = addQuery.trim() && !addPick ? found?.result.hits ?? [] : [];

  return (
    <LibScreen>
      <Bar title={`Edit ${list.name}`} subtitle={`v${current(list).number}`}
           right={<button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={onDone}>Done</button>} />
      {note && <Notice tone="info">{note}</Notice>}
      <Section title="Add to" />
      <Segmented options={sectionsFor(list.kind).map((b) => ({ value: b, label: title(b) }))} value={board} onChange={setBoard} />
      {addPick && catalog
        ? picked(addPick.p, catalog.oName[addPick.oi], title(removePick?.board ?? board), () => { setAddPick(null); setAddQuery(""); setFocus("add"); setTimeout(() => addInput.current?.focus()); })
        : <CardSearchBar label="Card to add" value={addQuery} onChange={(v) => { setAddQuery(v); setFocus("add"); }} placeholder="Name, or Scryfall syntax"
                         autoFocus inputRef={addInput} onFocus={() => setFocus("add")}
                         onSubmit={() => { const oi = hits[0]; if (oi != null && found) pickAdd(oi, found.result.covers.get(oi) ?? coverPrinting(catalog!, oi)); }} />}
      <Section title="Remove or replace" />
      {removePick
        ? picked(removePick.p, removePick.name, [title(removePick.board), removePick.finish === "nonfoil" ? null : FINISH_NAME[removePick.finish]].filter(Boolean).join(" · "),
                 () => { setRemovePick(null); setRemoveQuery(""); setFocus("remove"); setTimeout(() => removeInput.current?.focus()); }, removePick.finish)
        : (
          <label className="shrink-0 bg-t1-surface px-4 py-3 flex flex-col gap-1">
            <span className="t1-label">{list.kind === "cube" ? "Card in this cube" : "Card in this deck"}</span>
            <input type="search" ref={removeInput} value={removeQuery} onFocus={() => setFocus("remove")}
                   onChange={(e) => { setRemoveQuery(e.target.value); setFocus("remove"); }}
                   onKeyDown={(e) => { if (e.key === "Enter" && removeHits[0]) { e.preventDefault(); pickRemove(removeHits[0]); } }}
                   className="bg-transparent border-0 outline-0 text-[15px] text-t1-text w-full" />
          </label>
        )}
      <div className="shrink-0 flex gap-px">
        {action("Add", !!addPick, add)}
        {action(addPick && removePick ? "Replace" : "Remove", !!removePick, removeOrReplace)}
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!catalog && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
        {catalog && showingRemove && (<>
          {!removeQuery.trim()
            ? <Notice tone="info">Search the cards in {list.name}. Remove takes one copy out; with a card picked to add, Replace swaps it in the same section.</Notice>
            : !removeHits.length && <Row title={`No card in ${list.name} matches`} />}
          {removeHits.map((x) => (
            <div key={lineKey(x)} className="h-[60px] shrink-0">
              <CardRow c={catalog} p={x.p} title={x.name} finish={x.finish} onClick={() => pickRemove(x)}
                       detail={[title(x.board), x.finish === "nonfoil" ? null : FINISH_NAME[x.finish], x.qty > 1 ? `${x.qty} copies` : null].filter(Boolean).join(" · ")} />
            </div>
          ))}
        </>)}
        {catalog && !showingRemove && !addPick && (<>
          <CardSearchStatus query={addQuery} found={found} />
          {!addQuery && !removeQuery && (
            <Notice tone="info">Pick a card to add, a card to remove, or both: with both, Replace swaps them in the same section. + adds a card at once.</Notice>
          )}
          {hits.map((oi) => {
            const p = found?.result.covers.get(oi) ?? coverPrinting(catalog, oi);
            const inList = entriesOf(list).filter((e) => e.cardId === catalog.pId[p] && e.board === board).reduce((n, e) => n + e.qty, 0);
            return (
              <div key={oi} className="flex items-stretch gap-px h-[60px] shrink-0">
                <div className="flex-1 min-w-0">
                  <CardRow c={catalog} p={p} title={catalog.oName[oi]} onClick={() => pickAdd(oi, p)}
                           detail={inList ? `${inList} in ${title(board)}` : catalog.oType[oi]} />
                </div>
                <button type="button" aria-label={`Add ${catalog.oName[oi]}`} className="w-[52px] bg-t1-surface-hover text-[22px] hover:text-t1-accent"
                        onClick={() => {
                          void editList(list.id, [{ card_id: catalog.pId[p], board, finish: finishFor(p), delta: 1 }]);
                          capture("list_card_added", { kind: list.kind, from: "quick" });
                          setNote(`Added 1 ${catalog.oName[oi]} to ${title(board)}`);
                        }}>+</button>
              </div>
            );
          })}
        </>)}
      </div>
    </LibScreen>
  );
}

/* ── version history ──────────────────────────────────────────────────── */

export function VersionsScreen({ id, onBack, onOpen }: { id: string; onBack: () => void; onOpen: (n: number) => void }) {
  const { lists } = useListsData();
  const list = lists.lists.find((l) => l.id === id);
  if (!list) return <Screen><Bar title="Version history" onBack={onBack} /></Screen>;
  const vs = list.versions;
  return (
    <LibScreen>
      <Bar title="Version history" subtitle={list.name} onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {vs.map((v, i) => {
          const ch = diff(i > 0 ? vs[i - 1] : null, v);
          const added = ch.filter((c) => c.delta > 0).reduce((n, c) => n + c.delta, 0);
          const removed = -ch.filter((c) => c.delta < 0).reduce((n, c) => n + c.delta, 0);
          const detail = [fmtDate(v.at), i === 0 ? "first version" : `+${added} −${removed}`, i === vs.length - 1 ? "current" : null].filter(Boolean).join(" · ");
          return <Row key={v.number} title={`v${v.number} · ${v.note}`} detail={detail} onClick={() => onOpen(v.number)} />;
        }).reverse()}
      </div>
    </LibScreen>
  );
}

export function VersionScreen({ id, number, onBack, onCard }: { id: string; number: number; onBack: () => void; onCard: (oracleId: string) => void }) {
  const { lists } = useListsData();
  const { catalog } = useCatalog();
  const [restored, setRestored] = useState<string | null>(null);
  const list = lists.lists.find((l) => l.id === id);
  const i = list ? list.versions.findIndex((v) => v.number === number) : -1;
  if (!list || i < 0) return <Screen><Bar title={`v${number}`} onBack={onBack} /></Screen>;
  const v = list.versions[i];
  const prev = i > 0 ? list.versions[i - 1] : null;
  const changes = prev ? diff(prev, v) : [];
  const count = (b: Board) => v.entries.filter((e) => e.board === b).reduce((n, e) => n + e.qty, 0);
  return (
    <LibScreen>
      <Bar title={`v${number} · ${v.note}`} subtitle={list.name} onBack={onBack} />
      {restored && <Notice tone="info">{restored}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface py-4 flex">
          <Stat label={list.kind === "deck" ? "Main" : "Cards"} value={count("main")} />
          {list.kind === "deck" && <Stat label="Side" value={count("side")} />}
          <Stat label="Considering" value={count("maybe")} />
        </div>
        <Row title={new Date(v.at * 1000).toLocaleDateString(undefined, { month: "long", day: "numeric", year: "numeric" })}
             detail={prev ? `Changes from v${prev.number}` : "First version"} />
        {prev && changes.length === 0 && <Row title="No card changes" />}
        {catalog && (["commander", "main", "side", "maybe"] as Board[]).filter((b) => changes.some((c) => c.board === b)).map((b) => (
          <div key={b} className="flex flex-col gap-px">
            <Section title={boardTitle(list.kind, b)} />
            {changes.filter((c) => c.board === b).map((c) => {
              const p = catalog.printingIndex.get(c.cardId) ?? null;
              const oi = p == null ? -1 : catalog.pOracle[p];
              return (
                <div key={`${c.board}|${c.cardId}|${c.finish}`} className="h-[60px]">
                  <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Unknown card"}
                           detail={[c.delta > 0 ? "Added" : "Removed", c.finish === "nonfoil" ? null : FINISH_NAME[c.finish]].filter(Boolean).join(" · ")}
                           value={c.delta > 0 ? `+${c.delta}` : `−${-c.delta}`} warn={c.delta < 0}
                           onClick={() => oi >= 0 && onCard(catalog.oId[oi])} />
                </div>
              );
            })}
          </div>
        ))}
        {i !== list.versions.length - 1 && (
          <BigAction label={`Restore v${number}`} onClick={() => {
            void restoreList(list.id, number).then(() => setRestored(`Restored as a new version. Every earlier version is still here.`));
          }} />
        )}
      </div>
    </LibScreen>
  );
}
