// Sideboard guide screens (contract/sideboard-guide-2026-11-04.md § Screens): the guide, a matchup, the In and Out
// pickers, the sideboard and Considering, new matchup, and the print preview. Same as iOS SideboardGuideViews.swift
// and Android SideboardGuideScreens.kt.
import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Field, Menu, Modal, Notice, Row, Section, type MenuItem } from "../components/kit";
import { coverPrinting, formatName, searchCatalog, type Catalog } from "../lib/catalog";
import { isLibraryDemo } from "../lib/libraryDemo";
import { boardTitle, editList, setListGuide, type CardList } from "../lib/lists";
import { loadInsights, loadInsightsDemo, useInsights } from "../lib/insights";
import {
  MAX_MATCHUPS, MAX_NAME, MAX_NOTES, check, guideHtml, issueText, matchupName, overSideboard, pool, printDate, printModel, qtyOf,
  setQty, uses, warningText, type Copies, type GuideLine, type Matchup, type Side, type SideboardGuide,
} from "../lib/sideboardGuide";
import { capture } from "../lib/telemetry";
import { CardRow, Icon, ICON, LibScreen, useCatalog } from "./Library";
import { resolveLines, useListsData, type Line } from "./Lists";

export type GuidePage = { page: "guide" } | { page: "new" } | { page: "print" } | { page: "pool" }
  | { page: "matchup"; id: string } | { page: "pick"; id: string; side: Side };

const ruleLines = (lines: Line[]): GuideLine[] =>
  lines.filter((l) => l.oracleId).map((l) => ({ oracle: l.oracleId!, name: l.name, board: l.board, qty: l.qty }));

function edit(list: CardList, change: (g: SideboardGuide) => SideboardGuide) {
  setListGuide(list.id, change(list.guide ?? { matchups: [] }));
}
function editMatchup(list: CardList, id: string, change: (m: Matchup) => Matchup) {
  edit(list, (g) => ({ matchups: g.matchups.map((m) => (m.id === id ? change(m) : m)) }));
}

const iconButton = "w-[50px] h-[50px] -my-3 flex items-center justify-center hover:text-t1-accent";

export function SideboardGuideScreen({ id, at, go, onBack }: { id: string; at: GuidePage; go: (path: string, replace?: boolean) => void; onBack: () => void }) {
  const { lists: { lists, error } } = useListsData();
  const { catalog } = useCatalog();
  const list = lists.find((l) => l.id === id);
  const lines = useMemo(() => (list && catalog ? resolveLines(list.versions[list.versions.length - 1].entries, list.kind, catalog) : []), [list, catalog]);
  const opened = useRef(false);
  useEffect(() => {
    if (at.page !== "guide" || !list || opened.current) return;
    opened.current = true;
    capture("sideboard_guide_opened", { matchups: list.guide?.matchups.length ?? 0 });
  }, [at.page, list]);
  if (!list) return <LibScreen><Bar title="Sideboard guide" onBack={onBack} /><Notice tone="error">That deck isn't here anymore.</Notice></LibScreen>;
  const body = (() => {
    switch (at.page) {
      case "guide": return <Guide list={list} lines={lines} go={go} onBack={onBack} />;
      case "new": return <NewMatchup list={list} go={go} onBack={onBack} />;
      case "print": return <Print list={list} lines={lines} onBack={onBack} />;
      case "pool": return <Pool list={list} lines={lines} catalog={catalog} onBack={onBack} />;
      case "matchup": return <MatchupScreen list={list} id={at.id} lines={lines} catalog={catalog} go={go} onBack={onBack} />;
      case "pick": return <Pick list={list} id={at.id} side={at.side} lines={lines} catalog={catalog} onBack={onBack} />;
    }
  })();
  return <LibScreen>{body}{error && <Notice tone="error">{error}</Notice>}</LibScreen>;
}

function Guide({ list, lines, go, onBack }: { list: CardList; lines: Line[]; go: (p: string) => void; onBack: () => void }) {
  const rl = ruleLines(lines);
  const ms = list.guide?.matchups ?? [];
  const over = overSideboard(rl, list.format);
  const count = (b: string) => lines.filter((l) => l.board === b).reduce((n, l) => n + l.qty, 0);
  const add = () => { if (ms.length < MAX_MATCHUPS) go("new"); };
  return (
    <>
      <Bar title="Sideboard guide" onBack={onBack} right={<span className="flex">
        <button type="button" aria-label="New matchup" className={iconButton} onClick={add}><Icon d={ICON.plus} /></button>
        {ms.length > 0 && <button type="button" aria-label="Print" className={iconButton} onClick={() => go("print")}><Icon d={ICON.print} /></button>}
      </span>} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {over != null && <Notice tone="error">The sideboard has {over} cards: Constructed allows 15.</Notice>}
        <Row title="Sideboard" detail={`Sideboard ${count("side")} · considering ${count("maybe")}`} onClick={() => go("pool")} />
        {ms.length > 0 && <Section title="Matchups" count={ms.length} />}
        {ms.map((m) => {
          const c = check(m, rl, list.format);
          return <Row key={m.id} title={m.name} detail={c.label} value={lines.length && c.issues.length ? <span className="t1-label !text-t1-error">Check</span> : undefined}
                      onClick={() => go(`m/${m.id}`)} />;
        })}
        {!ms.length && <Row title="New matchup" value={<Icon d={ICON.plus} />} onClick={add} />}
      </div>
    </>
  );
}

