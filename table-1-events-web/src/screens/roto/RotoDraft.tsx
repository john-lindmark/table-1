// The Draft phase of a roto event (plan-roto-2026-10-15.md "Client views"): a one-line summary, then Grid / Cube /
// Picks / My list in a Table 1 segmented control. Organizers also get Pick for, Undo last pick and the pick clock.
// Same layout and behaviour as apps/ios/Table1/Roto/RotoDraftView.swift.
import { memo, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { cardImageUrl } from "../../lib/catalog";
import { useRoto, useRotoStore, type PickSource, type RotoStore } from "../../lib/roto";
import { COLOR_GROUPS, COLOR_HEX, countdownText, isAutomatic, pickNoAt, roundOf, type RotoCard } from "../../lib/rotoMath";
import { capture, screen as screenView, span } from "../../lib/telemetry";
import { BigAction, Bar, Dialog, GhostAction, Modal, Notice, Row, Section, Segmented, SwitchRow, TabBar, useNow } from "../../components/kit";
import { RotoClockEditor } from "./RotoSetup";

export type RotoTab = "grid" | "cube" | "picks" | "list";
const TAB_LABELS: Record<RotoTab, string> = { grid: "Grid", cube: "Cube", picks: "Picks", list: "My list" };

/**
 * Between Setup and Live, for organizers and players alike: the Draft screen once the draft has started (or is
 * done), otherwise `children` (the Setup / player screen). Round 1 paired → the caller stops using this.
 */
export function RotoDraftGate({
  eventId, title, isOrganizer, onBack, pairRound1, children,
}: {
  eventId: string;
  title: string;
  isOrganizer: boolean;
  onBack?: () => void;
  /** Organizer, once the draft is done. */
  pairRound1?: () => Promise<void>;
  children: ReactNode;
}) {
  const store = useRoto(eventId);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!store) return <>{children}</>;
  if (!store.loaded && !store.error) {
    return <div className="h-[100dvh] flex items-center justify-center t1-label bg-t1-bg">Loading draft…</div>;
  }
  if (store.phase === "setup") return <>{children}</>;
  const pair = pairRound1
    ? async () => {
        setBusy(true);
        setError(null);
        try {
          await pairRound1();
        } catch (e) {
          setError(e instanceof Error ? e.message : String(e));
        } finally {
          setBusy(false);
        }
      }
    : undefined;
  return (
    <RotoDraftScreen store={store} title={title} isOrganizer={isOrganizer} onBack={onBack} pairRound1={pair} busy={busy}
                     outsideError={error} />
  );
}

/** The read-only Draft over Live / Results (players look at each other's picks during the matches). */
export function RotoDraftOverlay({ eventId, title, isOrganizer, pairing, onClose }: {
  eventId: string; title: string; isOrganizer: boolean; pairing: "swiss" | "round_robin"; onClose: () => void;
}) {
  const store = useRoto(eventId);
  if (!store) return null;
  return (
    <div className="fixed inset-0 z-40 bg-t1-bg">
      <RotoDraftScreen store={store} title={title} isOrganizer={isOrganizer} readOnly onBack={onClose} pairing={pairing} />
    </div>
  );
}

