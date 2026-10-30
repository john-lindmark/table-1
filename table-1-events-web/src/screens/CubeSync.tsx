// Sync with Cube Cobra (contract/cube-sync-2026-10-30.md): reads the cube on Cube Cobra again, shows what's in, out and
// in a new printing or finish, and on Accept saves it as one new version. Same flow as iOS and Android.
import { useEffect, useRef, useState } from "react";
import { Bar, BigAction, Field, Notice, Row, Section } from "../components/kit";
import type { Catalog } from "../lib/catalog";
import { DEMO_USER } from "../lib/collection";
import { cubeCobraId, cubeSyncDiff, syncCounts, syncIsEmpty, syncSummary, type SyncResult } from "../lib/cubeSync";
import { entriesOf, finishOf, syncList, type CardList, type Entry } from "../lib/lists";
import { supabase } from "../lib/supabaseClient";
import { capture } from "../lib/telemetry";
import { resolveImport } from "./ListImport";
import { CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";
import { useListsData } from "./Lists";

interface ImportLine { qty: number; board: string; name: string; set?: string; cn?: string; scryfall_id?: string; finish?: string }
interface Imported { name: string; source_url: string; entries: ImportLine[] }
interface Checked { source: string; name: string; cards: number; seq?: number; result: SyncResult; missing: string[] }

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** The cube with its third Main card foil, the fourth in another printing, the first two gone, and two cards from a
 *  deck added (`?demo`). */
export function demoAnswer(c: Catalog, list: CardList, lists: CardList[]): Imported {
  const cur = entriesOf(list);
  let main = cur.filter((e) => e.board === "main");
  const rest = cur.filter((e) => e.board !== "main");
  const line = (e: Entry, card: string, finish: string): ImportLine =>
    ({ qty: e.qty, board: e.board, name: "Demo card", scryfall_id: card, ...(finish !== "nonfoil" ? { finish } : {}) });
  const lines: ImportLine[] = [];
  if (main.length > 4) {
    const [, , third, fourth] = main;
    lines.push(line(third, third.cardId, "foil"));
    const p = c.printingIndex.get(fourth.cardId);
    let other = fourth.cardId;
    if (p !== undefined) {
      const o = c.pOracle[p];
      for (let i = c.pFirst[o]; i < c.pFirst[o] + c.pCount[o]; i++) if (c.pId[i] !== fourth.cardId) { other = c.pId[i]; break; }
    }
    lines.push(line(fourth, other, finishOf(fourth)));
    main = main.slice(4);
  }
  lines.push(...[...main, ...rest].map((e) => line(e, e.cardId, finishOf(e))));
  const have = new Set(cur.map((e) => e.cardId));
  const deck = lists.find((l) => l.kind === "deck");
  for (const e of (deck ? entriesOf(deck) : []).filter((e) => e.board === "main" && !have.has(e.cardId)).slice(0, 2)) {
    lines.push({ qty: 1, board: "main", name: "Demo card", scryfall_id: e.cardId });
  }
  return { name: "Demo cube", source_url: "https://cubecobra.com/cube/list/demo", entries: lines };
}

export function CubeSyncScreen({ id, onBack, onCard }: { id: string; onBack: () => void; onCard: (oracleId: string) => void }) {
  const { lists: { lists } } = useListsData();
  const { userId } = useLibrarySession();
  const { catalog } = useCatalog();
  const list = lists.find((l) => l.id === id);
  const [link, setLink] = useState("");
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [conflict, setConflict] = useState(false);
  const [checked, setChecked] = useState<Checked | null>(null);
  const started = useRef(false);
  const demo = userId === DEMO_USER;

  const check = async (url: string) => {
    if (!catalog || !list) return;
    const u = /^https?:\/\//i.test(url.trim()) ? url.trim() : `https://${url.trim()}`;
    if (!cubeCobraId(u)) return setError("That isn't a Cube Cobra cube link.");
    setBusy(true);
    setError(null);
    setConflict(false);
    const fresh = lists.find((l) => l.id === id) ?? list;
    try {
      let r: Imported;
      if (demo) r = demoAnswer(catalog, fresh, lists);
      else {
        const { data, error: e } = await supabase.functions.invoke("list-import", { body: { url: u } });
        if (e) {
          const body = await (e as { context?: Response }).context?.json?.().catch(() => null);
          setAsking(true);
          capture("cube_sync_failed", { reason: "read" });
          return setError(body?.error ?? "Cube Cobra couldn't be read.");
        }
        r = data as Imported;
      }
      const resolved = resolveImport(catalog, r.entries ?? [], "cube");
      const result = cubeSyncDiff(entriesOf(fresh), resolved.entries, (cardId) => {
        const p = catalog.printingIndex.get(cardId);
        return p === undefined ? undefined : { oracle: String(catalog.pOracle[p]), lang: catalog.pLang[p] };
      });
      const out: Checked = { source: r.source_url || u, name: r.name ?? "", seq: fresh.seq, result, missing: resolved.missing,
                             cards: (r.entries ?? []).filter((l) => l.board === "main").reduce((n, l) => n + l.qty, 0) };
      setChecked(out);
      setAsking(false);
      const n = syncCounts(result);
      capture("cube_sync_checked", { in: n.in, out: n.out, changed: n.changed, same: result.same, missing: resolved.missing.length,
                                     known_link: !!fresh.sourceUrl });
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    if (started.current || !catalog || !list) return;
    started.current = true;
    if (list.sourceUrl) {
      setLink(list.sourceUrl);
      void check(list.sourceUrl);
    } else setAsking(true);
  }, [catalog, list?.id]);

  const accept = async (c: Checked) => {
    setBusy(true);
    try {
      await syncList(id, c.seq, c.result.entries, c.source);
      const n = syncCounts(c.result);
      capture("cube_sync_accepted", n);
      onBack();
    } catch (e) {
      const code = (e as { code?: string })?.code;
      if (code === "PT409") {
        setConflict(true);
        setError("This cube changed since you checked. Check again.");
        capture("cube_sync_failed", { reason: "conflict" });
      } else {
        setError((e as { message?: string })?.message ?? "The cube couldn't be saved.");
        capture("cube_sync_failed", { reason: "save" });
      }
    } finally {
      setBusy(false);
    }
  };

  const row = (p: number | undefined, detail: (string | null | false)[], value: string, warn = false, key?: string) => {
    const pi = p ?? null;
    return (
      <div key={key} className="h-[60px]">
        <CardRow c={catalog!} p={pi} title={pi !== null ? catalog!.oName[catalog!.pOracle[pi]] : "…"} value={value} warn={warn}
                 detail={detail.filter(Boolean).join(" · ")}
                 onClick={pi !== null ? () => onCard(catalog!.oId[catalog!.pOracle[pi]]) : undefined} />
      </div>
    );
  };
  const setLabel = (p: number | undefined) => (p === undefined || !catalog ? "?" : `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}`);

  const r = checked?.result;
  return (
    <LibScreen>
      <Bar title="Sync with Cube Cobra" subtitle={list?.name} onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!catalog && <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>}
        {!list && <Row title="This cube isn't here any more" />}
        {list && catalog && asking && (
          <>
            <Field label="Cube Cobra link" value={link} onChange={setLink} autoFocus />
            <Notice tone="info">Paste the cube's link from Cube Cobra. Table 1 remembers it for next time.</Notice>
            <BigAction label={busy ? "Reading Cube Cobra…" : "Check"} busy={busy} onClick={() => void check(link)} disabled={busy || !link.trim()} />
          </>
        )}
        {list && catalog && !asking && !checked && started.current &&
          <Row title="Reading Cube Cobra…" detail={cubeCobraId(link) ? `cubecobra.com · ${cubeCobraId(link)}` : undefined} />}
        {list && catalog && !asking && checked && r && (
          <>
            <Row title={syncSummary(r)} detail={`Cube Cobra · ${checked.name} · ${checked.cards} cards`} />
            {checked.missing.length > 0 && (
              <Notice tone="error">
                Not in the card data, left out: {checked.missing.slice(0, 12).join(", ")}{checked.missing.length > 12 ? ` and ${checked.missing.length - 12} more` : ""}
              </Notice>
            )}
            {conflict
              ? <BigAction label={busy ? "Reading Cube Cobra…" : "Check again"} busy={busy} onClick={() => void check(checked.source)} disabled={busy} />
              : !syncIsEmpty(r) && <BigAction label={busy ? "Saving…" : "Accept changes"} busy={busy} onClick={() => void accept(checked)} disabled={busy} />}
            <Row title={syncIsEmpty(r) ? "Back to the cube" : "Keep as it is"} onClick={onBack} />
            <Row title="Change link" detail={cubeCobraId(checked.source) ? `cubecobra.com · ${cubeCobraId(checked.source)}` : undefined}
                 onClick={() => { setAsking(true); setChecked(null); setError(null); setConflict(false); }} />
            {r.in.length > 0 && <Section title="In" count={syncCounts(r).in} />}
            {r.in.map((l) => row(catalog.printingIndex.get(l.card),
              [setLabel(catalog.printingIndex.get(l.card)), l.finish !== "nonfoil" && cap(l.finish), l.lang !== "en" && l.lang.toUpperCase(), l.board === "maybe" && "Considering"],
              `+${l.qty}`, false, `in|${l.board}|${l.card}|${l.finish}|${l.lang}`))}
            {r.out.length > 0 && <Section title="Out" count={syncCounts(r).out} />}
            {r.out.map((l) => row(catalog.printingIndex.get(l.card),
              [setLabel(catalog.printingIndex.get(l.card)), l.finish !== "nonfoil" && cap(l.finish), l.lang !== "en" && l.lang.toUpperCase(), l.board === "maybe" && "Considering"],
              `−${l.qty}`, true, `out|${l.board}|${l.card}|${l.finish}|${l.lang}`))}
            {r.changed.length > 0 && <Section title="New printing or finish" count={syncCounts(r).changed} />}
            {r.changed.map((ch) => {
              const from = catalog.printingIndex.get(ch.from_card), to = catalog.printingIndex.get(ch.to_card);
              const finish = ch.from_finish === "nonfoil" && ch.to_finish === "nonfoil" ? null
                : `${ch.from_finish === ch.to_finish ? "" : `${cap(ch.from_finish)} → `}${cap(ch.to_finish)}`;
              const sets = ch.from_card === ch.to_card ? setLabel(to) : `${setLabel(from)} → ${setLabel(to)}`;
              return row(to, [sets, finish, ch.to_lang !== "en" && ch.to_lang.toUpperCase(), ch.board === "maybe" && "Considering"], String(ch.qty), false,
                         `ch|${ch.board}|${ch.from_card}|${ch.from_finish}|${ch.from_lang}|${ch.to_card}|${ch.to_finish}`);
            })}
          </>
        )}
      </div>
    </LibScreen>
  );
}
