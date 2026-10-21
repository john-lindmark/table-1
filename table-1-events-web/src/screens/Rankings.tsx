import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Avatar } from "../components/Avatar";
import { Bar, Dialog, Field, GhostAction, Menu, Notice, Row, Section, Segmented, type MenuItem } from "../components/kit";
import { cardImageUrl, cornerRatio, type Catalog } from "../lib/catalog";
import { JOB_TITLE, compare, why, type Link, type RankChange, type RankJob, type RankSession, type RankingState } from "../lib/cubeRanking";
import { fileName } from "../lib/deckImage";
import {
  createRanking, deleteRanking, fetchBrief, fetchRankable, fetchRankings, progressText, rankingModel, shortDate, useRanking, whose,
  type CubeRankings, type RankCard, type RankableCube, type RankingBrief, type RankingModel, type RankingRow,
} from "../lib/rankings";
import { entriesOf } from "../lib/lists";
import { rankingsDemo, startRankingsDemo } from "../lib/rankings";
import { capture } from "../lib/telemetry";
import { CardArt, CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";
import { useListsData } from "./Lists";

/* Cube rankings (contract/cube-rankings-2026-10-21.md, "Where"), the same screens as iOS RankingsViews.swift: a Rankings
   row on each cube, a cube's rankings, one ranking's overview, the picking screen (drag, tap two to swap, or keys
   1–4 / ← → / Enter / Z), lists with each card's history, compare, P1P1 packs, the change log and the top 100 picture. */

const plural = (n: number, one: string, many?: string) => `${n.toLocaleString()} ${n === 1 ? one : many ?? `${one}s`}`;
const listTitle = (job: RankJob, top: number) => (job === "F" ? `Top ${top}` : JOB_TITLE[job]);

/* ── the row on a cube ──────────────────────────────────────────────── */

export function RankingsRow({ listId, onOpen }: { listId: string; onOpen: () => void }) {
  const [detail, setDetail] = useState<string | null>(null);
  const { demo } = useLibrarySession();
  useEffect(() => {
    if (demo && !rankingsDemo()) return; // the dev demo's rankings are built when Rankings opens
    let live = true;
    fetchRankings(listId).then((r) => {
      if (!live) return;
      const mine = r.rankings.find((x) => x.mine);
      setDetail(!r.rankings.length ? "Rank this cube's cards"
        : [plural(r.rankings.length, "ranking"), mine ? `yours: ${mine.sorted}/${mine.categories} sorted` : null].filter(Boolean).join(" · "));
    }).catch(() => {});
    return () => { live = false; };
  }, [listId]);
  return <Row title="Rankings" detail={detail ?? "Stack-rank this cube's cards"} onClick={onOpen} />;
}

/* ── a cube's rankings, or all of yours ─────────────────────────────── */

export function RankingsScreen({ listId, onBack, onOpen, onCube }: {
  listId: string | null; onBack: () => void; onOpen: (id: string) => void;
  /** Your rankings: open someone else's cube's rankings, to rank it. */
  onCube?: (listId: string) => void;
}) {
  const [data, setData] = useState<CubeRankings | null>(null);
  /** Every ranking of yours: other people's cubes you can rank too. */
  const [others2, setOthers2] = useState<RankableCube[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("My ranking");
  const [depth, setDepth] = useState<"half" | "full">("half");
  const [top, setTop] = useState(100);
  const [sharing, setSharing] = useState<"cube" | "private">("cube");
  const [busy, setBusy] = useState(false);
  const load = () => Promise.all([fetchRankings(listId), listId == null ? fetchRankable() : Promise.resolve([])])
    .then(([d, r]) => { setData(d); setOthers2(r); setError(null); }).catch((e) => setError((e as Error).message));
  useEffect(() => { void load(); }, [listId]);
  const cube = data?.cube ?? null;
  const mine = data?.rankings.filter((r) => r.mine) ?? [], others = data?.rankings.filter((r) => !r.mine) ?? [];
  const create = async () => {
    if (!cube || busy) return;
    setBusy(true);
    try {
      const r = await createRanking({ listId: cube.id, name: name.trim(), depth, top, sharing, ownCube: cube.mine });
      setCreating(false);
      onOpen(r.id);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const row = (r: RankingRow) => (
    <Row key={r.id} title={r.name} onClick={() => onOpen(r.id)} value={shortDate(r.updated_at) ?? undefined}
         detail={[listId == null ? r.cube?.name : r.mine ? "You" : r.by?.display_name, progressText(r)].filter(Boolean).join(" · ")}
         avatar={r.mine ? undefined : <Avatar name={r.by?.display_name ?? "?"} userId={r.by?.user_id} size={28} />} />
  );
  return (
    <LibScreen>
      <Bar title="Rankings" subtitle={listId == null ? "Yours, and cubes you can rank" : cube ? (cube.mine ? cube.name : `${cube.name} · ${cube.owner?.display_name ?? ""}`) : undefined}
           onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {error && <Notice tone="error">{error}</Notice>}
        {!data && !error && <Notice tone="info">Loading rankings…</Notice>}
        {data && listId != null && (
          <Notice tone="info">Sort each color by putting up to four cards in order at a time, then rank the best cards across the whole cube.
            Everyone who can see this cube can watch and compare the rankings shared with it.</Notice>
        )}
        {data?.can_rank && cube && (creating ? (<>
          <Field label="Name" value={name} onChange={setName} />
          <Segmented options={[{ value: "half", label: "Top half" }, { value: "full", label: "Every card" }]} value={depth} onChange={setDepth} />
          <Notice tone="info">{depth === "half" ? "Each color is ordered until its top half is in order; the rest sit below it. About half the screens."
                                                : "Every card of each color is put in order."}</Notice>
          <Segmented options={[{ value: 100, label: "Top 100" }, { value: 50, label: "Top 50" }]} value={top} onChange={setTop} />
          <Segmented options={[{ value: "cube", label: "Shared with the cube" }, { value: "private", label: "Only me" }]} value={sharing} onChange={setSharing} />
          <Notice tone="info">{sharing === "cube" ? `Who sees this: everyone who can see ${cube.name}${cube.mine ? "" : `, including ${cube.owner?.display_name ?? "its owner"}`}.`
                                                  : "Who sees this: only you."}</Notice>
          <div className="flex gap-px">
            <GhostAction label="Cancel" onClick={() => setCreating(false)} />
            <button type="button" onClick={() => void create()} disabled={busy}
                    className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px]">{busy ? "Starting…" : "Start"}</button>
          </div>
        </>) : <Row title={cube.mine ? "New ranking" : cube.owner ? `Rank ${cube.owner.display_name}'s cube` : "Rank this cube"}
                    detail={cube.mine ? "Sort each color, then the top 100" : "Your own ranking: each color, then the top 100"} onClick={() => setCreating(true)} />)}
        {data && mine.length > 0 && (<>{listId != null && <Section title="Yours" />}{mine.map(row)}</>)}
        {data && listId != null && (<>
          <Section title="Everyone else's" />
          {!others.length && <Notice tone="info">Nobody else has ranked this cube yet.</Notice>}
          {others.map(row)}
        </>)}
        {data && listId == null && !mine.length && <Notice tone="info">No rankings yet. Open one of your cubes and choose Rankings, or rank a friend's cube below.</Notice>}
        {data && listId == null && (<>
          <Section title="Cubes you can rank" />
          {!others2.length && <Notice tone="info">When a friend, or someone you've played with, shares a cube with you, it shows here. You can also open any cube
            shared with you on someone's profile and choose Rankings.</Notice>}
          {others2.map((c) => (
            <Row key={c.id} title={c.name} onClick={() => onCube?.(c.id)} avatar={<Avatar name={c.owner?.display_name ?? "?"} userId={c.owner?.user_id} size={28} />}
                 detail={[c.owner?.display_name, plural(c.cards, "card"), c.rankings ? plural(c.rankings, "ranking") : "no rankings yet", c.mine ? `${c.mine} yours` : null]
                   .filter(Boolean).join(" · ")} />
          ))}
        </>)}
      </div>
    </LibScreen>
  );
}

/* ── shared pieces ──────────────────────────────────────────────────── */

function useOthers(m: RankingModel) {
  const [others, setOthers] = useState<RankingRow[]>([]);
  const list = m.row?.list_id;
  useEffect(() => {
    if (!list) return;
    let live = true;
    fetchRankings(list).then((r) => live && setOthers(r.rankings.filter((x) => x.id !== m.id))).catch(() => {});
    return () => { live = false; };
  }, [list, m.id]);
  return others;
}

function Frame({ title, subtitle, onBack, m, catalog, children }: {
  title: string; subtitle?: string; onBack: () => void; m: RankingModel; catalog: Catalog | null; children: (st: RankingState, c: Catalog) => ReactNode;
}) {
  return (
    <LibScreen>
      <Bar title={title} subtitle={subtitle ?? m.row?.name} onBack={onBack} />
      {m.error && <Notice tone="error">{m.error}</Notice>}
      {m.notice && <Notice tone="info">{m.notice}</Notice>}
      {m.state && catalog ? children(m.state, catalog) : !m.error && <Notice tone="info">{catalog ? "Loading the ranking…" : "Loading card data…"}</Notice>}
    </LibScreen>
  );
}

function ProgressBar({ fraction }: { fraction: number }) {
  return (
    <div className="h-[3px] bg-t1-bg">
      <div className={`h-full ${fraction >= 1 ? "bg-t1-accent" : "bg-t1-text"}`} style={{ width: `${Math.max(0, Math.min(1, fraction)) * 100}%` }} />
    </div>
  );
}

function Tile({ title, state, done, fraction, note, children }: { title: string; state: string; done: boolean; fraction: number; note: string; children: ReactNode }) {
  return (
    <div className="bg-t1-surface p-4 flex flex-col gap-2.5">
      <div className="flex items-center justify-between gap-3">
        <span className="text-[15px] font-semibold uppercase tracking-[1.5px]">{title}</span>
        <span className={`t1-label ${done ? "!text-t1-accent" : ""}`}>{state}</span>
      </div>
      <ProgressBar fraction={fraction} />
      <p className="text-[12px] leading-[18px] text-t1-muted">{note}</p>
      <div className="flex gap-px">{children}</div>
    </div>
  );
}

function Btn({ label, onClick, accent, disabled }: { label: string; onClick: () => void; accent?: boolean; disabled?: boolean }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled}
            className={`flex-1 px-4 py-3 text-[11px] uppercase tracking-[1px] ${disabled ? "bg-t1-disabled text-t1-ink"
              : accent ? "bg-t1-accent text-t1-ink" : "bg-t1-bg hover:bg-t1-surface-hover"}`}>{label}</button>
  );
}

function Tabs({ st, shown, all, onSelect }: { st: RankingState; shown: RankJob | null; all?: boolean; onSelect: (j: RankJob | null) => void }) {
  const tab = (key: string, label: string, on: boolean, j: RankJob | null) => (
    <button key={key} type="button" onClick={() => onSelect(j)}
            className={`shrink-0 px-3.5 py-3 text-[11px] uppercase tracking-[1.5px] ${on ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>{label}</button>
  );
  return (
    <div className="shrink-0 flex gap-px overflow-x-auto bg-t1-bg">
      {all && tab("all", "All", shown == null, null)}
      {(["F", ...st.jobs] as RankJob[]).map((j) => tab(j, listTitle(j, st.top), shown === j, j))}
    </div>
  );
}

/* ── one ranking ────────────────────────────────────────────────────── */

export function RankingScreen({ id, onBack, go }: { id: string; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const m = useRanking(id, catalog);
  const others = useOthers(m);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [imaging, setImaging] = useState(false);
  const [newName, setNewName] = useState<string | null>(null);
  const row = m.row;
  return (
    <Frame title={row?.name ?? "Ranking"} subtitle={[row && whose(row), m.cube?.name].filter(Boolean).join(" · ")} onBack={onBack} m={m} catalog={catalog}>
      {(st, c) => (
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          {m.cubeGone && <Notice tone="info">This cube isn't shared with you any more, so only its lists show.</Notice>}
          {row && !row.mine && <Notice tone="info">You're watching {row.by?.display_name ?? "someone"}'s ranking. It updates live as they pick.</Notice>}
          {row?.depth === "half" && <Notice tone="info">This ranking orders only the top half of each color.</Notice>}
          {st.jobs.map((job) => {
            const s = st.session(job), used = st.knowledge.perJob[job] ?? 0, size = st.size(job);
            const note = s.done ? (s.target < size ? `Top ${s.target} of ${size} sorted in ${plural(used, "screen")}.` : `All ${size} sorted in ${plural(used, "screen")}.`)
              : used === 0 ? `${plural(size, "card")} · about ${plural(st.expected(job), "screen")}`
              : `${s.top.length} of the top ${s.target} placed · about ${plural(Math.max(1, st.expected(job) - used), "screen")} to go`;
            return (
              <Tile key={job} title={JOB_TITLE[job]} state={s.done ? "Sorted" : used ? "In progress" : "Not started"} done={s.done}
                    fraction={s.top.length / Math.max(1, s.target)} note={note}>
                {!s.done && <Btn label={m.mine ? (used ? "Continue" : "Start") : "Watch"} accent={m.mine} onClick={() => go(`screen/${job}`)} />}
                <Btn label="List" onClick={() => go(`lists/${job}`)} />
              </Tile>
            );
          })}
          {(() => {
            const s = st.session("F"), used = st.knowledge.perJob.F ?? 0;
            const unsorted = st.jobs.filter((j) => !st.session(j).done).length;
            const note = s.done ? `All ${s.target} places ranked in ${plural(used, "screen")}.`
              : `${s.top.length} of ${s.target} ranked · about ${plural(Math.max(1, st.expected("F") - used), "screen")} left once every color is sorted.` +
                (unsorted ? ` ${unsorted === 1 ? "1 color is" : `${unsorted} colors are`} not fully sorted yet; the final works anyway but will also ask about cards inside ${unsorted === 1 ? "it" : "them"}.` : "");
            return (
              <Tile title={`Final · Top ${s.target}`} state={s.done ? "Complete" : used ? "In progress" : "Not started"} done={s.done}
                    fraction={s.top.length / Math.max(1, s.target)} note={note}>
                {!s.done && <Btn label={m.mine ? (used ? "Continue the final" : "Start the final") : "Watch"} accent={m.mine} onClick={() => go("screen/F")} />}
                <Btn label={`Top ${s.target} list`} onClick={() => go("lists/F")} />
              </Tile>
            );
          })()}
          {(() => {
            const picks = m.picks, disagreed = picks.filter((p) => p.disagreed > 0 || p.won).length;
            return (
              <Tile title="P1P1" state={picks.length ? plural(picks.length, "pick") : ""} done={false} fraction={0}
                    note={!picks.length ? `Refine ${m.mine ? "your" : "this"} ranking: pick one card from a 15-card pack, like the first pick of a draft.`
                      : `${plural(picks.length, "pick")} · ${disagreed ? `${disagreed} disagreed with the ranking` : "all agreed with the ranking"}`}>
                <Btn label={m.mine ? "Open a pack" : "Pick history"} accent={m.mine} onClick={() => go("pack")} />
              </Tile>
            );
          })()}
          <Row title="Changes" detail={m.changes.length ? `${plural(m.changes.length, "change")} so far` : "Every move of every card, as it happens"} onClick={() => go("changes")} />
          <Row title="Compare with another ranking…" detail={others.length ? plural(others.length, "other ranking") : "No other rankings of this cube yet"}
               onClick={() => others.length && setMenu({ title: "Compare with", items: others.map((o) => ({ title: `${o.by?.display_name ?? "Someone"} · ${o.name}`, onClick: () => go(`compare/${o.id}/F`) })) })} />
          <Row title={`Top ${row?.top ?? 100} image`} detail="The final as a picture, to download or share" onClick={() => setImaging(true)} />
          {row?.mine && (<>
            <Section title="Settings" />
            <Field label="Name" value={newName ?? row.name} onChange={setNewName} />
            {newName != null && newName.trim() && newName !== row.name && (
              <Btn label="Rename" accent onClick={() => { void m.update({ name: newName.trim() }); setNewName(null); }} />
            )}
            <Segmented options={[{ value: "half", label: "Top half" }, { value: "full", label: "Every card" }]} value={row.depth} onChange={(d) => void m.update({ depth: d })} />
            <Segmented options={[{ value: 100, label: "Top 100" }, { value: 50, label: "Top 50" }]} value={row.top} onChange={(t) => void m.update({ top: t })} />
            <Segmented options={[{ value: "cube", label: "Shared with the cube" }, { value: "private", label: "Only me" }]} value={row.sharing}
                       onChange={(s) => void m.update({ sharing: s })} />
            <Row title="Delete this ranking" detail="Every pick, on every device" onClick={() => setConfirmDelete(true)} />
          </>)}
          {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
          {confirmDelete && row && (
            <Dialog title={`Delete ${row.name}?`} message="This removes every pick in it, on every device. It can't be undone." cancelLabel="Cancel"
                    confirmLabel="Yes, delete it" tone="danger" onCancel={() => setConfirmDelete(false)}
                    onConfirm={() => void deleteRanking(id).then(onBack).catch((e) => { m.error = (e as Error).message; setConfirmDelete(false); })} />
          )}
          {imaging && <RankingImage m={m} c={c} onClose={() => setImaging(false)} />}
        </div>
      )}
    </Frame>
  );
}

/* ── the picking screen ─────────────────────────────────────────────── */

export function RankingPickScreen({ id, job, onBack, go }: { id: string; job: RankJob; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const m = useRanking(id, catalog);
  const q = m.question(job);
  const key = q ? `${m.log.length}|${q.cards.join(",")}|${q.pinned.join(",")}` : "";
  const [order, setOrder] = useState<number[]>([]);
  const [picked, setPicked] = useState<number | null>(null);
  const [drag, setDrag] = useState<{ x: number; dx: number; dy: number } | null>(null);
  const pinned = useMemo(() => new Set(q?.pinned ?? []), [key]);
  const slots = useRef<(HTMLDivElement | null)[]>([]);
  useEffect(() => { if (q) { setOrder(q.cards); setPicked(null); } }, [key]);

  const move = (x: number, to: number) => setOrder((o) => { const r = o.filter((y) => y !== x); r.splice(Math.min(to, r.length), 0, x); return r; });
  const free = () => order.find((x) => !pinned.has(x));
  const tap = (x: number) => {
    if (!m.mine) return;
    if (picked == null) {
      if (!pinned.has(x)) setPicked(x);
      else { const f = free(); if (f != null) move(f, order.indexOf(x)); }
      return;
    }
    setPicked(null);
    if (picked === x) return;
    if (!pinned.size) setOrder((o) => { const r = o.slice(), i = r.indexOf(picked), j = r.indexOf(x); [r[i], r[j]] = [r[j], r[i]]; return r; });
    else move(picked, order.indexOf(x));
  };
  const lockIn = () => { if (order.length >= 2) m.lockIn(job, order); };

  // Keys: 1–4 picks up the card in that spot, ← → moves it, another number swaps the two, Enter locks in, Z undoes.
  useEffect(() => {
    if (!m.mine || !q || q.session.done) return;
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.tagName === "INPUT") return;
      const n = Number(e.key);
      if (n >= 1 && n <= order.length) { tap(order[n - 1]); e.preventDefault(); }
      else if ((e.key === "ArrowLeft" || e.key === "ArrowRight") && picked != null) {
        const i = order.indexOf(picked), to = e.key === "ArrowLeft" ? i - 1 : i + 1;
        if (to >= 0 && to < order.length && (!pinned.size || !pinned.has(picked))) move(picked, to);
        e.preventDefault();
      } else if (e.key === "Enter") { lockIn(); e.preventDefault(); }
      else if (e.key === "z" || e.key === "Z") { m.undo(job); e.preventDefault(); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const onPointerDown = (x: number) => (e: React.PointerEvent) => {
    if (!m.mine || pinned.has(x)) return;
    const startX = e.clientX, startY = e.clientY;
    let moved = false;
    const el = e.currentTarget as HTMLElement;
    el.setPointerCapture(e.pointerId);
    const onMove = (ev: PointerEvent) => {
      const dx = ev.clientX - startX, dy = ev.clientY - startY;
      if (!moved && Math.hypot(dx, dy) < 6) return;
      moved = true;
      const target = slots.current.findIndex((s) => { const r = s?.getBoundingClientRect(); return !!r && ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom; });
      if (target >= 0) move(x, target);
      setDrag({ x, dx, dy });
    };
    const onUp = () => {
      el.removeEventListener("pointermove", onMove);
      el.removeEventListener("pointerup", onUp);
      el.removeEventListener("pointercancel", onUp);
      setDrag(null);
      if (!moved) tap(x);
    };
    el.addEventListener("pointermove", onMove);
    el.addEventListener("pointerup", onUp);
    el.addEventListener("pointercancel", onUp);
  };

  return (
    <Frame title={job === "F" ? "Final" : JOB_TITLE[job]} onBack={onBack} m={m} catalog={catalog}>
      {(st, c) => {
        if (!q) return null;
        const s = q.session, used = st.knowledge.perJob[job] ?? 0, label = job === "F" ? "Final" : JOB_TITLE[job];
        return (
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <div className="bg-t1-surface p-4 flex flex-col gap-2">
              {!m.mine && <p className="t1-label">Watching {m.row?.by?.display_name ?? "someone"}'s ranking live</p>}
              <div className="flex items-baseline gap-3.5">
                <span className="text-[44px] font-bold text-t1-accent tabular-nums leading-none">{s.done ? "✓" : `#${s.top.length + 1}`}</span>
                <div className="flex flex-col gap-1 min-w-0">
                  <span className="t1-label !text-t1-text">{s.done ? `${label} · done` : `${label} · deciding #${s.top.length + 1} of the top ${s.target}`}</span>
                  <span className="text-[12px] text-t1-muted">{s.top.length} of the top {s.target} ({plural(s.size, "card")}) placed</span>
                  <span className="text-[11px] text-t1-muted">{s.done ? `Done in ${plural(used, "screen")}`
                    : `Screen ${(st.knowledge.screens + 1).toLocaleString()} of this ranking · about ${Math.max(1, st.expected(job) - used)} to go in ${label}`}</span>
                </div>
              </div>
              <ProgressBar fraction={s.top.length / Math.max(1, s.target)} />
            </div>
            {s.done ? (<>
              <Notice tone="info">{job === "F" ? `Top ${s.target} complete. All ${s.target} places are ranked.` : `${label} sorted.`}</Notice>
              <Btn label={job === "F" ? `Top ${s.target} list` : `${label} list`} accent onClick={() => go(`lists/${job}`)} />
              <Btn label="Back to the ranking" onClick={onBack} />
            </>) : (<>
              {m.mine && (pinned.size ? <Notice tone="info">Locked cards keep the order you already gave them. Move the free card to where it belongs.</Notice>
                : !m.log.some((x) => x.s === job) && <Notice tone="info">Drag the cards into order, best in spot 1, then lock it in. You can also click two cards to swap them, or use 1–4, ← →, Enter and Z.</Notice>)}
              <div className="bg-t1-bg p-4 grid grid-cols-2 md:grid-cols-4 gap-3 select-none">
                {order.map((x, i) => {
                  const card = m.cardAt(x), up = picked === x || drag?.x === x;
                  return (
                    <div key={x} ref={(el) => { slots.current[i] = el; }} className="flex flex-col gap-1.5 touch-none"
                         onPointerDown={onPointerDown(x)}
                         style={drag?.x === x ? { transform: `translate(${drag.dx * 0.15}px, ${drag.dy * 0.15}px)`, zIndex: 1 } : undefined}>
                      <div className={`relative ${up ? "outline outline-[3px] outline-t1-text" : ""}`} style={{ borderRadius: 8 }}>
                        <div className="w-full aspect-[488/680] overflow-hidden" style={{ borderRadius: 8 }}>
                          {card?.p != null ? <img src={cardImageUrl(c, card.p, "normal")} alt={card.name} draggable={false} className="w-full h-full object-cover" />
                            : <div className="w-full h-full bg-t1-surface-hover p-2 text-[12px]">{card?.name}</div>}
                        </div>
                        <span className={`absolute left-0 top-0 w-7 h-7 flex items-center justify-center text-[15px] font-bold tabular-nums ${up ? "bg-t1-text text-t1-bg" : "bg-t1-surface"}`}>{i + 1}</span>
                        {pinned.has(x) && <span className="absolute right-0 top-0 w-7 h-7 flex items-center justify-center bg-t1-surface text-[12px]" aria-label="Locked: its order is already known">🔒</span>}
                      </div>
                      <span className="text-[11px] leading-[14px] line-clamp-2 h-7">{card?.name}</span>
                    </div>
                  );
                })}
              </div>
              {m.mine && (
                <div className="flex gap-px">
                  <Btn label="Undo" onClick={() => m.undo(job)} disabled={!m.log.some((x) => x.s === job)} />
                  <Btn label="Lock in" accent onClick={lockIn} />
                </div>
              )}
            </>)}
          </div>
        );
      }}
    </Frame>
  );
}

/* ── lists ──────────────────────────────────────────────────────────── */

export function RankingListsScreen({ id, job, onBack, go }: { id: string; job: RankJob; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const m = useRanking(id, catalog);
  const others = useOthers(m);
  const [tab, setTab] = useState<RankJob>(job);
  const [copied, setCopied] = useState(false);
  const [menu, setMenu] = useState<MenuItem[] | null>(null);
  return (
    <Frame title={listTitle(tab, m.row?.top ?? 100)} onBack={onBack} m={m} catalog={catalog}>
      {(st, c) => {
        const l = m.list(tab);
        if (!l) return null;
        const s = l.session;
        const lede = !s.top.length ? "Nothing ranked yet."
          : tab === "F" ? (s.done ? "Final order, #1 down." : `${s.top.length} of ${s.target} ranked so far, #1 down.`)
          : s.done && s.target < s.size ? `The top ${s.target} of ${s.size}, best first. The other ${s.size - s.target} are below them, in no particular order.`
          : s.done ? `All ${s.size}, best first.` : `${s.top.length} of the top ${s.target} placed so far, best first.`;
        return (<>
          <Tabs st={st} shown={tab} onSelect={(j) => { setTab(j ?? "F"); setCopied(false); }} />
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <Notice tone="info">{lede}</Notice>
            {l.placed.map((card, i) => <CardRow key={card.oracleId} c={c} p={card.p} title={`${i + 1}. ${card.name}`} onClick={() => go(`card/${card.oracleId}/${tab}`)} />)}
            {l.restTitle && <Section title={l.restTitle} />}
            {l.rest.map((card) => <CardRow key={card.oracleId} c={c} p={card.p} title={card.name} onClick={() => go(`card/${card.oracleId}/${tab}`)} />)}
            <div className="flex gap-px">
              <Btn label={copied ? "Copied" : "Copy list"} onClick={() => { void navigator.clipboard.writeText(m.listText(tab)); setCopied(true); capture("ranking_list_copied", { list: tab }); }} />
              <Btn label="Compare…" onClick={() => others.length && setMenu(others.map((o) => ({ title: `${o.by?.display_name ?? "Someone"} · ${o.name}`, onClick: () => go(`compare/${o.id}/${tab}`) })))} />
            </div>
          </div>
          {menu && <Menu title="Compare this list with" items={menu} onClose={() => setMenu(null)} />}
        </>);
      }}
    </Frame>
  );
}

/* ── one card's history ─────────────────────────────────────────────── */

const moveText = (c: RankChange) => (c.f == null && c.to != null ? `#${c.to} new` : c.f != null && c.to == null ? `#${c.f} → out` : `#${c.f} → #${c.to}`);
const causeText = (c: RankChange) => ({ undo: "undo", redo: `redo screen ${c.n ?? 0}`, pick: "P1P1 pick", pick_win: "a pick won", settings: "settings" } as Record<string, string>)[c.by ?? ""]
  ?? (c.n ? `screen ${c.n}` : "screen");

export function RankingCardScreen({ id, oracleId, job, onBack, go }: { id: string; oracleId: string; job: RankJob; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const m = useRanking(id, catalog);
  const [against, setAgainst] = useState<string | null>(null);
  const [menu, setMenu] = useState<MenuItem[] | null>(null);
  const [redo, setRedo] = useState<number | null>(null);
  const card = m.card(oracleId);
  return (
    <Frame title={card?.name ?? "Card"} onBack={onBack} m={m} catalog={catalog}>
      {(st, c) => {
        const x = st.knowledge.index.get(oracleId.toLowerCase());
        if (x == null) return <Notice tone="info">That card isn't in this cube any more.</Notice>;
        const s = st.session(job), fin = st.session("F");
        const where = job === "F" ? `the top ${s.target}` : JOB_TITLE[job];
        const i = s.top.indexOf(x);
        const place = i >= 0 ? `#${i + 1} in ${where}` : s.done ? (job === "F" ? `Not in the top ${s.target}` : `Below the top ${s.target} in ${JOB_TITLE[job]}`)
          : job === "F" ? `Not in the top ${s.target} yet` : `Not placed yet in ${JOB_TITLE[job]}`;
        const me = st.id(x);
        const defaultOther = i > 0 ? st.id(s.top[i - 1]) : i === 0 && s.top.length > 1 ? st.id(s.top[1]) : s.top.length ? st.id(s.top[s.top.length - 1]) : null;
        const other = against ?? defaultOther;
        const up = other ? why(st.knowledge, m.log, me, other) : null;
        const down = other && !up ? why(st.knowledge, m.log, other, me) : null;
        const chain = (links: Link[]) => links.map((l) => (
          <Row key={`${l.winner}|${l.loser}|${l.screen}`} title={`${m.card(l.winner)?.name ?? "?"} above ${m.card(l.loser)?.name ?? "?"}`} detail={`Screen ${l.screen}`} />
        ));
        const changes = m.changes.filter((ch) => ch.c.toLowerCase() === me).reverse();
        const hits = m.log.map((sc, k) => [sc, k] as const).filter(([sc]) => sc.o.some((o) => o.toLowerCase() === me));
        const pickMenu = () => {
          const inTop = new Set(s.top);
          const rest: number[] = [];
          st.knowledge.ids.forEach((id2, k) => { if (k !== x && !inTop.has(k) && (job === "F" || st.category.get(id2) === job)) rest.push(k); });
          rest.sort((a, b) => (m.cardAt(a)?.name ?? "").localeCompare(m.cardAt(b)?.name ?? ""));
          setMenu([...s.top.filter((y) => y !== x), ...rest].slice(0, 150).map((y) => ({
            title: `${s.top.includes(y) ? `#${s.top.indexOf(y) + 1} ` : ""}${m.cardAt(y)?.name ?? ""}`, onClick: () => setAgainst(st.id(y)),
          })));
        };
        return (
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <div className="bg-t1-surface p-4 flex gap-4 items-start">
              <CardArt c={c} p={card?.p ?? null} width={120} alt={card?.name} />
              <div className="flex flex-col gap-1.5">
                <span className="text-[15px]">{place}</span>
                {job !== "F" && fin.top.includes(x) && <span className="t1-label">#{fin.top.indexOf(x) + 1} in the top {fin.target}</span>}
              </div>
            </div>
            <Section title="Why" />
            <Row title={other ? `Against ${m.card(other)?.name ?? "?"}` : "Pick a card to compare"} detail="Change" onClick={pickMenu} />
            {other && (up ? (<><Notice tone="info">{card?.name} is above {m.card(other)?.name}:</Notice>{chain(up)}</>)
              : down ? (<><Notice tone="info">{card?.name} is below {m.card(other)?.name}:</Notice>{chain(down)}</>)
              : <Notice tone="info">No screen has settled these two yet, directly or through other cards.</Notice>)}
            {changes.length > 0 && (<>
              <Section title="Rank changes" count={changes.length} />
              {changes.map((ch, k) => <Row key={k} title={`${listTitle(ch.s, st.top)}: ${moveText(ch)}`}
                                           detail={[causeText(ch), ch.t ? new Date(ch.t).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : null].filter(Boolean).join(" · ")} />)}
            </>)}
            <Section title="Screens with this card" count={hits.length} />
            {!hits.length && <Notice tone="info">It has not been on a screen yet.</Notice>}
            {hits.map(([sc, k]) => (
              <div key={k} className="bg-t1-surface px-4 py-3 flex items-start gap-3">
                <div className="flex-1 min-w-0 flex flex-col gap-1">
                  <span className="t1-label">Screen {k + 1} · {sc.s === "P" ? "P1P1 pick (first card picked)" : sc.s === "F" ? "Final" : JOB_TITLE[sc.s]}</span>
                  <span className="text-[13px] leading-[18px] whitespace-pre-line">
                    {sc.s === "P" ? `Picked ${m.card(sc.o[0])?.name ?? "?"} over ${sc.o.slice(1).map((o) => m.card(o)?.name ?? "?").join(", ")}`
                      : sc.o.map((o, n) => `${n + 1}. ${m.card(o)?.name ?? "?"}`).join("\n")}
                  </span>
                </div>
                {m.mine && <button type="button" className="t1-label !text-t1-text px-2 py-1" onClick={() => setRedo(k)}>Redo</button>}
              </div>
            ))}
            {menu && <Menu title="Compare with" items={menu} onClose={() => setMenu(null)} />}
            {redo != null && (() => {
              const sc = m.log[redo];
              const nothing = m.redoChangesNothing(redo);
              return (
                <Dialog title={`Remove screen ${redo + 1}?`} cancelLabel="Cancel" confirmLabel="Remove and re-ask" tone="danger"
                        message={nothing ? "Removing it changes nothing: other screens settle every order it did."
                          : sc?.s === "P" ? "The pick comes out of the ranking."
                          : `It comes out of the ranking and ${sc?.s === "F" ? "the final" : JOB_TITLE[sc?.s ?? "F"]} asks about those cards again.`}
                        onCancel={() => setRedo(null)}
                        onConfirm={() => { const j = sc?.s; m.redo(redo); setRedo(null); if (j && j !== "P") go(`screen/${j}`); }} />
              );
            })()}
          </div>
        );
      }}
    </Frame>
  );
}

/* ── compare ────────────────────────────────────────────────────────── */

export function RankingCompareScreen({ id, otherId, job, onBack, go }: { id: string; otherId: string; job: RankJob; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const [a, setA] = useState(id), [b, setB] = useState(otherId);
  const [tab, setTab] = useState<RankJob>(job);
  const ma = useRanking(a, catalog, false), mb = useRanking(b, catalog, false);
  const [all, setAll] = useState<RankingRow[]>([]);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  useEffect(() => { if (ma.row?.list_id) fetchRankings(ma.row.list_id).then((r) => setAll(r.rankings)).catch(() => {}); }, [ma.row?.list_id]);
  useEffect(() => { capture("ranking_compared", { list: tab }); }, [a, b, tab]);
  const [brief, setBrief] = useState<RankingBrief | null>(null);
  const [briefError, setBriefError] = useState<string | null>(null);
  const [briefTry, setBriefTry] = useState(0);
  const ready0 = !!(ma.state && mb.state);
  useEffect(() => {
    if (!ready0) return;
    let live = true;
    setBrief(null); setBriefError(null);
    fetchBrief(a, b, tab).then((r) => live && setBrief(r)).catch((e) => live && setBriefError((e as Error).message));
    return () => { live = false; };
  }, [a, b, tab, briefTry, ready0]);
  const label = (r: RankingRow | null) => (r?.mine ? "You" : r?.by?.display_name ?? "Someone");
  const picker = (title: string, r: RankingRow | null, set: (id: string) => void) => (
    <button type="button" className="flex-1 bg-t1-surface hover:bg-t1-surface-hover p-3 text-left flex flex-col gap-0.5"
            onClick={() => setMenu({ title, items: all.map((o) => ({ title: `${label(o)} · ${o.name}`, onClick: () => set(o.id) })) })}>
      <span className="t1-label">{title}</span>
      <span className="text-[13px]">{label(r)} · {r?.name}</span>
    </button>
  );
  const ready = ma.state && mb.state && catalog;
  return (
    <LibScreen>
      <Bar title="Compare" subtitle={listTitle(tab, ma.row?.top ?? 100)} onBack={onBack} />
      {(ma.error || mb.error) && <Notice tone="error">{ma.error ?? mb.error}</Notice>}
      {!ready ? <Notice tone="info">Loading both rankings…</Notice> : (() => {
        const sa = ma.state!, sb = mb.state!, c = catalog!;
        const tb = sb.session(tab);
        const translated: Pick<RankSession, "top" | "done" | "size"> = { top: tb.top.map((x) => sa.knowledge.index.get(sb.id(x))).filter((x): x is number => x != null), done: tb.done, size: tb.size };
        const cmp = compare(sa.knowledge, sa.session(tab), translated, sa.scope(tab));
        const na = label(ma.row), nb = label(mb.row);
        const side = (n: string, p: number, out: boolean) => (out ? `${n}: below the top ${p - 1}` : `${n} #${p}`);
        const gapRow = (g: (typeof cmp.biggest)[number]) => {
          const card = ma.card(g.card);
          return <CardRow key={g.card} c={c} p={card?.p ?? null} title={card?.name ?? "?"} detail={`${side(na, g.a, g.aOut)} · ${side(nb, g.b, g.bOut)}`}
                          value={`${g.atLeast ? "≥" : ""}${g.gap} ${g.gap === 1 ? "place" : "places"}`} onClick={() => go(`card/${g.card}/${tab}`)} />;
        };
        return (<>
          <Tabs st={sa} shown={tab} onSelect={(j) => setTab(j ?? "F")} />
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <div className="flex gap-px">
              {picker("Ranking", ma.row, setA)}
              <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover px-3.5 t1-label !text-t1-text" onClick={() => { setA(b); setB(a); }}>Swap</button>
              {picker("Compared with", mb.row, setB)}
            </div>
            <Section title="In brief" />
            {brief?.brief ? (
              <div className="bg-t1-surface px-4 py-4 flex flex-col gap-2">
                <p className="text-[13px] leading-[20px]">{brief.brief}</p>
                <span className="t1-label">{brief.sample ? "Demo sample" : "Written by Claude from both rankings"}</span>
              </div>
            ) : brief?.reason ? <Notice tone="info">{brief.reason}</Notice>
              : briefError ? <Row title="No brief yet" detail={`${briefError} Tap to try again.`} onClick={() => setBriefTry((n) => n + 1)} />
              : <Notice tone="info">Writing a brief…</Notice>}
            {!cmp.compared ? <Notice tone="info">Nothing to compare yet: these two rankings have no {tab === "F" ? "cards" : `${JOB_TITLE[tab].toLowerCase()} cards`} placed in common.</Notice> : (<>
              <Section title={tab === "F" ? "Biggest differences" : `${JOB_TITLE[tab]}: biggest differences`} />
              <Notice tone="info">
                Comparing {plural(cmp.compared, tab === "F" ? "card" : `${JOB_TITLE[tab].toLowerCase()} card`)} both rankings have placed. On average they sit {cmp.atLeast ? "at least " : ""}
                {Math.floor(cmp.avgTenths / 10)}.{cmp.avgTenths % 10} places apart; these {cmp.biggest.length} differ the most.
                {tab !== "F" && (ma.row?.depth === "half" || mb.row?.depth === "half") && " A ranking that sorts only the top half puts a card below its cut at the first place past it, so its gap is at least what's shown."}
              </Notice>
              {cmp.biggest.map(gapRow)}
              {cmp.oneSide.length > 0 && (<>
                <Section title={tab === "F" ? `In one top ${sa.top}, not the other` : "In one top half, not the other"} />
                <Notice tone="info">{plural(cmp.oneSide.length, "card")} {cmp.oneSide.length === 1 ? "is" : "are"} in one ranking's list but below the other's cut.</Notice>
                {cmp.oneSide.map(gapRow)}
              </>)}
            </>)}
          </div>
        </>);
      })()}
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
    </LibScreen>
  );
}

/* ── P1P1 ───────────────────────────────────────────────────────────── */

export function RankingPackScreen({ id, onBack, go }: { id: string; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const m = useRanking(id, catalog);
  const [pack, setPack] = useState<string[]>([]);
  const [picked, setPicked] = useState<string | null>(null);
  const [verdict, setVerdict] = useState<{ kind: "disagree"; picked: string; above: string[]; removals: number } | { kind: "saved"; text: string } | null>(null);
  useEffect(() => { if (m.state && !pack.length) setPack(m.pack); }, [m.state]);
  const placeOf = (cid: string) => {
    const st = m.state, x = st?.knowledge.index.get(cid.toLowerCase());
    if (!st || x == null) return "not ranked";
    const f = st.session("F").top.indexOf(x);
    if (f >= 0) return `#${f + 1} in the top ${st.top}`;
    const job = st.category.get(cid.toLowerCase());
    const k = job ? st.session(job).top.indexOf(x) : -1;
    return k >= 0 && job ? `#${k + 1} in ${JOB_TITLE[job]}` : "not placed yet";
  };
  const save = (p: string, wins: boolean) => {
    const disagreed = m.disagreements(p, pack).length, settles = m.newOrders(p, pack);
    m.pick(p, pack, wins);
    const name = m.card(p)?.name ?? "That pick";
    setVerdict({ kind: "saved", text: disagreed ? (wins ? `${name} now sits above the rest of that pack. Saved.` : "Kept your ranking; the rest of the pick is saved.")
      : settles ? `${name}: this pick settles ${plural(settles, "order")} your ranking hadn't. Saved.` : `${name} agrees with your ranking. Saved.` });
  };
  const pick = () => {
    if (!picked) return;
    const above = m.disagreements(picked, pack);
    if (!above.length) save(picked, false);
    else setVerdict({ kind: "disagree", picked, above, removals: m.pickWinRemovals(picked, pack).length });
  };
  const history = (c: Catalog) => m.picks.length > 0 && (<>
    <Section title="Pick history" count={m.picks.length} />
    {m.picks.map((p) => {
      const card = m.card(p.screen.o[0]);
      return <CardRow key={p.index} c={c} p={card?.p ?? null} title={card?.name ?? "?"} onClick={() => go(`card/${p.screen.o[0]}/F`)}
                      detail={`Screen ${p.index + 1} · ${p.won ? "won over your ranking" : p.disagreed ? `disagreed with ${plural(p.disagreed, "card")}, ranking kept` : "agreed"} · ${placeOf(p.screen.o[0])}`} />;
    })}
  </>);
  return (
    <Frame title={m.row && !m.mine ? "Pick history" : "P1P1"} onBack={onBack} m={m} catalog={catalog}>
      {(_, c) => !m.mine ? (
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          {!m.picks.length && <Notice tone="info">No P1P1 picks yet.</Notice>}
          {history(c)}
        </div>
      ) : (
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          {verdict?.kind === "disagree" ? (<>
            <Section title="Your ranking disagrees" />
            <Notice tone="info">You picked {m.card(verdict.picked)?.name} ({placeOf(verdict.picked)}), but your ranking puts {verdict.above.length === 1 ? "this card" : `these ${verdict.above.length} cards`} above it:</Notice>
            {verdict.above.map((cid) => <CardRow key={cid} c={c} p={m.card(cid)?.p ?? null} title={m.card(cid)?.name ?? "?"} detail={placeOf(cid)} />)}
            <div className="flex gap-px">
              <Btn label="Keep my ranking" onClick={() => save(verdict.picked, false)} />
              <Btn label="Let the pick win" accent onClick={() => save(verdict.picked, true)} />
            </div>
            <Notice tone="info">{verdict.removals ? `Letting the pick win takes out ${plural(verdict.removals, "screen")} behind that order; those cards are asked about again.`
                                                  : "Letting the pick win changes nothing else."}</Notice>
          </>) : verdict?.kind === "saved" ? (<>
            <Notice tone="info">{verdict.text}</Notice>
            <Btn label="Next pack" accent onClick={() => { setVerdict(null); setPicked(null); setPack(m.pack); }} />
          </>) : <Notice tone="info">Pick the card you'd take first from this pack. Each pick refines your ranking: the card you take counts as better than the other {Math.max(0, pack.length - 1)}.</Notice>}
          <div className="bg-t1-bg p-4 grid grid-cols-3 md:grid-cols-5 gap-2">
            {pack.map((cid) => {
              const card = m.card(cid);
              const flagged = verdict?.kind === "disagree" && (verdict.picked === cid || verdict.above.includes(cid));
              return (
                <button key={cid} type="button" aria-pressed={picked === cid} aria-label={card?.name} onClick={() => !verdict && setPicked(cid)}
                        className={`block ${picked === cid ? "outline outline-[3px] outline-t1-accent" : flagged ? "outline outline-[3px] outline-t1-warning" : ""}`}
                        style={{ borderRadius: 8 }}>
                  {card?.p != null ? <img src={cardImageUrl(c, card.p, "normal")} alt={card.name} className="w-full aspect-[488/680] object-cover" style={{ borderRadius: 8 }} />
                    : <span className="block w-full aspect-[488/680] bg-t1-surface-hover p-2 text-[11px] text-left">{card?.name}</span>}
                </button>
              );
            })}
          </div>
          {!verdict && <Btn label={picked ? `Pick ${m.card(picked)?.name ?? ""}` : "Click a card to pick it"} accent={!!picked} disabled={!picked} onClick={pick} />}
          {history(c)}
        </div>
      )}
    </Frame>
  );
}

/* ── change log ─────────────────────────────────────────────────────── */

export function RankingChangesScreen({ id, onBack, go }: { id: string; onBack: () => void; go: (path: string) => void }) {
  const { catalog } = useCatalog();
  const m = useRanking(id, catalog);
  const [filter, setFilter] = useState<RankJob | null>(null);
  useEffect(() => { capture("ranking_changes_opened"); }, []);
  return (
    <Frame title="Changes" onBack={onBack} m={m} catalog={catalog}>
      {(st, c) => {
        const rows = m.changes.map((ch, k) => [ch, k] as const).filter(([ch]) => !filter || ch.s === filter).reverse().slice(0, 2000);
        const days = new Map<string, (typeof rows)[number][]>();
        for (const r of rows) {
          const d = r[0].t ? new Date(r[0].t).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" }) : "Earlier";
          if (!days.has(d)) days.set(d, []);
          days.get(d)!.push(r);
        }
        return (<>
          <Tabs st={st} shown={filter} all onSelect={setFilter} />
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            {!rows.length && <Notice tone="info">Nothing has moved yet.</Notice>}
            {[...days].map(([d, list]) => (
              <div key={d} className="flex flex-col gap-px">
                <Section title={d} />
                {list.map(([ch, k]) => {
                  const card = m.card(ch.c);
                  return <CardRow key={k} c={c} p={card?.p ?? null} title={card?.name ?? "?"} detail={`${listTitle(ch.s, st.top)} · ${causeText(ch)}`}
                                  value={moveText(ch)} onClick={() => go(`card/${ch.c}/${ch.s}`)} />;
                })}
              </div>
            ))}
          </div>
        </>);
      }}
    </Frame>
  );
}

/* ── the top 100 as a picture ───────────────────────────────────────── */

function loadImage(url: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = url;
  });
}

/** Piles of ten in rank order, each card over the one above so only its name bar shows (the last in a pile whole). */
function drawTop(cards: RankCard[], c: Catalog, art: Map<number, HTMLImageElement>, title: string, byline: string, font: string) {
  const CW = 168, CH = Math.round(CW * 680 / 488), PEEK = 26, GAP = 14, PAD = 32, PER = 10, HEAD = 90, SCALE = 2;
  const piles = Math.max(1, Math.ceil(cards.length / PER));
  const W = PAD * 2 + piles * (CW + GAP) - GAP, H = PAD + HEAD + 24 + (PER - 1) * PEEK + CH + PAD;
  const cv = document.createElement("canvas");
  cv.width = W * SCALE; cv.height = H * SCALE;
  const g = cv.getContext("2d")!;
  g.scale(SCALE, SCALE);
  g.fillStyle = "#171725"; g.fillRect(0, 0, W, H);
  g.fillStyle = "#ffffff"; g.font = `bold 30px ${font}`; g.fillText(title, PAD, PAD + 28, W - PAD * 2 - 140);
  g.fillStyle = "#c4c4ca"; g.font = `14px ${font}`; g.fillText(byline, PAD, PAD + 56, W - PAD * 2 - 140);
  g.font = `11px ${font}`; g.textAlign = "right"; g.fillText("TABLE-1.SITE", W - PAD, PAD + 20); g.textAlign = "left";
  cards.forEach((card, i) => {
    const pile = Math.floor(i / PER), k = i % PER;
    const x = PAD + pile * (CW + GAP), y = PAD + HEAD + 24 + k * PEEK;
    if (k === 0) { g.fillStyle = "#c4c4ca"; g.font = `12px ${font}`; g.fillText(`#${i + 1}–${Math.min(i + PER, cards.length)}`, x, PAD + HEAD + 12); }
    const r = CW * (card.p != null ? cornerRatio(c.pSet[card.p]) : 0.0432);
    g.save();
    g.beginPath(); g.roundRect(x, y, CW, CH, r); g.clip();
    const img = card.p != null ? art.get(card.p) : undefined;
    if (img) g.drawImage(img, x, y, CW, CH);
    else { g.fillStyle = "#33334a"; g.fillRect(x, y, CW, CH); g.fillStyle = "#ffffff"; g.font = `11px ${font}`; g.fillText(card.name, x + 8, y + 16, CW - 40); }
    g.restore();
    g.fillStyle = "#ffffff"; g.fillRect(x + CW - 26, y + 4, 24, 18);
    g.fillStyle = "#171725"; g.font = `bold 11px ${font}`; g.textAlign = "center"; g.fillText(String(i + 1), x + CW - 14, y + 17); g.textAlign = "left";
  });
  return cv;
}

function RankingImage({ m, c, onClose }: { m: RankingModel; c: Catalog; onClose: () => void }) {
  const [url, setUrl] = useState<string | null>(null);
  const [progress, setProgress] = useState<[number, number]>([0, 0]);
  const [note, setNote] = useState<string | null>(null);
  const blob = useRef<Blob | null>(null);
  const cards = useMemo(() => (m.state ? m.state.session("F").top.map((x) => m.cardAt(x)).filter((x): x is RankCard => !!x) : []), [m.version]);
  const name = m.row?.name ?? "Top 100";
  useEffect(() => {
    if (!cards.length) return;
    let live = true;
    const ps = [...new Set(cards.map((x) => x.p).filter((p): p is number => p != null))];
    let done = 0;
    setProgress([0, ps.length]);
    void Promise.all(ps.map(async (p) => { const img = await loadImage(cardImageUrl(c, p, "normal")); if (live) setProgress([++done, ps.length]); return [p, img] as const; }))
      .then((all) => {
        if (!live) return;
        const art = new Map<number, HTMLImageElement>();
        for (const [p, img] of all) if (img) art.set(p, img);
        if (art.size < ps.length) setNote(`${ps.length - art.size} card images couldn't be loaded; their names show instead.`);
        const row = m.row;
        const partial = m.state?.session("F").done ? null : `${cards.length} of ${row?.top ?? 100} ranked so far`;
        const byline = [row ? `${row.mine ? "Your ranking" : `${row.by?.display_name ?? "Someone"}'s ranking`} of ${m.cube?.name ?? "a cube"}` : null, partial,
                        "Ranked on Table 1", new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" })].filter(Boolean).join(" · ");
        const cv = drawTop(cards, c, art, name, byline, getComputedStyle(document.body).fontFamily || "ui-monospace, monospace");
        cv.toBlob((b) => { if (!live || !b) return; blob.current = b; setUrl(URL.createObjectURL(b)); }, "image/jpeg", 0.9);
      });
    return () => { live = false; };
  }, [cards]);
  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);
  const download = () => {
    if (!url) return;
    const a = document.createElement("a");
    a.href = url; a.download = fileName(name); a.click();
    setNote(`Downloaded ${fileName(name)}.`);
    capture("ranking_image", { how: "download" });
  };
  const share = async () => {
    if (!blob.current) return;
    const f = new File([blob.current], fileName(name), { type: "image/jpeg" });
    try {
      if (navigator.canShare?.({ files: [f] })) { await navigator.share({ files: [f], title: name }); capture("ranking_image", { how: "share" }); return; }
      download();
    } catch (e) {
      if ((e as Error)?.name !== "AbortError") setNote("Couldn't share here. Download it instead.");
    }
  };
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={`Top ${m.row?.top ?? 100} image`}>
      <Bar title={`Top ${m.row?.top ?? 100} image`} subtitle={name} onBack={onClose} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {note && <Notice tone="info">{note}</Notice>}
        {!cards.length ? <Notice tone="info">Nothing ranked in the final yet.</Notice>
          : url ? <img src={url} alt={`Top ${cards.length} of ${name}`} className="w-full h-auto block" />
          : <Notice tone="info">Getting card images… {progress[0]} of {progress[1]}</Notice>}
      </div>
      <div className="shrink-0 flex gap-px pb-px">
        <Btn label="Download" accent disabled={!url} onClick={download} />
        <Btn label="Share" disabled={!url} onClick={() => void share()} />
      </div>
    </div>
  );
}

export { rankingModel };

/** Dev demo (`?demo`): rankings of the fixture's cube, built once the card data and demo lists are in. Signed in: as is. */
export function RankingsDemoGate({ children }: { children: ReactNode }) {
  const { demo } = useLibrarySession();
  const { catalog } = useCatalog();
  const { lists } = useListsData();
  const [, setReady] = useState(0);
  useEffect(() => {
    if (!demo || rankingsDemo() || !catalog || !lists.ready) return;
    const cube = lists.lists.find((l) => l.kind === "cube");
    if (!cube) return;
    startRankingsDemo(catalog, { id: cube.id, name: cube.name, cardIds: entriesOf(cube).filter((e) => e.board === "main").map((e) => e.cardId) });
    setReady((n) => n + 1);
  }, [demo, catalog, lists.ready]);
  if (demo && !rankingsDemo()) return <LibScreen><Bar title="Rankings" /><Notice tone="info">Setting up the demo rankings…</Notice></LibScreen>;
  return <>{children}</>;
}