export function RotoDraftScreen({
  store: s, title, isOrganizer, readOnly = false, onBack, pairRound1, pairing, busy = false, outsideError, initialTab = "grid",
}: {
  store: RotoStore;
  title: string;
  isOrganizer: boolean;
  /** After round 1: the draft stays readable, nothing can be picked. */
  readOnly?: boolean;
  onBack?: () => void;
  pairRound1?: () => void;
  pairing?: "swiss" | "round_robin";
  busy?: boolean;
  outsideError?: string | null;
  initialTab?: RotoTab;
}) {
  const store = useRotoStore(s);
  const navigate = useNavigate();
  const tabs: RotoTab[] = store.me ? ["grid", "cube", "picks", "list"] : ["grid", "cube", "picks"];
  const [tab, setTab] = useState<RotoTab>(initialTab);
  const [panel, setPanel] = useState<{ slot: number; from: PickSource } | null>(null);
  const [menu, setMenu] = useState(false);
  const [clockPanel, setClockPanel] = useState(false);
  const [confirmUndo, setConfirmUndo] = useState(false);
  const shownTab = tabs.includes(tab) ? tab : "grid";

  useEffect(() => screenView(`roto_${shownTab}`), [shownTab]);

  const openDeck = async (from: "event" | "picks") => {
    const id = await store.openDeckId();
    if (!id) return;
    capture("roto_deck_opened", { from });
    navigate(`/library/list/${id}`);
  };

  const parts = [readOnly && pairing ? (pairing === "round_robin" ? "Round robin" : "Swiss") : "Draft",
                 `${store.players} players`, `${store.draft.picksPerPlayer} picks each`, store.snake ? "Snake" : "Same order"];
  const organizerLive = isOrganizer && !readOnly && store.phase === "drafting";
  const pickFor = organizerLive && !!store.onClock && store.onClock.participantId !== store.me?.participantId;
  const open = (slot: number, from: PickSource) => setPanel({ slot, from });

  return (
    <div className="h-[100dvh] w-full bg-t1-bg text-t1-text flex flex-col gap-px">
      <Bar title={title} subtitle={parts.join(" · ")} onBack={onBack}
           right={organizerLive ? <button type="button" className="t1-label hover:text-t1-text shrink-0" onClick={() => setMenu(true)}>More</button> : undefined} />
      <RotoSummary store={store} onPickFor={pickFor ? () => setTab("cube") : undefined} />
      {(outsideError ?? store.error) && <Notice tone="error">{outsideError ?? store.error}</Notice>}
      {store.notice && <Notice tone="info">{store.notice}</Notice>}
      <TabBar tabs={tabs} value={shownTab} labels={TAB_LABELS}
              onChange={(t) => {
                // "Taken by …" on My list shows once: cleared when you leave the list.
                if (shownTab === "list" && t !== "list") store.dismissTaken();
                setTab(t);
              }} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {shownTab === "grid" && <RotoGrid store={store} interactive={!readOnly} onCell={open} onNext={() => setTab("cube")} />}
        {shownTab === "cube" && <RotoCube store={store} onOpen={(slot) => open(slot, "cube")} />}
        {shownTab === "picks" && <RotoPicks store={store} onOpen={(slot) => open(slot, "detail")} onOpenDeck={() => void openDeck("picks")} />}
        {shownTab === "list" && <RotoList store={store} readOnly={readOnly} onOpen={(slot) => open(slot, "list")} onAdd={() => { store.dismissTaken(); setTab("cube"); }} />}
      </div>
      {pairRound1 && store.phase === "done" && !readOnly ? (
        <BigAction label="Pair round 1" tone="accent" busy={busy} onClick={pairRound1} />
      ) : store.phase === "done" && store.me?.deckListId && !readOnly ? (
        <BigAction label="Open deck" tone="accent" onClick={() => void openDeck("event")} />
      ) : null}

      {panel && (
        <RotoCardPanel store={store} slot={panel.slot} from={panel.from} isOrganizer={isOrganizer} readOnly={readOnly}
                       onClose={() => setPanel(null)} />
      )}
      {menu && (
        <Modal title="Draft" onClose={() => setMenu(false)}>
          <div className="flex flex-col gap-px">
            {pickFor && store.onClock && (
              <Row title={`Pick for ${store.name(store.onClock.seat)}`} detail="Choose the card in the Cube"
                   onClick={() => { setMenu(false); setTab("cube"); }} />
            )}
            <Row title="Undo last pick" detail={store.picksMade > 0 ? "With the automatic picks after it" : "Nothing picked yet"}
                 onClick={store.picksMade > 0 ? () => { setMenu(false); setConfirmUndo(true); } : undefined} />
            {!!store.draft.clock?.length && (
              <Row title={store.draft.clockPaused ? "Resume clock" : "Pause clock"}
                   onClick={() => { setMenu(false); void store.setClock(null, !store.draft.clockPaused); }} />
            )}
            <Row title="Pick clock" value={store.draft.clock?.length ? `${store.draft.clock.length} range${store.draft.clock.length === 1 ? "" : "s"}` : "Off"}
                 onClick={() => { setMenu(false); setClockPanel(true); }} />
          </div>
          <GhostAction label="Close" onClick={() => setMenu(false)} />
        </Modal>
      )}
      {clockPanel && (
        <Modal title={store.draft.clockPaused ? "Pick clock · paused" : "Pick clock"} onClose={() => setClockPanel(false)}>
          <div className="flex flex-col gap-px max-h-[60dvh] overflow-y-auto">
            <RotoClockEditor ranges={store.draft.clock ?? []} rounds={store.draft.picksPerPlayer} save={(r) => store.setClock(r)} />
            {!!store.draft.clock?.length && (
              <GhostAction label={store.draft.clockPaused ? "Resume clock" : "Pause clock"}
                           onClick={() => void store.setClock(null, !store.draft.clockPaused)} />
            )}
            <Notice tone="info">Changes apply from the next turn; the current turn keeps its time.</Notice>
            {store.error && <Notice tone="error">{store.error}</Notice>}
          </div>
          <GhostAction label="Done" onClick={() => setClockPanel(false)} />
        </Modal>
      )}
      {confirmUndo && (
        <Dialog title="Undo the last pick?" message="Removes the last pick a person made and any automatic picks after it. Their decks follow."
                cancelLabel="Keep it" confirmLabel="Undo" tone="danger" busy={store.busy}
                onCancel={() => setConfirmUndo(false)} onConfirm={() => void store.undo().then(() => setConfirmUndo(false))} />
      )}
    </div>
  );
}

