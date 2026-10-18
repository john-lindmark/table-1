import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Field, Modal, Notice, Row, Screen, Section, Segmented } from "../components/kit";
import { CANLANDER_POINT_LIMIT, RARITY_NAME, coverPrinting, formatName, legalityOf, searchCatalog, type Catalog } from "../lib/catalog";
import { DEMO_USER, useCollection } from "../lib/collection";
import { loadDemoLists } from "../lib/libraryDemo";
import {
  EXPORT_DETAIL, EXPORT_FILE, EXPORT_LABEL, exportFileName, exportFormats, exportLines, renderList, type ExportFormat,
} from "../lib/listExport";
import {
  boardTitle, boardsOf, countOf, createList, finishOf, ownKey, type ListFinish, current, deleteList, diff, duplicateList, editList, entriesOf, missingIn, restoreList,
  sectionsFor, useLists, type Board, type CardList, type ListKind,
} from "../lib/lists";
import { capture } from "../lib/telemetry";
import {
  CardArt, CardRow, CardTile, LibScreen, StackRows, ViewButton, useCatalog, useLibrarySession, useStoredLayout, type StackItem,
} from "./Library";

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

/* ── grouping (same rules as iOS) ─────────────────────────────────────── */

const TYPE_ORDER = ["Creatures", "Planeswalkers", "Instants", "Sorceries", "Artifacts", "Enchantments", "Battles", "Lands", "Other"];
const COLOR_ORDER = ["White", "Blue", "Black", "Red", "Green", "Multicolor", "Colorless", "Lands"];

function typeGroup(t: string): string {
  if (t.includes("Creature")) return "Creatures";
  if (t.includes("Planeswalker")) return "Planeswalkers";
  if (t.includes("Land")) return "Lands";
  if (t.includes("Instant")) return "Instants";
  if (t.includes("Sorcery")) return "Sorceries";
  if (t.includes("Artifact")) return "Artifacts";
  if (t.includes("Enchantment")) return "Enchantments";
  if (t.includes("Battle")) return "Battles";
  return "Other";
}

function colorGroup(cost: string): string {
  const colors = (["W", "U", "B", "R", "G"] as const).filter((c) => cost.includes(c));
  if (colors.length > 1) return "Multicolor";
  return ({ W: "White", U: "Blue", B: "Black", R: "Red", G: "Green" } as const)[colors[0]] ?? "Colorless";
}

interface Line {
  cardId: string;
  p: number | null;
  oracleId: string | null;
  name: string;
  group: string;
  board: Board;
  qty: number;
  oi: number;
  finish: ListFinish;
  points: number;
  basic: boolean;
}

const FINISH_NAME: Record<ListFinish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };
const lineKey = (x: Line) => `${x.board}|${x.cardId}|${x.finish}`;

