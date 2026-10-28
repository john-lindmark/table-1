import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, Notice, Row, Section, Segmented, Stepper } from "../components/kit";
import { LEGALITY_FORMATS, formatName, tokenIndexes, type Catalog } from "../lib/catalog";
import {
  BUCKETS, COLOR_GROUPS, SampleHand, StatsRng, TYPES, asfan, asfanLabels, averageMV, colorBalance, curve, curveByColor, deckOf,
  drawsByTurn, expand, hypergeometric, isLand, legality, pipTotals, price, sources, statCard, tokens, typeCounts, type AsfanBy,
  type StatCard,
} from "../lib/deckStats";
import { entriesOf, finishOf, type CardList, type ListFinish } from "../lib/lists";
import { usdPrice, usePrices } from "../lib/prices";
import { capture } from "../lib/telemetry";
import { CardArt, LibScreen, useCatalog } from "./Library";
import { useListsData } from "./Lists";
import { loadSpice, spiceOf, spiceSummary, useSpice, type SpiceDemoCard } from "../lib/spice";
import { SpiceSection } from "./Spice";

/* Deck and cube stats, one tap below the list (contract/lists-2026-10-15.md, "Stats"). The list screen shows a
   one-line summary (ListStatsRow); the Stats screen has the detail, and the sample hand, draw odds and sample pack
   are each one more tap. Same screens as iOS ListStats.swift; all math is in lib/deckStats.ts. */

/** A list line read for stats, with the printing to draw it. */
interface StatLine {
  card: StatCard;
  cardId: string;
  finish: ListFinish;
  p: number;
}

/** The list's lines with catalog data and prices; lines the pack doesn't know are left out. */
function statLines(l: CardList, c: Catalog): StatLine[] {
  const out: StatLine[] = [];
  for (const e of entriesOf(l)) {
    const p = c.printingIndex.get(e.cardId);
    if (p == null) continue;
    const oi = c.pOracle[p];
    const finish = finishOf(e);
    out.push({
      card: statCard({ name: c.oName[oi], qty: e.qty, board: e.board, type: c.oType[oi], cost: c.oCost[oi], cmc: c.oCmc[oi], colors: c.oColors[oi],
                       legal: c.oLegal[oi], rarity: c.pRarity[p], usd: usdPrice(e.cardId, finish), produced: c.oProduced[oi],
                       tokens: tokenIndexes(c, oi).map((t) => ({ key: c.oId[t], name: c.oName[t], type: c.oType[t] })) }),
      cardId: e.cardId, finish, p,
    });
  }
  return out;
}

/** The list, the catalog and its stat lines, re-read when prices arrive. */
function useStatLines(id: string) {
  const { session, ready, lists } = useListsData();
  const { catalog, error } = useCatalog();
  const list = lists.lists.find((l) => l.id === id) ?? null;
  const ids = useMemo(() => (list ? entriesOf(list).map((e) => e.cardId) : null), [list]);
  const priceVersion = usePrices(ids);
  const lines = useMemo(() => (list && catalog ? statLines(list, catalog) : null), [list, catalog, priceVersion]);
  return { session, ready, listsReady: lists.ready, list, catalog, error: error ?? lists.error, lines };
}

/** Asks for the list's spice once its cards are read, and again whenever they change. */
function useLoadSpice(list: CardList | null, c: Catalog | null) {
  const key = useMemo(() => (list ? entriesOf(list).map((e) => `${e.board}|${e.cardId}|${e.qty}`).join(",") : ""), [list]);
  useEffect(() => {
    if (!list || !c) return;
    const demo: SpiceDemoCard[] = [];
    for (const e of entriesOf(list)) {
      const p = c.printingIndex.get(e.cardId);
      if (p == null) continue;
      const oi = c.pOracle[p];
      demo.push({ oracleId: c.oId[oi], name: c.oName[oi], qty: e.qty, board: e.board, basic: c.oType[oi].startsWith("Basic") });
    }
    void loadSpice(list.id, key, { kind: list.kind, format: list.format, demo, name: list.name });
  }, [list?.id, key, !!c]); // eslint-disable-line react-hooks/exhaustive-deps
}