/* ── summary line ─────────────────────────────────────────────────── */

/** `ON THE CLOCK · ANNA · PICK 37/360`, then `YOU PICK IN 3` / `YOUR PICK` (accent) and the clock. */
function RotoSummary({ store, onPickFor }: { store: RotoStore; onPickFor?: () => void }) {
  const ticking = store.phase === "drafting" && !!store.draft.clock?.length && !store.draft.clockPaused;
  const now = useNow(ticking, 1000);
  useEffect(() => {
    if (ticking) store.expireIfDue(now);
  }, [now, ticking, store]);
  const c = store.onClock;
  let head: string;
  if (store.phase === "done") head = `Draft done · ${store.picksMade} picks`;
  else if (store.pending) head = `Picking · ${store.card(store.pending.slot)?.name ?? "card"} · pick ${store.pending.pickNo}/${store.total}`;
  else if (c) head = `On the clock · ${store.name(c.seat)} · pick ${c.pickNo}/${store.total}`;
  else head = "Draft not started";
  const until = store.picksUntilMine;
  const turn = store.phase !== "drafting" ? null
    : until === 0 ? <span className="text-t1-accent">Your pick</span>
    : until != null ? <span>You pick in {until}</span>
    : store.me ? <span>Your picks are done</span> : <span>Watching</span>;
  let clock: ReactNode = null;
  if (store.phase === "drafting" && store.draft.clock?.length && !store.pending && c) {
    const left = store.secondsLeft(now);
    if (store.draft.clockPaused) clock = <span> · Paused</span>;
    else if (c.overdue || left === 0) clock = <span className="text-t1-danger"> · Overdue</span>;
    else if (left != null) clock = <span className="tabular-nums"> · {countdownText(left)}</span>;
  }
  return (
    <div className="shrink-0 bg-t1-surface px-4 py-3 flex items-center gap-3">
      <div className="flex-1 min-w-0 flex flex-col gap-1">
        <p className="t1-label text-t1-text! truncate">{head}</p>
        {turn && <p className="t1-label truncate">{turn}{clock}</p>}
      </div>
      {onPickFor && (
        <button type="button" onClick={onPickFor} className="shrink-0 bg-t1-surface-hover px-3 py-2.5 t1-label text-t1-text!">
          Pick for
        </button>
      )}
    </div>
  );
}

/* ── color bar ───────────────────────────────────────────────────── */

/** Thin bar in the card's colors (grey for none); lands get a neutral bar. */
function ColorBar({ card, vertical = false, className = "" }: { card: RotoCard | null; vertical?: boolean; className?: string }) {
  const list = card?.colors.length ? card.colors : [card?.isLand ? "L" : "C"];
  return (
    <span className={`flex ${vertical ? "flex-col" : ""} ${className}`} aria-hidden="true">
      {list.map((c) => <span key={c} className="flex-1" style={{ background: COLOR_HEX[c] }} />)}
    </span>
  );
}