function NewMatchup({ list, go, onBack }: { list: CardList; go: (p: string, replace?: boolean) => void; onBack: () => void }) {
  const [name, setName] = useState("");
  const { constructed } = useInsights();
  useEffect(() => { void (isLibraryDemo() ? loadInsightsDemo() : loadInsights()); }, []);
  const taken = new Set((list.guide?.matchups ?? []).map((m) => m.name.toLowerCase()));
  const pack = constructed[list.format];
  const view = pack?.tiers[pack.default_tier];
  const options = (view?.windows["30"]?.share ?? []).filter((r) => r.a !== 0).slice().sort((a, b) => b.share - a.share).slice(0, 30)
    .map((r) => ({ id: r.a, name: pack!.archetypes.find((a) => a.id === r.a)?.name ?? "Other", share: `${(r.share * 100).toFixed(1)}%` }))
    .filter((a) => !taken.has(a.name.toLowerCase()));
  const add = (n: string, archetype: number | null) => {
    const id = crypto.randomUUID();
    edit(list, (g) => ({ matchups: [...g.matchups, { id, name: n, archetype, in: [], out: [], notes: "" }] }));
    capture("sideboard_matchup_added", { from: archetype == null ? "typed" : "archetype" });
    go(`m/${id}`, true);
  };
  return (
    <>
      <Bar title="New matchup" onBack={onBack} />
      <Field label="Name" value={name} onChange={(v) => setName(v.slice(0, MAX_NAME))} autoFocus />
      <BigAction label="Add" disabled={!matchupName(name)} onClick={() => add(matchupName(name), null)} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {options.length > 0 && <Section title={`${formatName(list.format)} meta`} />}
        {options.map((a) => <Row key={a.id} title={a.name} detail={a.share} onClick={() => add(a.name, a.id)} />)}
      </div>
    </>
  );
}

function MatchupScreen({ list, id, lines, catalog, go, onBack }: { list: CardList; id: string; lines: Line[]; catalog: Catalog | null; go: (p: string) => void; onBack: () => void }) {
  const ms = list.guide?.matchups ?? [];
  const i = ms.findIndex((m) => m.id === id);
  const m = ms[i];
  const [menu, setMenu] = useState(false);
  const [renaming, setRenaming] = useState<string | null>(null);
  const [notes, setNotes] = useState(m?.notes ?? "");
  useEffect(() => { setNotes(m?.notes ?? ""); }, [m?.id]);
  if (!m) return <><Bar title="Matchup" onBack={onBack} /><Notice tone="error">That matchup isn't in the guide anymore.</Notice></>;
  const rl = ruleLines(lines);
  const p = pool(rl);
  const c = check(m, rl, list.format);
  const move = (by: number) => edit(list, (g) => {
    const out = g.matchups.slice();
    const [x] = out.splice(i, 1);
    out.splice(Math.max(0, Math.min(out.length, i + by)), 0, x);
    return { matchups: out };
  });
  const items: MenuItem[] = [
    { title: "Rename", onClick: () => setRenaming(m.name) },
    ...(i > 0 ? [{ title: "Move up", onClick: () => move(-1) }] : []),
    ...(i < ms.length - 1 ? [{ title: "Move down", onClick: () => move(1) }] : []),
    { title: "Delete matchup", onClick: () => { edit(list, (g) => ({ matchups: g.matchups.filter((x) => x.id !== m.id) })); onBack(); } },
  ];
  const plan = (side: Side) => {
    const cards = m[side];
    if (!cards.length) return <Row title="—" />;
    return cards.map(([o, q]) => {
      const line = lines.find((l) => l.oracleId === o && (side === "out" ? l.board === "main" : l.board !== "main")) ?? lines.find((l) => l.oracleId === o);
      const fromMaybe = side === "in" && (p.get(o)?.side ?? 0) < q;
      return catalog
        ? <CardRow key={o} c={catalog} p={line?.p ?? null} title={p.get(o)?.name ?? line?.name ?? "Card"} detail={fromMaybe ? "Considering" : undefined}
                   value={`${side === "in" ? "+" : "−"}${q}`} onClick={() => go(`m/${m.id}/${side}`)} />
        : <Row key={o} title={p.get(o)?.name ?? "Card"} value={`${side === "in" ? "+" : "−"}${q}`} />;
    });
  };
  return (
    <>
      <Bar title={m.name} onBack={onBack} right={<button type="button" className="t1-label hover:text-t1-text px-2 py-1 -my-1" onClick={() => setMenu(true)}>Edit</button>} />
      <div className="grid grid-cols-2 gap-px">
        <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover h-[50px] t1-label !text-t1-text" onClick={() => go(`m/${m.id}/in`)}>In {c.in}</button>
        <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover h-[50px] t1-label !text-t1-text" onClick={() => go(`m/${m.id}/out`)}>Out {c.out}</button>
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {lines.length > 0 && c.issues.map((x, k) => <Notice key={k} tone="error">{issueText(x, p)}</Notice>)}
        <Section title="In" count={c.in} />
        {plan("in")}
        <Section title="Out" count={c.out} />
        {plan("out")}
        <Section title={`Notes · ${notes.length}/${MAX_NOTES}`} />
        <textarea value={notes} placeholder="Add notes" rows={6} maxLength={MAX_NOTES}
                  onChange={(e) => { setNotes(e.target.value); editMatchup(list, m.id, (x) => ({ ...x, notes: e.target.value.trim() })); }}
                  className="bg-t1-surface px-4 py-3 text-[14px] leading-6 text-t1-text placeholder:text-t1-muted outline-0 resize-none" />
      </div>
      {menu && <Menu title={m.name} items={items} onClose={() => setMenu(false)} />}
      {renaming != null && (
        <Modal title="Rename matchup" onClose={() => setRenaming(null)}>
          <Field label="Name" value={renaming} onChange={(v) => setRenaming(v.slice(0, MAX_NAME))} autoFocus />
          <BigAction label="Save" disabled={!matchupName(renaming)} onClick={() => {
            editMatchup(list, m.id, (x) => ({ ...x, name: matchupName(renaming) }));
            setRenaming(null);
          }} />
        </Modal>
      )}
    </>
  );
}