const pct = (x: number) => `${(x * 100).toFixed(1)}%`;
const dec = (x: number) => x.toFixed(2);
const usd = (n: number) => new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(n);
const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
const qtyOf = (cards: StatCard[]) => cards.reduce((n, c) => n + c.qty, 0);

/** The screen frame every stats page shares: bar, errors, loading. */
function StatsFrame({ title, subtitle, onBack, state, children }: {
  title: string; subtitle?: string; onBack: () => void; state: ReturnType<typeof useStatLines>; children: (lines: StatLine[], list: CardList, c: Catalog) => React.ReactNode;
}) {
  const { ready, session, list, catalog, lines, error, listsReady } = state;
  return (
    <LibScreen>
      <Bar title={title} subtitle={subtitle ?? list?.name} onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      {!ready ? <div className="flex-1" />
        : !session ? <Notice tone="info">Sign in to keep decks and cubes.</Notice>
        : !list ? <Notice tone="info">{listsReady ? "That list isn't here anymore." : "Loading…"}</Notice>
        : !catalog || !lines ? <div className="bg-t1-surface px-4 py-4 t1-label">Loading card data…</div>
        : children(lines, list, catalog)}
    </LibScreen>
  );
}

/* ── the summary row on the list screen ──────────────────────────────── */

export function ListStatsRow({ list, catalog, onOpen }: { list: CardList; catalog: Catalog; onOpen: () => void }) {
  const ids = useMemo(() => entriesOf(list).map((e) => e.cardId), [list]);
  const v = usePrices(ids);
  const cards = useMemo(() => statLines(list, catalog).map((l) => l.card), [list, catalog, v]);
  useSpice();
  useLoadSpice(list, catalog);
  if (!cards.length) return null;
  let detail: string;
  if (list.kind === "cube") {
    const b = colorBalance(cards.filter((c) => c.board === "main"));
    detail = ["W", "U", "B", "R", "G", "M", "C", "L"].map((k, i) => (b[i] ? `${k} ${b[i]}` : null)).filter(Boolean).join(" · ");
  } else {
    const lands = qtyOf(deckOf(cards).filter(isLand));
    const p = price(cards);
    detail = [`${lands} lands`, `avg MV ${dec(averageMV(cards, false))}`, p.total > 0 ? usd(p.total) : null].filter(Boolean).join(" · ");
  }
  const spice = spiceOf(list.id);
  const tail = spice && spiceSummary(spice);
  return <Row title="Stats" detail={[detail, tail].filter(Boolean).join(" · ")} onClick={onOpen} />;
}

/* ── shared pieces ───────────────────────────────────────────────────── */

function Cells({ cells }: { cells: [string, string][] }) {
  return (
    <div className="flex gap-px">
      {cells.map(([label, value]) => (
        <div key={label} className="flex-1 min-w-0 bg-t1-surface py-3.5 flex flex-col items-center gap-0.5">
          <span className="t1-label">{label}</span>
          <span className="text-[20px] tabular-nums truncate">{value}</span>
        </div>
      ))}
    </div>
  );
}

/** A plain table on the hairline grid: header row, then rows; the first column takes the rest of the width. */
function Table({ header, rows, cell = 72 }: { header: string[]; rows: string[][]; cell?: number }) {
  const line = (cells: string[], label: boolean, key: string) => (
    <div key={key} className="flex gap-px">
      {cells.map((x, i) => (
        <span key={i} className={`bg-t1-surface ${label ? "t1-label py-2" : "text-[13px] tabular-nums py-3"} ${i === 0 ? "flex-1 min-w-0 pl-4 pr-2 truncate" : "shrink-0 text-right pr-2"}`}
              style={i === 0 ? undefined : { width: cell }}>
          {x}
        </span>
      ))}
    </div>
  );
  return <div className="flex flex-col gap-px">{line(header, true, "h")}{rows.map((r, i) => line(r, false, String(i)))}</div>;
}