/* ── grid ─────────────────────────────────────────────────────────── */

const CELL_W = 108;
const CELL_H = 46;
const HEAD_H = 34;
const COL_W = 44;
const ROW = CELL_H + 1;
const OVERSCAN = 4;

/**
 * The classic roto sheet: seats across (sticky names), rounds down (sticky numbers with the snake direction).
 * Only the rows in view (plus a few) are in the page, so 12 × 45 cells scroll smoothly.
 */
function RotoGrid({ store, interactive, onCell, onNext }: {
  store: RotoStore; interactive: boolean; onCell: (slot: number, from: PickSource) => void; onNext: () => void;
}) {
  const seats = store.orderedSeats;
  const n = Math.max(1, store.players);
  const rounds = Math.max(1, store.draft.picksPerPlayer);
  const next = store.phase === "drafting" && !store.pending ? store.picksMade + 1 : null;
  const current = roundOf(n, Math.min(store.total, Math.max(1, store.picksMade + 1)));
  const ref = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ top: 0, height: 800 });
  const frame = useRef(0);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    // Opens scrolled to the current round.
    if (current > 3) el.scrollTop = (current - 3) * ROW;
    setView({ top: el.scrollTop, height: el.clientHeight });
    const ro = new ResizeObserver(() => setView({ top: el.scrollTop, height: el.clientHeight }));
    ro.observe(el);
    if (!store.gridTraced && store.loaded) {
      store.gridTraced = true;
      const sp = span("roto.grid", "first_render");
      requestAnimationFrame(() => sp.finish());
    }
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (!seats.length) return <Notice tone="info">No one is seated yet.</Notice>;
  const first = Math.max(0, Math.floor((view.top - HEAD_H) / ROW) - OVERSCAN);
  const last = Math.min(rounds, Math.ceil((view.top + view.height) / ROW) + OVERSCAN);
  const width = COL_W + 1 + n * (CELL_W + 1);
  const rows = [];
  for (let r = first + 1; r <= last; r++) {
    rows.push(<GridRow key={r} store={store} round={r} players={n} next={next} current={r === current} version={store.version}
                       interactive={interactive} onCell={onCell} onNext={onNext} />);
  }
  return (
    <div ref={ref} className="flex-1 min-h-0 overflow-auto overscroll-contain"
         onScroll={(e) => {
           const el = e.currentTarget;
           cancelAnimationFrame(frame.current);
           frame.current = requestAnimationFrame(() => setView({ top: el.scrollTop, height: el.clientHeight }));
         }}>
      <div style={{ width, minHeight: HEAD_H + 1 + rounds * ROW }}>
        <div className="sticky top-0 z-20 flex gap-px bg-t1-bg pb-px" style={{ width }}>
          <span className="sticky left-0 z-30 bg-t1-surface t1-label flex items-center justify-center shrink-0" style={{ width: COL_W, height: HEAD_H }}>Rd</span>
          {seats.map((st) => (
            <span key={st.participantId} title={st.displayName}
                  className={`shrink-0 bg-t1-surface px-1.5 flex items-center text-[10px] uppercase tracking-[1px] truncate ${st.me ? "text-t1-accent" : ""}`}
                  style={{ width: CELL_W, height: HEAD_H }}>
              <span className="truncate">{st.me ? "You" : st.displayName}</span>
            </span>
          ))}
        </div>
        <div style={{ height: first * ROW }} />
        {rows}
        <div style={{ height: (rounds - last) * ROW }} />
      </div>
    </div>
  );
}