/** "SIDEBOARD 2 · CONSIDERING 1", "CONSIDERING 1" or "MAIN 4". */
export function copiesLabel(c: Copies, side: Side): string {
  return side === "out" ? `Main ${c.main}` : [c.side ? `Sideboard ${c.side}` : null, c.maybe ? `Considering ${c.maybe}` : null].filter(Boolean).join(" · ");
}

function Pick({ list, id, side, lines, catalog, onBack }: { list: CardList; id: string; side: Side; lines: Line[]; catalog: Catalog | null; onBack: () => void }) {
  const m = list.guide?.matchups.find((x) => x.id === id);
  const [q, setQ] = useState("");
  const p = pool(ruleLines(lines));
  const cards = useMemo(() => {
    const seen = new Set<string>();
    return lines.filter((l) => l.oracleId && !seen.has(l.oracleId) && seen.add(l.oracleId)).map((l) => ({ o: l.oracleId!, line: l, c: p.get(l.oracleId!)! }));
  }, [lines]);
  const hits = useMemo(() => (catalog && side === "in" && q.trim() ? searchCatalog(catalog, q, 12) : []), [catalog, q, side]);
  if (!m) return <><Bar title={side === "in" ? "In" : "Out"} onBack={onBack} /><Notice tone="error">That matchup isn't in the guide anymore.</Notice></>;
  const step = (o: string, n: number) => editMatchup(list, m.id, (x) => setQty(x, o, n, side));
  const consider = (oi: number) => {
    if (!catalog) return;
    const o = catalog.oId[oi];
    const have = qtyOf(m, o, "in");
    const c = p.get(o);
    if ((c?.side ?? 0) + (c?.maybe ?? 0) <= have) void editList(list.id, [{ card_id: catalog.pId[coverPrinting(catalog, oi)], board: "maybe", delta: 1 }]);
    step(o, have + 1);
    capture("sideboard_card_considered");
    setQ("");
  };
  const group = (title: string, rows: typeof cards, count: number, max: (c: Copies) => number) => !rows.length ? null : (
    <>
      <Section title={title} count={count} />
      {rows.map(({ o, line, c }) => {
        const n = qtyOf(m, o, side);
        const btn = "w-14 self-stretch bg-t1-surface-hover text-[20px] disabled:text-t1-disabled";
        return (
          <div key={o} className="flex gap-px items-stretch">
            <div className="flex-1 min-w-0">
              {catalog ? <CardRow c={catalog} p={line.p} title={c.name} detail={copiesLabel(c, side)} value={n ? `${side === "in" ? "+" : "−"}${n}` : "0"} />
                : <Row title={c.name} detail={copiesLabel(c, side)} value={n} />}
            </div>
            <button type="button" aria-label={`One fewer ${c.name}`} className={btn} disabled={n <= 0} onClick={() => step(o, n - 1)}>−</button>
            <button type="button" aria-label={`One more ${c.name}`} className={btn} disabled={n >= max(c)} onClick={() => step(o, n + 1)}>+</button>
          </div>
        );
      })}
    </>
  );
  const total = (side === "in" ? m.in : m.out).reduce((n, [, x]) => n + x, 0);
  const side_ = cards.filter((x) => x.c.side > 0), maybe = cards.filter((x) => !x.c.side && x.c.maybe > 0), main = cards.filter((x) => x.c.main > 0);
  return (
    <>
      <Bar title={`${side === "in" ? "In" : "Out"} · ${total}`} onBack={onBack} />
      {side === "in" && <Field label="Add a card to consider" value={q} onChange={setQ} placeholder="Card name" />}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {side === "in" && q.trim() ? hits.map((oi) => <Row key={oi} title={catalog!.oName[oi]} detail={catalog!.oType[oi]} value={<Icon d={ICON.plus} />} onClick={() => consider(oi)} />)
          : side === "in" ? <>
            {group("Sideboard", side_, side_.reduce((n, x) => n + x.c.side, 0), (c) => c.side + c.maybe)}
            {group("Considering", maybe, maybe.reduce((n, x) => n + x.c.maybe, 0), (c) => c.maybe)}
          </> : group("Main deck", main, main.reduce((n, x) => n + x.c.main, 0), (c) => c.main)}
      </div>
    </>
  );
}