function linesOf(l: CardList, c: Catalog): Line[] {
  return entriesOf(l).map((e) => {
    const p = c.printingIndex.get(e.cardId) ?? null;
    const oi = p == null ? -1 : c.pOracle[p];
    const type = oi >= 0 ? c.oType[oi].split(" // ")[0] : "";
    const group = l.kind === "deck" ? typeGroup(type) : type.includes("Land") ? "Lands" : colorGroup(oi >= 0 ? c.oCost[oi] : "");
    return { cardId: e.cardId, p, oracleId: oi >= 0 ? c.oId[oi] : null, name: oi >= 0 ? c.oName[oi] : "Unknown card", group, board: e.board, qty: e.qty, oi, finish: finishOf(e),
             points: oi >= 0 ? c.oPoints[oi] : 0, basic: type.includes("Basic") };
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

function groupsOf(lines: Line[], kind: ListKind): string[] {
  const order = kind === "deck" ? TYPE_ORDER : COLOR_ORDER;
  return [...new Set(lines.map((x) => x.group))].sort((a, b) => order.indexOf(a) - order.indexOf(b));
}

function BoardHeader({ title, count }: { title: string; count: number }) {
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

export function ListsScreen({ kind, onBack, onOpen, onFind, onImport }: {
  kind: ListKind; onBack: () => void; onOpen: (id: string) => void; onFind: () => void; onImport: () => void;
}) {
  const { session, ready, lists, owned } = useListsData();
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [format, setFormat] = useState(kind === "deck" ? "modern" : "vintage");
  const [busy, setBusy] = useState(false);
  const mine = lists.lists.filter((l) => l.kind === kind);
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
        {mine.map((l) => {
          const miss = missingIn(l, owned);
          const side = countOf(l, "side"), maybe = countOf(l, "maybe");
          const detail = [formatName(l.format), side ? `${side} sideboard` : null, maybe ? `${maybe} considering` : null,
                          l.eventId ? `From ${l.eventName ?? "an event"}` : miss ? `${miss} missing` : "All owned", `v${current(l).number}`].filter(Boolean).join(" · ");
          return <Row key={l.id} title={l.name} detail={detail} value={countOf(l, "main")} onClick={() => onOpen(l.id)} />;
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

/** The current version in another app's format (contract/lists-2026-10-15.md, Export): copied for the formats other
 *  apps paste in, downloaded for MTGO and Cube Cobra. Same formats and output as iOS and Android. */
function ExportModal({ list, catalog, onClose }: { list: CardList; catalog: Catalog; onClose: () => void }) {
  const [note, setNote] = useState<string | null>(null);
  const download = (text: string, name: string) => {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([text], { type: name.endsWith(".csv") ? "text/csv;charset=utf-8" : "text/plain;charset=utf-8" }));
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
  };
  const run = async (format: ExportFormat) => {
    const { lines, left } = exportLines(catalog, entriesOf(list));
    const text = renderList(lines, list.kind, format);
    const name = exportFileName(list.name, list.kind, format);
    let done: string;
    if (EXPORT_FILE[format]) {
      download(text, name);
      done = `Downloaded ${name}.`;
    } else {
      try {
        await navigator.clipboard.writeText(text);
        done = format === "text" ? "Copied." : `Copied. Paste it into ${EXPORT_LABEL[format]}'s Import.`;
      } catch {
        download(text, name);
        done = `Downloaded ${name}.`;
      }
    }
    if (left) done += ` ${left} card${left === 1 ? "" : "s"} newer than the card data ${left === 1 ? "was" : "were"} left out.`;
    setNote(done);
    capture("list_exported", { kind: list.kind, format, cards: lines.reduce((n, l) => n + l.qty, 0), left });
  };
  return (
    <Modal title={`Export ${list.name}`} onClose={onClose}>
      <p className="text-[12px] text-t1-muted">The current version, v{current(list).number}.</p>
      <div className="flex flex-col gap-px">
        {exportFormats(list.kind).map((f) => (
          <div key={f} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
            <span className="flex-1 min-w-0 flex flex-col gap-0.5">
              <span className="text-[13px]">{EXPORT_LABEL[f]}</span>
              <span className="t1-label">{EXPORT_DETAIL[f]}</span>
            </span>
            <button type="button" className="shrink-0 t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => void run(f)}>
              {EXPORT_FILE[f] ? "Download" : "Copy"}
            </button>
          </div>
        ))}
      </div>
      {note && <Notice tone="info">{note}</Notice>}
    </Modal>
  );
}

export function ListScreen({ id, onBack, onCard, onAdd, onVersions, onOpen, onPrinting }: {
  id: string; onBack: () => void; onCard: (oracleId: string) => void; onAdd: () => void; onVersions: () => void;
  onOpen: (listId: string) => void; onPrinting: (cardId: string, board: Board, finish: ListFinish) => void;
}) {
  const { session, ready, lists, owned } = useListsData();
  const { catalog, error } = useCatalog();
  const [layout, setLayout] = useStoredLayout("table1.library.list.layout", "table1.library.list.grid");
  const [editing, setEditing] = useState(false);
  const [moving, setMoving] = useState<Line | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [exporting, setExporting] = useState(false);
  const list = lists.lists.find((l) => l.id === id) ?? null;
  const lines = useMemo(() => (list && catalog ? linesOf(list, catalog) : []), [list, catalog]);
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
  const cols = Math.max(3, Math.floor(width / 180));
  const tile = Math.floor((width - (cols - 1)) / cols);
  const v = current(list);

  const lineRow = (x: Line) => {
    const have = owned.get(ownKey(x.cardId, x.finish)) ?? 0;
    const fin = x.finish === "nonfoil" ? null : FINISH_NAME[x.finish];
    const pts = x.points > 0 && list.format === "canlander" ? `${x.points} pt${x.points === 1 ? "" : "s"}` : null;
    const considering = x.board === "maybe";
    const short = !considering && !list.eventId && have < x.qty;
    const issue = issues.get(x.oracleId ?? x.cardId);
    if (editing) {
      return (
        <div key={lineKey(x)} className="flex items-stretch gap-px h-[60px]">
          <div className="flex-1 min-w-0">
            <CardRow c={catalog!} p={x.p} title={x.name} detail={[fin, "Tap to move, change or remove"].filter(Boolean).join(" · ")}
                     value={x.qty} onClick={() => setMoving(x)} />
          </div>
          <button type="button" aria-label="Remove one" className="w-14 bg-t1-surface-hover text-[20px]"
                  onClick={() => editList(list.id, [{ card_id: x.cardId, board: x.board, finish: x.finish, delta: -1 }])}>−</button>
          <button type="button" aria-label="Add one" className="w-14 bg-t1-surface-hover text-[20px]"
                  onClick={() => editList(list.id, [{ card_id: x.cardId, board: x.board, finish: x.finish, delta: 1 }])}>+</button>
        </div>
      );
    }
    return (
      <div key={lineKey(x)} className="h-[60px]">
        <CardRow c={catalog!} p={x.p} title={x.name} value={x.qty} warn={short || !!issue}
                 detail={(issue ? `${issue} · ` : "") + (pts ? `${pts} · ` : "") + (fin ? `${fin} · ` : "") + (considering ? (have ? `Owned ${have}` : "Not owned") : short ? `Owned ${have} · missing ${x.qty - have}` : `Owned ${have}`)}
                 onClick={() => x.oracleId && onCard(x.oracleId)} />
      </div>
    );
  };

  return (
    <LibScreen>
      <Bar title={list.name} subtitle={list.eventId ? `From ${list.eventName ?? "an event"} · v${v.number}` : `${formatName(list.format)} ${list.kind} · v${v.number}`} onBack={onBack}
           right={<span className="flex gap-4">
             <button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => setEditing(!editing)}>{editing ? "Done" : "Edit"}</button>
             {!editing && <ViewButton layout={layout} onChange={setLayout} screen={list.kind === "cube" ? "cube" : "deck"} />}
           </span>} />
      {(lists.error || error) && <Notice tone="error">{lists.error ?? error}</Notice>}
      <div ref={boxRef} className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface py-4 flex">
          <Stat label={list.kind === "deck" ? "Main" : "Cards"} value={countOf(list, "main")} />
          {list.kind === "deck" && <Stat label="Side" value={countOf(list, "side")} />}
          {list.kind === "deck" && list.format === "canlander" && <Stat label="Points" value={pointsOf(lines).total} />}
          <Stat label="Considering" value={countOf(list, "maybe")} />
          <Stat label="Missing" value={missingIn(list, owned)} />
        </div>
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
        {editing && <Row title={list.kind === "deck" ? "Duplicate deck" : "Duplicate cube"} detail="A new list with these cards"
                         onClick={() => { void duplicateList(list).then((copy) => { setEditing(false); onOpen(copy); }); }} />}
        {editing && <Row title={list.kind === "deck" ? "Delete deck" : "Delete cube"} detail="From every device" onClick={() => setConfirmDelete(true)} />}
        <Row title="Add cards" detail={list.kind === "deck" ? "To the main deck, sideboard or considering" : "To the cube or considering"} onClick={onAdd} />
        <Row title="Version history" detail={`v${v.number} · ${v.note} · ${fmtDate(v.at)}`} value={list.versions.length} onClick={onVersions} />
        {entriesOf(list).length > 0 && !editing && catalog &&
          <Row title="Export" detail={list.kind === "deck" ? "For Arena, Moxfield, MTGO or as plain text" : "For Cube Cobra or as plain text"}
               onClick={() => setExporting(true)} />}
        {entriesOf(list).length === 0 && <Row title="No cards yet" detail="Add cards to start this list" />}
        {!catalog && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
        {catalog && boardsOf(list).map((board) => {
          const inBoard = lines.filter((x) => x.board === board);
          return (
            <div key={board} className="flex flex-col gap-px">
              <BoardHeader title={boardTitle(list.kind, board)} count={inBoard.reduce((n, x) => n + x.qty, 0)} />
              {/* Stacks keep the list's organization: a stack per type (decks) or color (cubes). */}
              {layout === "stacks" && !editing ? (
                <StackRows c={catalog} boxWidth={width} stacks={groupsOf(inBoard, list.kind).map((g): StackItem => {
                  const inGroup = inBoard.filter((x) => x.group === g);
                  return {
                    key: g,
                    title: `${g} · ${inGroup.reduce((n, x) => n + x.qty, 0)}`,
                    cards: inGroup.map((x) => ({
                      key: lineKey(x), p: x.p, name: x.name, qty: x.qty,
                      warn: (board !== "maybe" && (owned.get(ownKey(x.cardId, x.finish)) ?? 0) < x.qty) || issues.has(x.oracleId ?? x.cardId),
                      onClick: () => x.oracleId && onCard(x.oracleId),
                    })),
                  };
                })} />
              ) : groupsOf(inBoard, list.kind).map((g) => {
                const inGroup = inBoard.filter((x) => x.group === g);
                return (
                  <div key={g} className="flex flex-col gap-px">
                    <Section title={g} count={inGroup.reduce((n, x) => n + x.qty, 0)} />
                    {layout === "grid" && !editing ? (
                      <div className="grid gap-px" style={{ gridTemplateColumns: `repeat(${cols}, ${tile}px)` }}>
                        {inGroup.map((x) => (
                          <CardTile key={lineKey(x)} c={catalog} p={x.p} name={x.name} qty={x.qty} width={tile}
                                    warn={(board !== "maybe" && (owned.get(ownKey(x.cardId, x.finish)) ?? 0) < x.qty) || issues.has(x.oracleId ?? x.cardId)}
                                    onClick={() => x.oracleId && onCard(x.oracleId)} />
                        ))}
                      </div>
                    ) : inGroup.map(lineRow)}
                  </div>
                );
              })}
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
            <Row title={`Remove from ${boardTitle(list.kind, moving.board)}`}
                 onClick={() => { void editList(list.id, [{ card_id: moving.cardId, board: moving.board, finish: moving.finish, qty: 0 }]); setMoving(null); }} />
          </div>
        </Modal>
      )}
      {exporting && catalog && <ExportModal list={list} catalog={catalog} onClose={() => setExporting(false)} />}
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

export function ListAddScreen({ id, onDone, onCard }: { id: string; onDone: () => void; onCard: (oracleId: string) => void }) {
  const { lists } = useListsData();
  const { catalog } = useCatalog();
  const [q, setQ] = useState("");
  const [board, setBoard] = useState<Board>("main");
  const list = lists.lists.find((l) => l.id === id);
  const hits = useMemo(() => (catalog ? searchCatalog(catalog, q, 40) : []), [catalog, q]);
  if (!list) return <Screen><Bar title="Add cards" onBack={onDone} /></Screen>;
  return (
    <LibScreen>
      <Bar title={`Add to ${list.name}`} subtitle={`v${current(list).number}`} onBack={onDone} />
      <Segmented options={sectionsFor(list.kind).map((b) => ({ value: b, label: boardTitle(list.kind, b) }))} value={board} onChange={setBoard} />
      <Field label="Card name" value={q} onChange={setQ} autoFocus />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {catalog && hits.map((oi) => {
          const p = coverPrinting(catalog, oi);
          const inList = entriesOf(list).filter((e) => e.cardId === catalog.pId[p] && e.board === board).reduce((n, e) => n + e.qty, 0);
          return (
            <div key={oi} className="flex items-stretch gap-px h-[60px]">
              <div className="flex-1 min-w-0">
                <CardRow c={catalog} p={p} title={catalog.oName[oi]}
                         detail={inList ? `${inList} in ${boardTitle(list.kind, board)}` : catalog.oType[oi]}
                         onClick={() => onCard(catalog.oId[oi])} />
              </div>
              <button type="button" className="px-4 bg-t1-surface-hover t1-label hover:text-t1-text"
                      onClick={() => editList(list.id, [{ card_id: catalog.pId[p], board, delta: 1 }])}>+ Add</button>
            </div>
          );
        })}
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

/* ── a line's printing and finish ─────────────────────────────────────── */

/**
 * Moves some or all copies of one line to another printing or finish. Splitting 4 non-foil into 2 non-foil
 * and 2 foil is "move 2" to the foil finish of the same printing.
 */
export function LinePrintingScreen({ id, cardId, board, finish, onDone }: {
  id: string; cardId: string; board: Board; finish: ListFinish; onDone: () => void;
}) {
  const { lists } = useListsData();
  const { catalog } = useCatalog();
  const list = lists.lists.find((l) => l.id === id);
  const have = list ? entriesOf(list).find((e) => e.cardId === cardId && e.board === board && finishOf(e) === finish)?.qty ?? 0 : 0;
  const [count, setCount] = useState(0);
  const n = Math.min(Math.max(count || have, 1), have);
  if (!list || !catalog) return <LibScreen><Bar title="Printing" onBack={onDone} /></LibScreen>;
  const p0 = catalog.printingIndex.get(cardId);
  const oi = p0 === undefined ? -1 : catalog.pOracle[p0];
  const orig = oi >= 0 ? catalog.oOriginal[oi] : -1;
  const printings = oi < 0 ? [] : Array.from({ length: catalog.pCount[oi] }, (_, i) => catalog.pFirst[oi] + i)
    .sort((a, b) => Number(b === orig) - Number(a === orig));
  const label = (p: number) => `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`;
  return (
    <LibScreen>
      <Bar title="Printing" subtitle={oi >= 0 ? catalog.oName[oi] : undefined} onBack={onDone} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {have === 0 && <Notice tone="info">This line has no copies left.</Notice>}
        {have > 0 && p0 !== undefined && (
          <>
            <div className="h-[60px]">
              <CardRow c={catalog} p={p0} title={catalog.oName[oi]} value={have}
                       detail={[label(p0), FINISH_NAME[finish], boardTitle(list.kind, board)].join(" · ")} />
            </div>
            <div className="bg-t1-surface flex items-stretch gap-px h-[52px]">
              <span className="flex-1 px-4 flex items-center t1-label">Change {n} of {have}</span>
              <button type="button" aria-label="Fewer" className="w-14 bg-t1-surface-hover text-[20px]" onClick={() => setCount(Math.max(1, n - 1))}>−</button>
              <button type="button" aria-label="More" className="w-14 bg-t1-surface-hover text-[20px]" onClick={() => setCount(Math.min(have, n + 1))}>+</button>
            </div>
            <Section title="Move them to" />
            {printings.map((p) => {
              const finishes = (["nonfoil", "foil", "etched"] as ListFinish[]).filter((f) => catalog.pFinishes[p].includes(f[0]));
              return (
                <div key={p} className="bg-t1-surface flex items-stretch gap-px">
                  <div className="flex-1 min-w-0 px-4 py-[5px] flex items-center gap-3">
                    <CardArt c={catalog} p={p} width={36} />
                    <span className="min-w-0 flex flex-col gap-0.5">
                      <span className="text-[13px] truncate">{label(p)}</span>
                      <span className="t1-label truncate">
                        {[RARITY_NAME[catalog.pRarity[p]], catalog.pReleased[p]?.slice(0, 4), p === orig ? "Original" : null,
                          catalog.pLang[p] !== "en" ? catalog.pLang[p].toUpperCase() : null].filter(Boolean).join(" · ")}
                      </span>
                    </span>
                  </div>
                  {finishes.map((f) => {
                    const same = catalog.pId[p] === cardId && f === finish;
                    return (
                      <button key={f} type="button" disabled={same}
                              className="px-3 bg-t1-surface-hover t1-label hover:text-t1-text disabled:text-t1-disabled"
                              onClick={() => {
                                void editList(id, [{ card_id: cardId, board, finish, to_card_id: catalog.pId[p], to_finish: f, qty: n, swap: true }]);
                                onDone();
                              }}>{same ? "Current" : FINISH_NAME[f]}</button>
                    );
                  })}
                </div>
              );
            })}
          </>
        )}
      </div>
    </LibScreen>
  );
}