/** Stacked bars per mana value: creatures solid, other spells muted. Drawn in divs, no chart library. */
function CurveBars({ creatures, other }: { creatures: number[]; other: number[] }) {
  const top = Math.max(1, ...creatures.map((c, i) => c + other[i]));
  const H = 120;
  return (
    <div className="flex flex-col gap-px">
      <div className="flex gap-px items-stretch">
        {BUCKETS.map((b, i) => {
          const total = creatures[i] + other[i];
          return (
            <div key={b} className="flex-1 bg-t1-surface px-1.5 pt-2 flex flex-col justify-end" style={{ height: H + 30 }}>
              <span className="text-[12px] tabular-nums text-center pb-1">{total || ""}</span>
              <div className="bg-t1-muted" style={{ height: (H * other[i]) / top }} />
              <div className="bg-t1-text" style={{ height: (H * creatures[i]) / top }} />
            </div>
          );
        })}
      </div>
      <div className="flex gap-px">{BUCKETS.map((b) => <span key={b} className="flex-1 bg-t1-surface t1-label text-center py-2">{b}</span>)}</div>
      <div className="bg-t1-surface px-4 py-2.5 flex gap-4 t1-label">
        <span className="flex items-center gap-1.5"><span className="inline-block w-2.5 h-2.5 bg-t1-text" />Creatures {sum(creatures)}</span>
        <span className="flex items-center gap-1.5"><span className="inline-block w-2.5 h-2.5 bg-t1-muted" />Other spells {sum(other)}</span>
      </div>
    </div>
  );
}

/** A text-only button; disabled is a flat fill, never dimmed. */
function StatsButton({ children, onClick, disabled }: { children: React.ReactNode; onClick: () => void; disabled?: boolean }) {
  return (
    <button type="button" onClick={onClick} disabled={disabled}
            className={`flex-1 py-4 t1-label ${disabled ? "bg-t1-disabled !text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover !text-t1-text"}`}>
      {children}
    </button>
  );
}