/** One round of the sheet: a cell per seat. Re-renders only when the store changes (`version`). */
const GridRow = memo(function GridRow({ store, round, players, next, current, interactive, onCell, onNext }: {
  store: RotoStore; round: number; players: number; next: number | null; current: boolean; version: number;
  interactive: boolean; onCell: (slot: number, from: PickSource) => void; onNext: () => void;
}) {
  const cells = [];
  for (let seat = 1; seat <= players; seat++) {
    const no = pickNoAt(seat, round, players, store.snake);
    const p = no <= store.total ? store.pick(no) : null;
    const card = p ? store.card(p.slot) : null;
    const isNext = next === no;
    cells.push(
      <button key={seat} type="button"
              onClick={() => (p ? onCell(p.slot, "grid") : isNext && interactive ? onNext() : undefined)}
              className={`shrink-0 bg-t1-surface hover:bg-t1-surface-hover text-left flex flex-col relative ${isNext ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}
              style={{ width: CELL_W, height: CELL_H }}>
        {card && <ColorBar card={card} className="h-[3px] w-full shrink-0" />}
        <span className="px-1.5 py-1 flex flex-col gap-0.5 min-w-0">
          {card ? (
            <>
              <span className={`text-[10px] leading-[12px] line-clamp-2 break-words ${store.pending?.pickNo === no ? "text-t1-muted" : ""}`}>{card.name}</span>
              {p && isAutomatic(p) && <span className="text-[8px] tracking-[1px] text-t1-muted">AUTO</span>}
            </>
          ) : isNext ? (
            <span className="text-[10px] text-t1-accent">#{no}</span>
          ) : no <= store.total ? (
            <span className="text-[9px] text-t1-muted/60">{no}</span>
          ) : null}
        </span>
      </button>,
    );
  }
  return (
    <div className="flex gap-px mb-px" style={{ height: CELL_H }}>
      <span className={`sticky left-0 z-10 shrink-0 flex flex-col items-center justify-center text-[11px] ${current ? "bg-t1-surface-hover text-t1-text" : "bg-t1-surface text-t1-muted"}`}
            style={{ width: COL_W }}>
        <span>{round}</span>
        <span className="text-[10px] text-t1-muted">{store.snake && round % 2 === 0 ? "←" : "→"}</span>
      </span>
      {cells}
    </div>
  );
});

/* ── cube ─────────────────────────────────────────────────────────── */

type CubeFilter = "available" | "all" | "picked";

/** Every card in the pool by color, with search and Available · All · Picked. Picked cards keep a flat `#23 · ANNA`. */
function RotoCube({ store, onOpen }: { store: RotoStore; onOpen: (slot: number) => void }) {
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<CubeFilter>("available");
  const q = query.trim().toLowerCase();
  const groups = useMemo(() => {
    const by = new Map<string, number[]>();
    for (const slot of store.poolOrder) {
      const taken = !!store.takenBy(slot);
      if ((filter === "available" && taken) || (filter === "picked" && !taken)) continue;
      const card = store.card(slot);
      if (!card || (q && !card.name.toLowerCase().includes(q))) continue;
      by.set(card.group, [...(by.get(card.group) ?? []), slot]);
    }
    return COLOR_GROUPS.filter((g) => by.has(g)).map((g) => ({ name: g, slots: by.get(g)! }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [store.version, q, filter]);
  return (
    <>
      <label className="shrink-0 bg-t1-surface px-4 py-3 flex items-center gap-3">
        <span className="t1-label shrink-0">Search</span>
        <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search the cube"
               className="flex-1 min-w-0 bg-transparent border-0 outline-0 text-[14px] placeholder:text-t1-muted/60" />
      </label>
      <div className="shrink-0">
        <Segmented value={filter} onChange={setFilter}
                   options={[{ value: "available", label: "Available" }, { value: "all", label: "All" }, { value: "picked", label: "Picked" }]} />
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {store.pool.size === 0 && <Notice tone="info">{store.loaded ? "The pool appears when the draft starts." : "Loading…"}</Notice>}
        {groups.map((g) => (
          <div key={g.name} className="flex flex-col gap-px">
            <Section title={g.name} count={g.slots.length} />
            {g.slots.map((slot) => <CubeRow key={slot} store={store} slot={slot} onOpen={onOpen} />)}
          </div>
        ))}
        {store.pool.size > 0 && groups.length === 0 && <Notice tone="info">{q ? `No card matches “${query.trim()}”` : "Nothing here."}</Notice>}
      </div>
    </>
  );
}

const typeDetail = (c: RotoCard) => {
  const type = c.typeLine.split(" — ")[0];
  return c.isLand ? type : `${type} · ${c.manaValue}`;
};

/** A pool card: color bar, name, type · mana value; picked ones carry `#23 · ANNA`, listed ones `LISTED #4`. */
function CubeRow({ store, slot, onOpen }: { store: RotoStore; slot: number; onOpen: (slot: number) => void }) {
  const card = store.card(slot);
  const taken = store.takenBy(slot);
  const listed = store.inList(slot);
  return (
    <button type="button" onClick={() => onOpen(slot)}
            className="shrink-0 bg-t1-surface hover:bg-t1-surface-hover px-4 py-2.5 flex items-center gap-3 text-left w-full [content-visibility:auto] [contain-intrinsic-size:auto_52px]">
      <ColorBar card={card} vertical className="w-[3px] h-7 shrink-0" />
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        <span className={`text-[14px] truncate ${taken ? "text-t1-muted" : ""}`}>{card?.name ?? "Card"}</span>
        <span className="t1-label truncate">{card ? typeDetail(card) : ""}</span>
      </span>
      {taken ? <PickedTag>#{taken.pickNo} · {store.name(taken.seat)}</PickedTag> : listed ? <span className="t1-label shrink-0">Listed #{listed}</span> : null}
    </button>
  );
}

/** The flat disabled-color tag on picked cards: `#23 · ANNA` (no opacity dimming). */
function PickedTag({ children }: { children: ReactNode }) {
  return <span className="shrink-0 bg-t1-disabled text-white px-2 py-1 text-[10px] uppercase tracking-[1px] truncate max-w-[45%]">{children}</span>;
}

/* ── picks ────────────────────────────────────────────────────────── */

/** One player's picks: You first, then seat order. Color counts, a mana-value curve, creatures; list or images. */
function RotoPicks({ store, onOpen, onOpenDeck }: { store: RotoStore; onOpen: (slot: number) => void; onOpenDeck: () => void }) {
  const seated = store.orderedSeats.filter((x) => x.seat != null);
  const choices = [...seated.filter((x) => x.me), ...seated.filter((x) => !x.me)];
  const [seat, setSeat] = useState<number | null>(null);
  const [images, setImages] = useState(false);
  const chosen = seat ?? choices[0]?.seat ?? 1;
  const slots = store.picksOf(chosen).map((p) => p.slot);
  const cards = slots.map((x) => store.card(x)).filter((c): c is RotoCard => !!c);
  const mine = !!store.seat(chosen)?.me;
  const cat = store.catalog;
  return (
    <>
      <div className="shrink-0 flex gap-px overflow-x-auto">
        {choices.map((x) => (
          <button key={x.participantId} type="button" onClick={() => setSeat(x.seat)}
                  className={`shrink-0 px-3.5 py-3.5 text-[11px] uppercase tracking-[1px] ${x.seat === chosen ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>
            {x.me ? "You" : x.displayName}
          </button>
        ))}
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <PickStats cards={cards} />
        {mine && store.me?.deckListId && <Row title="Open deck" detail="Your picks land in Main as you draft" value="›" onClick={onOpenDeck} />}
        <Section title={`${cards.length} pick${cards.length === 1 ? "" : "s"}`}
                 right={<button type="button" className="hover:text-t1-text" onClick={() => setImages(!images)}>{images ? "List" : "Images"}</button>} />
        {cards.length === 0 && <Notice tone="info">No picks yet.</Notice>}
        {images ? (
          <div className="grid gap-2 p-3 bg-t1-surface" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(104px, 1fr))" }}>
            {slots.map((slot) => {
              const c = store.card(slot);
              return (
                <button key={slot} type="button" onClick={() => onOpen(slot)} className="aspect-[63/88] bg-t1-bg overflow-hidden">
                  {cat && c?.p != null
                    ? <img src={cardImageUrl(cat, c.p, "small")} alt={c.name} loading="lazy" className="w-full h-full object-cover" />
                    : <span className="text-[10px] p-1 block">{c?.name}</span>}
                </button>
              );
            })}
          </div>
        ) : (
          COLOR_GROUPS.map((g) => {
            const inGroup = slots.filter((x) => store.card(x)?.group === g);
            if (!inGroup.length) return null;
            return (
              <div key={g} className="flex flex-col gap-px">
                <Section title={g} count={inGroup.length} />
                {inGroup.map((slot) => {
                  const c = store.card(slot)!;
                  const p = store.takenBy(slot);
                  return <Row key={slot} title={c.name} detail={typeDetail(c)} value={p ? `#${p.pickNo}${isAutomatic(p) ? " · auto" : ""}` : ""} onClick={() => onOpen(slot)} />;
                })}
              </div>
            );
          })
        )}
      </div>
    </>
  );
}

/** Color counts, a mana-value curve (0 … 7+) and creatures / other spells / lands. */
function PickStats({ cards }: { cards: RotoCard[] }) {
  const spells = cards.filter((c) => !c.isLand);
  const curve = Array.from({ length: 8 }, (_, mv) => spells.filter((c) => (mv === 7 ? c.manaValue >= 7 : c.manaValue === mv)).length);
  const top = Math.max(1, ...curve);
  const creatures = spells.filter((c) => c.isCreature).length;
  return (
    <div className="shrink-0 bg-t1-surface p-4 flex flex-col gap-3">
      <div className="flex gap-3.5">
        {["W", "U", "B", "R", "G"].map((c) => (
          <span key={c} className="flex items-center gap-1 text-[13px] tabular-nums">
            <span className="size-2" style={{ background: COLOR_HEX[c] }} />
            {cards.filter((x) => x.colors.includes(c)).length}
          </span>
        ))}
      </div>
      <div className="flex items-end gap-1.5 h-[70px]">
        {curve.map((n, i) => (
          <span key={i} className="flex-1 flex flex-col items-center gap-[3px] text-[9px] text-t1-muted">
            <span>{n}</span>
            <span className="w-full bg-t1-text" style={{ height: Math.max(1, (n / top) * 40) }} />
            <span>{i === 7 ? "7+" : i}</span>
          </span>
        ))}
      </div>
      <p className="t1-label">{creatures} creatures · {spells.length - creatures} other spells · {cards.length - spells.length} lands</p>
    </div>
  );
}

/* ── my list ──────────────────────────────────────────────────────── */

/** Your ranked pick order: drag (or ↑ ↓) to reorder, × to remove, the auto-pick switch. Saved ~600 ms after the last change. */
function RotoList({ store, readOnly, onOpen, onAdd }: { store: RotoStore; readOnly: boolean; onOpen: (slot: number) => void; onAdd: () => void }) {
  const [drag, setDrag] = useState<number | null>(null);
  const [over, setOver] = useState<number | null>(null);
  return (
    <>
      <SwitchRow label="Auto-pick from my list" on={store.autoPick} disabled={readOnly} onChange={(on) => store.setAutoPick(on)}
                 detail={store.autoPick ? "When it's your turn, the top card still there is picked for you" : "Off: the draft waits for you"} />
      {store.takenFromList.map((t) => (
        <Notice key={t.slot} tone="info">{store.card(t.slot)?.name ?? "A card"} · taken by {store.name(t.pick.seat)} (#{t.pick.pickNo})</Notice>
      ))}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {store.queue.length === 0 && (
          <Notice tone="info">Nothing listed. Add cards from the cube in the order you want them; with auto-pick on they're picked for you when your turn comes.</Notice>
        )}
        {store.queue.map((slot, i) => {
          const c = store.card(slot);
          return (
            <div key={slot} draggable={!readOnly}
                 onDragStart={(e) => { setDrag(i); e.dataTransfer.effectAllowed = "move"; }}
                 onDragOver={(e) => { if (drag != null) { e.preventDefault(); setOver(i); } }}
                 onDragEnd={() => { setDrag(null); setOver(null); }}
                 onDrop={(e) => { e.preventDefault(); if (drag != null && drag !== i) store.moveInList(drag, i); setDrag(null); setOver(null); }}
                 className={`shrink-0 bg-t1-surface flex items-center gap-3 pl-3 min-h-12 ${over === i && drag !== i ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""} ${drag === i ? "bg-t1-surface-hover" : ""}`}>
              <span className="w-6 text-right text-[12px] text-t1-muted tabular-nums shrink-0">{i + 1}</span>
              <ColorBar card={c} vertical className="w-[3px] h-6 shrink-0" />
              <button type="button" onClick={() => onOpen(slot)} className="flex-1 min-w-0 text-left text-[14px] truncate py-3">{c?.name ?? "Card"}</button>
              {!readOnly && (
                <span className="flex shrink-0">
                  <button type="button" aria-label="Move up" disabled={i === 0} onClick={() => store.moveInList(i, i - 1)}
                          className="w-9 h-12 text-t1-muted hover:text-t1-text disabled:opacity-30">↑</button>
                  <button type="button" aria-label="Move down" disabled={i === store.queue.length - 1} onClick={() => store.moveInList(i, i + 1)}
                          className="w-9 h-12 text-t1-muted hover:text-t1-text disabled:opacity-30">↓</button>
                  <button type="button" aria-label={`Remove ${c?.name ?? "card"}`} onClick={() => store.removeFromList(slot)}
                          className="w-10 h-12 text-[18px] text-t1-muted hover:text-t1-text">×</button>
                </span>
              )}
            </div>
          );
        })}
      </div>
      {!readOnly && <div className="shrink-0 flex"><GhostAction label="Add from the cube" onClick={onAdd} /></div>}
    </>
  );
}

/* ── card panel ───────────────────────────────────────────────────── */

/** A card from the pool: picture, who took it, and Pick (your turn; organizers: Pick for) / your list. */
function RotoCardPanel({ store, slot, from, isOrganizer, readOnly, onClose }: {
  store: RotoStore; slot: number; from: PickSource; isOrganizer: boolean; readOnly: boolean; onClose: () => void;
}) {
  const [confirm, setConfirm] = useState(false);
  const card = store.card(slot);
  const taken = store.takenBy(slot);
  const clock = store.onClock;
  const canPick = !readOnly && !taken && store.phase === "drafting" && !store.pending && (store.isMyTurn || (isOrganizer && !!clock));
  const forWhom = clock && clock.participantId !== store.me?.participantId ? store.name(clock.seat) : null;
  const listed = store.inList(slot);
  const cat = store.catalog;
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center" role="dialog" aria-modal="true" aria-label={card?.name ?? "Card"}>
      <div className="absolute inset-0 bg-black/70" onClick={onClose} />
      <div className="relative w-full max-w-[480px] bg-t1-bg flex flex-col gap-px max-h-[92dvh] overflow-y-auto">
        <Bar title={card?.name ?? "Card"} subtitle={card?.typeLine}
             right={<button type="button" className="t1-label hover:text-t1-text shrink-0" onClick={onClose}>Close</button>} />
        <div className="bg-t1-surface py-4 flex justify-center">
          {cat && card?.p != null
            ? <img src={cardImageUrl(cat, card.p, "normal")} alt={card.name} className="w-[220px] aspect-[63/88] object-cover rounded-[4.32%/3.1%]" />
            : <div className="w-[220px] aspect-[63/88] bg-t1-bg flex items-center justify-center t1-label">{card?.name}</div>}
        </div>
        {taken ? (
          <Row title={`Picked #${taken.pickNo} by ${store.name(taken.seat)}`}
               detail={taken.how === "player" ? undefined : taken.how === "organizer" ? "Picked by the organizer" : "Picked from their list"} />
        ) : (
          <Row title="Available" detail={listed ? `On your list at #${listed}` : undefined} />
        )}
        {!readOnly && !taken && store.me && store.phase !== "done" && (
          <div className="flex">
            <GhostAction label={listed ? "Remove from my list" : "Add to my list"}
                         onClick={() => (listed ? store.removeFromList(slot) : store.addToList(slot))} />
          </div>
        )}
        {canPick && <BigAction label={forWhom ? `Pick for ${forWhom}` : "Pick"} tone="accent" onClick={() => setConfirm(true)} />}
      </div>
      {confirm && (
        <Dialog title={forWhom ? `Pick ${card?.name ?? "this card"} for ${forWhom}?` : `Pick ${card?.name ?? "this card"}?`}
                message={forWhom ? "Recorded as an organizer pick." : "It goes into your deck. Picks can't be taken back (the organizer can undo)."}
                cancelLabel="Not yet" confirmLabel="Pick"
                onCancel={() => setConfirm(false)}
                onConfirm={() => { setConfirm(false); onClose(); void store.pickSlot(slot, from); }} />
      )}
    </div>
  );
}