function Pool({ list, lines, catalog, onBack }: { list: CardList; lines: Line[]; catalog: Catalog | null; onBack: () => void }) {
  const u = list.guide ? uses(list.guide) : {};
  const [menu, setMenu] = useState<Line | null>(null);
  return (
    <>
      <Bar title="Sideboard" onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {(["side", "maybe"] as const).map((board) => {
          const rows = lines.filter((l) => l.board === board);
          return (
            <div key={board} className="flex flex-col gap-px">
              <Section title={boardTitle(list.kind, board, list.format)} count={rows.reduce((n, l) => n + l.qty, 0)} />
              {!rows.length && <Row title="—" />}
              {rows.map((l) => {
                const n = (l.oracleId && u[l.oracleId]) || 0;
                const detail = n ? `In ${n} ${n === 1 ? "matchup" : "matchups"}` : "In no matchups";
                return catalog ? <CardRow key={`${l.cardId}|${l.finish}|${l.lang}|${l.cond}`} c={catalog} p={l.p} title={l.name} detail={detail} value={l.qty} onClick={() => setMenu(l)} />
                  : <Row key={l.cardId} title={l.name} detail={detail} value={l.qty} />;
              })}
            </div>
          );
        })}
      </div>
      {menu && (() => {
        const to = menu.board === "side" ? "maybe" : "side";
        const at = { card_id: menu.cardId, finish: menu.finish, lang: menu.lang, cond: menu.cond };
        return <Menu title={menu.name} onClose={() => setMenu(null)} items={[
          { title: `Move one to ${boardTitle(list.kind, to, list.format)}`, onClick: () => void editList(list.id, [{ ...at, board: menu.board, delta: -1 }, { ...at, board: to, delta: 1 }]) },
          { title: `Move all to ${boardTitle(list.kind, to, list.format)}`, onClick: () => void editList(list.id, [{ ...at, from: menu.board, to }]) },
        ]} />;
      })()}
    </>
  );
}

function Print({ list, lines, onBack }: { list: CardList; lines: Line[]; onBack: () => void }) {
  const r = useMemo(() => (list.guide ? printModel(list.name, formatName(list.format), printDate(), ruleLines(lines), list.guide, list.format) : null),
                    [list, lines]);
  const frame = useRef<HTMLIFrameElement>(null);
  if (!r) return <><Bar title="Print" onBack={onBack} /><Notice tone="info">No matchups yet.</Notice></>;
  const html = guideHtml(r.model);
  const print = () => {
    capture("sideboard_guide_printed", { matchups: r.model.matchups.length, left_considering: r.warnings.find((w) => w.code === "considering")?.qty ?? 0, sheets: r.sheets });
    frame.current?.contentWindow?.print();
  };
  return (
    <>
      <Bar title="Print" onBack={onBack} />
      {r.warnings.map((w) => <Notice key={w.code} tone="error">{warningText(w)}</Notice>)}
      <div className="flex-1 min-h-0 bg-white p-4">
        <iframe ref={frame} title={`${list.name} sideboard guide`} srcDoc={html} className="w-full h-full border-0 bg-white" />
      </div>
      <BigAction label="Print" onClick={print} />
    </>
  );
}