/** A grid of whole cards that fills the width, three or more across. */
function CardGrid({ c, items, onClick }: { c: Catalog; items: { key: string; p: number; name: string; tag?: string }[]; onClick?: (i: number) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(390);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const cols = Math.max(3, Math.floor(width / 180));
  const tile = Math.floor((width - (cols - 1)) / cols);
  return (
    <div ref={ref} className="flex-1 min-h-0 overflow-y-auto">
      <div className="grid gap-px" style={{ gridTemplateColumns: `repeat(${cols}, ${tile}px)` }}>
        {items.map((it, i) => (
          <button key={it.key} type="button" className="relative block" style={{ width: tile }} onClick={() => onClick?.(i)} aria-label={it.name}>
            <CardArt c={c} p={it.p} width={tile} alt={it.name} />
            {it.tag && (
              <span className="absolute t1-label !text-t1-bg bg-t1-text px-1.5 py-0.5" style={{ left: Math.round(tile * 0.05), bottom: Math.round(tile * 0.05) }}>
                {it.tag}
              </span>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}

/* ── the Stats screen ────────────────────────────────────────────────── */

const CHECKED = [...LEGALITY_FORMATS, "canlander"];

export function ListStatsScreen({ id, onBack, onHand, onOdds, onPack, onCard }: {
  id: string; onBack: () => void; onHand: () => void; onOdds: () => void; onPack: () => void; onCard?: (oracleId: string) => void;
}) {
  const state = useStatLines(id);
  useLoadSpice(state.list, state.catalog);
  return (
    <StatsFrame title="Stats" onBack={onBack} state={state}>
      {(lines, list) => (
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          {list.kind === "deck"
            ? <DeckStats list={list} cards={lines.map((l) => l.card)} onHand={onHand} onOdds={onOdds} onCard={onCard} />
            : (<>
              <SpiceSection listId={list.id} kind="cube" format={list.format} onCard={onCard} />
              <CubeStats cards={lines.map((l) => l.card).filter((c) => c.board === "main")} onPack={onPack} />
            </>)}
        </div>
      )}
    </StatsFrame>
  );
}

function DeckStats({ list, cards, onHand, onOdds, onCard }: {
  list: CardList; cards: StatCard[]; onHand: () => void; onOdds: () => void; onCard?: (oracleId: string) => void;
}) {
  const deck = deckOf(cards);
  const size = qtyOf(deck);
  const lands = qtyOf(deck.filter(isLand));
  const cv = curve(cards);
  const types = typeCounts(deck);
  const pips = pipTotals(cards);
  const src = sources(cards);
  const pipSum = Math.max(1, sum(pips));
  const olderPack = deck.some((c) => c.produced == null);
  const made = tokens(cards);
  // The deck's colors; a fetch land's other land type (Bloodstained Mire in Boros) isn't one.
  const shown = [0, 1, 2, 3, 4].filter((i) => (sum(pips) > 0 ? pips[i] > 0 : src.colors[i] > 0));
  const p = price(cards);
  const issues = CHECKED.includes(list.format) ? legality(cards, list.format) : null;
  const others = CHECKED.filter((f) => f !== list.format).map((f) => [f === "canlander" ? "Canlander" : formatName(f), legality(cards, f).length] as const);
  return (
    <>
      <Cells cells={[["Cards", String(size)], ["Lands", String(lands)], ["Spells", String(size - lands)], ["Avg MV", dec(averageMV(cards, false))]]} />

      <SpiceSection listId={list.id} kind="deck" format={list.format} onCard={onCard} />

      <Section title="Mana curve · spells by mana value" />
      <CurveBars creatures={cv.creatures} other={cv.other} />

      <Section title="Types" />
      {TYPES.map((t, i) => (types[i] ? <Row key={t} title={t} value={types[i]} /> : null))}
      <Row title="Average mana value" detail={`With lands ${dec(averageMV(cards, true))} · without ${dec(averageMV(cards, false))}`} />
      {sum(types) > size && <Notice tone="info">A card counts once for each of its types: an artifact creature is in both.</Notice>}

      <Section title="Colors · pips in costs vs sources" />
      {shown.length === 0 ? <Row title="Colorless" detail="No colored mana symbols or colored sources" /> : (
        <Table header={["Color", "Pips", "Share", "Sources", "Share"]}
               rows={shown.map((i) => [COLOR_GROUPS[i], String(pips[i]), pct(pips[i] / pipSum), String(src.colors[i]), pct(src.colors[i] / Math.max(1, src.sources))])} />
      )}
      <Row title="Mana sources" value={src.sources}
           detail={["Lands and permanents that make mana", ...(src.nonLand ? [`${src.nonLand} not lands`] : []),
                    ...(src.colorless ? [`${src.colorless} colorless`] : [])].join(" · ")} />
      {src.unread > 0 && (
        <Notice tone="info">
          {olderPack
            ? `Card data is still updating, so lands count by their basic land types: ${src.unread} land${src.unread === 1 ? "" : "s"} without one (fetch or utility lands) ${src.unread === 1 ? "isn't" : "aren't"} counted.`
            : `${src.unread} land${src.unread === 1 ? " makes" : "s make"} no mana and ${src.unread === 1 ? "isn't" : "aren't"} counted.`}
        </Notice>
      )}

      <Section title={`Legality · ${formatName(list.format)}`} />
      {issues == null ? <Row title="Not checked" detail={`${formatName(list.format)} has no legality list`} />
        : issues.length === 0 ? <Row title={`Legal in ${formatName(list.format)}`} detail="Main deck and sideboard" value="LEGAL" accentValue />
        : issues.map((x) => <Row key={x.name} title={x.name} value={<span className="t1-label !text-t1-error">{x.reason}</span>} />)}
      <div className="grid grid-cols-4 gap-px">
        {others.map(([name, n]) => (
          <div key={name} className="bg-t1-surface py-2.5 flex flex-col items-center gap-0.5 min-w-0">
            <span className="t1-label truncate max-w-full">{name}</span>
            <span className={`text-[12px] ${n === 0 ? "" : "text-t1-muted"}`}>{n === 0 ? "Legal" : `${n} card${n === 1 ? "" : "s"}`}</span>
          </div>
        ))}
      </div>

      <Section title="Tokens" />
      {made.length === 0
        ? <Row title="None" detail={cards.some((c) => c.produced == null) ? "Card data is still updating" : "No card here makes tokens"} />
        : made.map((t) => (
          <div key={t.key} className="bg-t1-surface px-4 py-3 flex flex-col gap-1 min-w-0">
            <div className="flex items-baseline gap-3 min-w-0">
              <span className="text-[13px] truncate flex-1">{t.name}</span>
              <span className="t1-label shrink-0">{t.type.replace("Token ", "")}</span>
            </div>
            <span className="text-[12px] text-t1-muted">Made by {t.makers.map((m) => (m.qty > 1 ? `${m.name} ×${m.qty}` : m.name)).join(", ")}</span>
          </div>
        ))}

      <Section title="Price" />
      <Row title={p.total > 0 ? usd(p.total) : "No prices yet"} detail={p.unpriced > 0 ? `TCGplayer market · ${p.unpriced} unpriced` : "TCGplayer market · main and side"} />

      <Section title="Try it" />
      <Row title="Sample hand" detail="Draw seven, mulligan, draw the next card" onClick={onHand} />
      <Row title="Draw odds" detail="Chance to see cards by a turn" onClick={onOdds} />
    </>
  );
}

const PACK_KEY = "table1.library.cube.packSize";
function usePackSize(): [number, (n: number) => void] {
  const [n, setN] = useState(() => {
    try { return Number(localStorage.getItem(PACK_KEY)) || 15; } catch { return 15; }
  });
  return [n, (v) => { setN(v); try { localStorage.setItem(PACK_KEY, String(v)); } catch { /* fine */ } }];
}

function CubeStats({ cards, onPack }: { cards: StatCard[]; onPack: () => void }) {
  const [by, setBy] = useState<AsfanBy>("color");
  const [pack, setPack] = usePackSize();
  const size = qtyOf(cards);
  const balance = colorBalance(cards);
  const byColor = curveByColor(cards);
  const types = typeCounts(cards);
  const af = asfan(cards, pack, by);
  const labels = asfanLabels(by);
  return (
    <>
      <Cells cells={[["Cards", String(size)], ["Lands", String(balance[7])], ["Avg MV", dec(averageMV(cards, false))]]} />

      <Section title="Color balance" />
      <Table header={["Color", "Cards", "Share"]}
             rows={COLOR_GROUPS.map((g, i) => [g, String(balance[i]), pct(balance[i] / Math.max(1, size))]).filter((_, i) => balance[i] > 0)} />

      <Section title="Curve per color · mana value" />
      {/* One letter per color so nine columns fit a phone: W U B R G, M multicolor, C colorless. */}
      <Table header={["Color", ...BUCKETS]} cell={36}
             rows={byColor.map((r, i) => [["W", "U", "B", "R", "G", "M", "C"][i], ...r.map((n) => (n ? String(n) : "·"))]).filter((_, i) => sum(byColor[i]) > 0)} />

      <Section title="Type mix" />
      {TYPES.map((t, i) => (types[i] ? <Row key={t} title={t} detail={pct(types[i] / Math.max(1, size))} value={types[i]} /> : null))}

      <Section title="Asfan · expected per pack" />
      <Segmented options={[{ value: "color", label: "Color" }, { value: "type", label: "Type" }, { value: "mv", label: "Mana value" }]}
                 value={by} onChange={(v) => { setBy(v); capture("cube_asfan_changed", { by: v, pack }); }} />
      <Stepper label="Pack size" value={pack} min={1} max={30} onChange={setPack} />
      {labels.map((l, i) => (af[i] > 0 ? <Row key={l} title={l} value={dec(af[i])} accentValue /> : null))}

      <Section title="Try it" />
      <Row title="Sample pack" detail={`${pack} random cards from the cube`} onClick={onPack} />
    </>
  );
}

/* ── sample hand ─────────────────────────────────────────────────────── */

export function SampleHandScreen({ id, onBack }: { id: string; onBack: () => void }) {
  const state = useStatLines(id);
  const main = useMemo(() => state.lines?.filter((l) => l.card.board === "main") ?? null, [state.lines]);
  const library = useMemo(() => (main ? expand(main.map((l) => l.card)) : []), [main]);
  const [hand, setHand] = useState<SampleHand | null>(null);
  const counts = useRef({ hands: 0, mulligans: 0, draws: 0 });
  const deal = (n: number) => { setHand(SampleHand.deal(n, StatsRng.randomSeed())); counts.current.hands++; };
  useEffect(() => { if (main && (!hand || hand.size !== library.length)) deal(library.length); }, [library.length, main]);
  useEffect(() => () => {
    if (counts.current.hands > 0) capture("sample_hand_used", { ...counts.current });
  }, []);
  const subtitle = hand ? [`${hand.hand.length} in hand`, `library ${hand.library.length}`,
    hand.mulligans ? `${hand.mulligans} mulligan${hand.mulligans === 1 ? "" : "s"}` : null, hand.drawn ? `drew ${hand.drawn}` : null].filter(Boolean).join(" · ") : undefined;
  return (
    <StatsFrame title="Sample hand" subtitle={subtitle} onBack={onBack} state={state}>
      {(_, __, c) => !main || !hand ? null : library.length === 0 ? <Notice tone="info">The main deck is empty.</Notice> : (
        <>
          {hand.toBottom > 0 && (
            <Notice tone="info">Mulligan to {7 - hand.mulligans}: tap {hand.toBottom === 1 ? "a card" : `${hand.toBottom} cards`} to put on the bottom.</Notice>
          )}
          <CardGrid c={c} onClick={(i) => setHand(hand.bottom(i))}
                    items={hand.hand.map((pos, i) => {
                      const l = main[library[pos]];
                      return { key: `${i}-${pos}`, p: l.p, name: l.card.name, tag: i >= hand.hand.length - hand.drawn ? "Drawn" : undefined };
                    })} />
          <div className="flex gap-px">
            <StatsButton onClick={() => deal(library.length)}>New hand</StatsButton>
            <StatsButton disabled={!hand.canMulligan} onClick={() => { setHand(hand.mulligan()); counts.current.mulligans++; }}>
              {hand.canMulligan ? `Mulligan to ${6 - hand.mulligans}` : "Mulligan"}
            </StatsButton>
            <StatsButton disabled={!hand.canDraw} onClick={() => { setHand(hand.draw()); counts.current.draws++; }}>Draw</StatsButton>
          </div>
        </>
      )}
    </StatsFrame>
  );
}

/* ── draw odds ───────────────────────────────────────────────────────── */

export function DrawOddsScreen({ id, onBack }: { id: string; onBack: () => void }) {
  const state = useStatLines(id);
  const [group, setGroup] = useState("type:Land");
  const [atLeast, setAtLeast] = useState(1);
  const [turn, setTurn] = useState(3);
  const [onPlay, setOnPlay] = useState(true);
  const used = useRef<Record<string, string | number | boolean> | null>(null);
  useEffect(() => () => { if (used.current) capture("draw_odds_used", used.current); }, []);
  const mark = (next: Partial<{ group: string; atLeast: number; turn: number; onPlay: boolean }>) => {
    const g = next.group ?? group;
    used.current = { group: g.startsWith("card:") ? "card" : g.slice(5).toLowerCase(), turn: next.turn ?? turn, on_play: next.onPlay ?? onPlay, at_least: next.atLeast ?? atLeast };
  };
  return (
    <StatsFrame title="Draw odds" onBack={onBack} state={state}>
      {(lines) => {
        const main = lines.map((l) => l.card).filter((c) => c.board === "main");
        const N = qtyOf(main);
        if (N === 0) return <Notice tone="info">The main deck is empty.</Notice>;
        const types = typeCounts(main);
        const byName = new Map<string, number>();
        for (const c of main) byName.set(c.name, (byName.get(c.name) ?? 0) + c.qty);
        const groups = [
          ...TYPES.map((t, i) => ({ id: `type:${t}`, title: t === "Sorcery" ? "Sorceries" : `${t}s`, count: types[i] })).filter((g) => g.count > 0),
          ...[...byName].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).map(([name, n]) => ({ id: `card:${name}`, title: name, count: n })),
        ];
        const chosen = groups.find((g) => g.id === group) ?? groups[0];
        const K = chosen?.count ?? 0;
        const draws = drawsByTurn(turn, onPlay);
        const p = hypergeometric(N, K, draws, atLeast);
        return (
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <div className="bg-t1-surface py-5 flex flex-col items-center gap-1.5">
              <span className="t1-label">At least {atLeast} of {K} {chosen?.title} by turn {turn}</span>
              <span className="text-[44px] tabular-nums text-t1-accent leading-none py-1">{pct(p)}</span>
              <span className="t1-label">{draws} of {N} cards seen {onPlay ? "on the play" : "on the draw"}</span>
            </div>
            <Segmented options={[{ value: "play", label: "On the play" }, { value: "draw", label: "On the draw" }]}
                       value={onPlay ? "play" : "draw"} onChange={(v) => { setOnPlay(v === "play"); mark({ onPlay: v === "play" }); }} />
            <Stepper label="At least" value={atLeast} min={1} max={Math.max(1, Math.min(K, 22))} onChange={(v) => { setAtLeast(v); mark({ atLeast: v }); }} />
            <Stepper label="By turn" value={turn} min={1} max={15} onChange={(v) => { setTurn(v); mark({ turn: v }); }} />

            <Section title="By turn" />
            <Table header={["Turn", "Seen", "Chance"]}
                   rows={[1, 2, 3, 4, 5, 6, 7, 8].map((t) => {
                     const n = drawsByTurn(t, onPlay);
                     return [`Turn ${t}`, String(Math.min(n, N)), pct(hypergeometric(N, K, n, atLeast))];
                   })} />

            <Section title="Card group" />
            {groups.map((g) => (
              <Row key={g.id} title={g.title} detail={`${g.count} in the main deck`} value={g.id === chosen?.id ? <span className="t1-label !text-t1-accent">Selected</span> : undefined}
                   onClick={() => { setGroup(g.id); setAtLeast(Math.min(atLeast, Math.max(1, g.count))); mark({ group: g.id }); }} />
            ))}
          </div>
        );
      }}
    </StatsFrame>
  );
}

/* ── sample pack ─────────────────────────────────────────────────────── */

export function SamplePackScreen({ id, onBack }: { id: string; onBack: () => void }) {
  const state = useStatLines(id);
  const [packSize] = usePackSize();
  const main = useMemo(() => state.lines?.filter((l) => l.card.board === "main") ?? null, [state.lines]);
  const pool = useMemo(() => (main ? expand(main.map((l) => l.card)) : []), [main]);
  const [pack, setPack] = useState<number[]>([]);
  const packs = useRef(0);
  const open = (n: number) => { setPack(new StatsRng(StatsRng.randomSeed()).shuffle(n).slice(0, packSize)); packs.current++; };
  useEffect(() => { if (pool.length) open(pool.length); }, [pool.length]);
  useEffect(() => () => { if (packs.current > 0) capture("sample_pack_used", { packs: packs.current, size: packSize }); }, []);
  return (
    <StatsFrame title="Sample pack" subtitle={`${pack.length} cards`} onBack={onBack} state={state}>
      {(_, __, c) => !main ? null : pool.length === 0 ? <Notice tone="info">The cube is empty.</Notice> : (
        <>
          <CardGrid c={c} items={pack.map((pos, i) => { const l = main[pool[pos]]; return { key: `${i}-${pos}`, p: l.p, name: l.card.name }; })} />
          <div className="flex gap-px"><StatsButton onClick={() => open(pool.length)}>Another pack</StatsButton></div>
        </>
      )}
    </StatsFrame>
  );
}
