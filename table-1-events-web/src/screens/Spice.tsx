import { useEffect, useState } from "react";
import { Notice, Row, Section } from "../components/kit";
import { capture, screen } from "../lib/telemetry";
import {
  loadSpice, spiceBasis, spiceCardDetail, spiceCardTitle, spiceCubes, spiceFailed, spiceHeadline, spiceMissingDetail, spiceOf,
  spiceReason, spiceViewed, useSpice, type SpiceDemoCard, type SpiceResult,
} from "../lib/spice";

/* Spice (contract/spice-2026-10-28.md): the section on the Stats screen and, on a shared deck or cube, a Spice row
   that opens the same section in place. Same as iOS Spice.swift. */

/** Score and word, what it was compared with, the spiciest cards, stock cards you don't play. */
export function SpiceSection({ listId, kind, format, onCard }: {
  listId: string; kind: "deck" | "cube"; format: string; onCard?: (oracleId: string) => void;
}) {
  useSpice();
  const [all, setAll] = useState(false);
  const [open] = useState(() => Math.random().toString(36).slice(2));
  const r = spiceOf(listId);
  useEffect(() => { if (r) spiceViewed(r, listId, open, format); }, [r, listId, open, format]);
  const opened = (res: SpiceResult, section: string, id: string) => {
    capture("spice_card_opened", { kind: res.kind, section });
    if (!id.startsWith("demo-")) onCard?.(id);
  };
  const headline = r && spiceHeadline(r);
  return (
    <>
      <Section title="Spice" />
      {!r ? (spiceFailed(listId) ? <Notice tone="info">Spice isn't available right now</Notice>
                                 : <div className="bg-t1-surface px-4 py-4 t1-label">Reading spice…</div>)
        : !headline ? <Notice tone="info">{spiceReason(r)}</Notice>
        : (<>
          <div className="bg-t1-surface px-4 py-[14px] flex flex-col gap-1.5">
            <div className="text-[24px] uppercase tracking-[0.1em] text-t1-accent font-mono">{headline}</div>
            <div className="text-[12px] leading-[18px] text-t1-muted">{spiceBasis(r)}</div>
            {spiceCubes(r).map((line) => <div key={line} className="text-[12px] text-t1-muted">{line}</div>)}
          </div>
          {r.cards.length > 0 && (<>
            <Section title="Spiciest cards" />
            {(all ? r.cards : r.cards.slice(0, 8)).map((c) => (
              <Row key={`${c.section}|${c.c}`} title={spiceCardTitle(c)} detail={spiceCardDetail(c, r)}
                   onClick={onCard ? () => opened(r, c.section, c.c) : undefined} />
            ))}
            {r.cards.length > 8 && !all && <Row title={`Show all ${r.cards.length}`} onClick={() => setAll(true)} />}
          </>)}
          {r.stock_missing.length > 0 && (<>
            <Section title="Stock cards you don't play" />
            {r.stock_missing.map((m) => (
              <Row key={m.c} title={m.n} detail={spiceMissingDetail(m, r)} onClick={onCard ? () => opened(r, "missing", m.c) : undefined} />
            ))}
          </>)}
        </>)}
      {r && <SpiceScreenLog kind={kind} />}
    </>
  );
}

/** deck_spice / cube_spice once the section is drawn. */
function SpiceScreenLog({ kind }: { kind: "deck" | "cube" }) {
  useEffect(() => { screen(kind === "cube" ? "cube_spice" : "deck_spice"); }, [kind]);
  return null;
}

/** A shared deck or cube: a Spice row with the score, opening the section in place. */
export function SpiceRow({ listId, token, kind, format, name, demo, onCard }: {
  listId: string; token?: string | null; kind: "deck" | "cube"; format: string; name: string; demo: SpiceDemoCard[]; onCard?: (oracleId: string) => void;
}) {
  useSpice();
  const [open, setOpen] = useState(false);
  useEffect(() => { void loadSpice(listId, "shared", { token, kind, format, demo, name }); }, [listId, token, kind, format]); // eslint-disable-line react-hooks/exhaustive-deps
  const r = spiceOf(listId);
  const detail = r ? spiceHeadline(r) ?? spiceReason(r) : spiceFailed(listId) ? "Not available" : "Reading spice…";
  return (<>
    <Row title="Spice" detail={detail ?? undefined} onClick={() => setOpen((o) => !o)} />
    {open && <SpiceSection listId={listId} kind={kind} format={format} onCard={onCard} />}
  </>);
}
