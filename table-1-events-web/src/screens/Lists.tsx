import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Field, Modal, Notice, Row, Screen, Section, Segmented } from "../components/kit";
import { coverPrinting, searchCatalog, type Catalog } from "../lib/catalog";
import { DEMO_USER, useCollection } from "../lib/collection";
import { loadDemoLists } from "../lib/libraryDemo";
import {
  boardTitle, boardsOf, countOf, createList, current, deleteList, diff, editList, entriesOf, missingIn, restoreList,
  sectionsFor, useLists, type Board, type CardList, type ListKind,
} from "../lib/lists";
import { Back, BarToggle, CardRow, CardTile, LibScreen, useCatalog, useLibrarySession, useStoredFlag } from "./Library";

/* Decks and cubes on the web (contract/lists-2026-10-15.md): the same lists, sections, groups and version
   history as iOS, read from and written to the database, so a deck built on one device is here too. */

function useListsData() {
  const { session, ready, userId } = useLibrarySession();
  const lists = useLists(userId, userId === DEMO_USER ? loadDemoLists : undefined);
  const col = useCollection(userId);
  const owned = useMemo(() => {
    const m = new Map<string, number>();
    for (const it of col.items.values()) m.set(it.cardId, (m.get(it.cardId) ?? 0) + it.qty);
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
}

function linesOf(l: CardList, c: Catalog): Line[] {
  return entriesOf(l).map((e) => {
    const p = c.printingIndex.get(e.cardId) ?? null;
    const oi = p == null ? -1 : c.pOracle[p];
    const type = oi >= 0 ? c.oType[oi].split(" // ")[0] : "";
    const group = l.kind === "deck" ? typeGroup(type) : type.includes("Land") ? "Lands" : colorGroup(oi >= 0 ? c.oCost[oi] : "");
    return { cardId: e.cardId, p, oracleId: oi >= 0 ? c.oId[oi] : null, name: oi >= 0 ? c.oName[oi] : "Unknown card", group, board: e.board, qty: e.qty };
  }).sort((a, b) => a.name.localeCompare(b.name));
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

const DECK_FORMATS = ["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "other"];
const CUBE_FORMATS = ["vintage", "legacy", "pauper", "peasant", "other"];

export function ListsScreen({ kind, onBack, onOpen }: { kind: ListKind; onBack: () => void; onOpen: (id: string) => void }) {
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
      <Bar title={kind === "deck" ? "Decks" : "Cubes"} subtitle={`${mine.length}`} right={<Back onClick={onBack} />} />
      {lists.error && <Notice tone="error">{lists.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Row title={kind === "deck" ? "New deck" : "New cube"} detail="Name it, then add cards" onClick={() => setCreating(true)} />
        {mine.map((l) => {
          const miss = missingIn(l, owned);
          const side = countOf(l, "side"), maybe = countOf(l, "maybe");
          const detail = [l.format, side ? `${side} sideboard` : null, maybe ? `${maybe} considering` : null,
                          miss ? `${miss} missing` : "All owned", `v${current(l).number}`].filter(Boolean).join(" · ");
          return <Row key={l.id} title={l.name} detail={detail} value={countOf(l, "main")} onClick={() => onOpen(l.id)} />;
        })}
      </div>
      {creating && (
        <Modal title={kind === "deck" ? "New deck" : "New cube"} onClose={() => setCreating(false)}>
          <Field label="Name" value={name} onChange={setName} autoFocus />
          <Segmented options={(kind === "deck" ? DECK_FORMATS : CUBE_FORMATS).map((f) => ({ value: f, label: f }))}
                     value={format} onChange={setFormat} columns={4} />
          <BigAction label={kind === "deck" ? "Create deck" : "Create cube"} onClick={create} disabled={!name.trim()} busy={busy} />
        </Modal>
      )}
    </LibScreen>
  );
}

/* ── one list ─────────────────────────────────────────────────────────── */

export function ListScreen({ id, onBack, onCard, onAdd, onVersions }: {
  id: string; onBack: () => void; onCard: (oracleId: string) => void; onAdd: () => void; onVersions: () => void;
}) {
  const { session, ready, lists, owned } = useListsData();
  const { catalog, error } = useCatalog();
  const [grid, setGrid] = useStoredFlag("table1.library.list.grid");
  const [editing, setEditing] = useState(false);
  const [moving, setMoving] = useState<Line | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const list = lists.lists.find((l) => l.id === id) ?? null;
  const lines = useMemo(() => (list && catalog ? linesOf(list, catalog) : []), [list, catalog]);
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
        <Bar title="List" right={<Back onClick={onBack} />} />
        <Notice tone="info">{lists.ready ? "That list isn't here anymore." : "Loading…"}</Notice>
      </Screen>
    );
  }
  const cols = Math.max(3, Math.floor(width / 180));
  const tile = Math.floor((width - (cols - 1)) / cols);
  const v = current(list);

  const lineRow = (x: Line) => {
    const have = owned.get(x.cardId) ?? 0;
    const considering = x.board === "maybe";
    const short = !considering && have < x.qty;
    if (editing) {
      return (
        <div key={`${x.board}|${x.cardId}`} className="flex items-stretch gap-px h-[60px]">
          <div className="flex-1 min-w-0">
            <CardRow c={catalog!} p={x.p} title={x.name} detail="Tap to move or remove" value={x.qty} onClick={() => setMoving(x)} />
          </div>
          <button type="button" aria-label="Remove one" className="w-14 bg-t1-surface-hover text-[20px]"
                  onClick={() => editList(list.id, [{ card_id: x.cardId, board: x.board, delta: -1 }])}>−</button>
          <button type="button" aria-label="Add one" className="w-14 bg-t1-surface-hover text-[20px]"
                  onClick={() => editList(list.id, [{ card_id: x.cardId, board: x.board, delta: 1 }])}>+</button>
        </div>
      );
    }
    return (
      <div key={`${x.board}|${x.cardId}`} className="h-[60px]">
        <CardRow c={catalog!} p={x.p} title={x.name} value={x.qty} warn={short}
                 detail={considering ? (have ? `Owned ${have}` : "Not owned") : short ? `Owned ${have} · missing ${x.qty - have}` : `Owned ${have}`}
                 onClick={() => x.oracleId && onCard(x.oracleId)} />
      </div>
    );
  };

  return (
    <LibScreen>
      <Bar title={list.name} subtitle={`${list.format} ${list.kind} · v${v.number}`}
           right={<span className="flex gap-4">
             <button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => setEditing(!editing)}>{editing ? "Done" : "Edit"}</button>
             {!editing && <BarToggle on={grid} onChange={setGrid} />}
             <Back onClick={onBack} />
           </span>} />
      {(lists.error || error) && <Notice tone="error">{lists.error ?? error}</Notice>}
      <div ref={boxRef} className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface py-4 flex">
          <Stat label={list.kind === "deck" ? "Main" : "Cards"} value={countOf(list, "main")} />
          {list.kind === "deck" && <Stat label="Side" value={countOf(list, "side")} />}
          <Stat label="Considering" value={countOf(list, "maybe")} />
          <Stat label="Missing" value={missingIn(list, owned)} />
        </div>
        {editing && <Row title={list.kind === "deck" ? "Delete deck" : "Delete cube"} detail="From every device" onClick={() => setConfirmDelete(true)} />}
        <Row title="Add cards" detail={list.kind === "deck" ? "To the main deck, sideboard or considering" : "To the cube or considering"} onClick={onAdd} />
        <Row title="Version history" detail={`v${v.number} · ${v.note} · ${fmtDate(v.at)}`} value={list.versions.length} onClick={onVersions} />
        {entriesOf(list).length === 0 && <Row title="No cards yet" detail="Add cards to start this list" />}
        {!catalog && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
        {catalog && boardsOf(list).map((board) => {
          const inBoard = lines.filter((x) => x.board === board);
          return (
            <div key={board} className="flex flex-col gap-px">
              <BoardHeader title={boardTitle(list.kind, board)} count={inBoard.reduce((n, x) => n + x.qty, 0)} />
              {groupsOf(inBoard, list.kind).map((g) => {
                const inGroup = inBoard.filter((x) => x.group === g);
                return (
                  <div key={g} className="flex flex-col gap-px">
                    <Section title={g} count={inGroup.reduce((n, x) => n + x.qty, 0)} />
                    {grid && !editing ? (
                      <div className="grid gap-px" style={{ gridTemplateColumns: `repeat(${cols}, ${tile}px)` }}>
                        {inGroup.map((x) => (
                          <CardTile key={x.cardId} c={catalog} p={x.p} name={x.name} qty={x.qty} width={tile}
                                    warn={board !== "maybe" && (owned.get(x.cardId) ?? 0) < x.qty}
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
                   onClick={() => { void editList(list.id, [{ card_id: moving.cardId, from: moving.board, to: b }]); setMoving(null); }} />
            ))}
            <Row title={`Remove from ${boardTitle(list.kind, moving.board)}`}
                 onClick={() => { void editList(list.id, [{ card_id: moving.cardId, board: moving.board, qty: 0 }]); setMoving(null); }} />
          </div>
        </Modal>
      )}
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
  if (!list) return <Screen><Bar title="Add cards" right={<Back onClick={onDone} />} /></Screen>;
  return (
    <LibScreen>
      <Bar title={`Add to ${list.name}`} subtitle={`v${current(list).number}`} right={<Back onClick={onDone} />} />
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
  if (!list) return <Screen><Bar title="Version history" right={<Back onClick={onBack} />} /></Screen>;
  const vs = list.versions;
  return (
    <LibScreen>
      <Bar title="Version history" subtitle={list.name} right={<Back onClick={onBack} />} />
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
  if (!list || i < 0) return <Screen><Bar title={`v${number}`} right={<Back onClick={onBack} />} /></Screen>;
  const v = list.versions[i];
  const prev = i > 0 ? list.versions[i - 1] : null;
  const changes = prev ? diff(prev, v) : [];
  const count = (b: Board) => v.entries.filter((e) => e.board === b).reduce((n, e) => n + e.qty, 0);
  return (
    <LibScreen>
      <Bar title={`v${number} · ${v.note}`} subtitle={list.name} right={<Back onClick={onBack} />} />
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
                <div key={c.cardId} className="h-[60px]">
                  <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Unknown card"} detail={c.delta > 0 ? "Added" : "Removed"}
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
