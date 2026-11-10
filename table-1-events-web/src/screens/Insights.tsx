import { lazy, Suspense, useEffect, useMemo, useState, type ReactNode } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Bar as ShareBar, Heatmap, LineChart, Scatter, SlopeChart, type Marker } from "../components/InsightCharts";
import { Bar, GhostAction, Notice, Row, Screen, Section, Segmented, Stat, SwitchRow, TabNav } from "../components/kit";
import { cardImageUrl, printingsByName, type Catalog } from "../lib/catalog";
import { EDIT_VALUE, FilterRow, ManaCost, type FilterCell } from "../components/FilterRow";
import { LIMITED_COLORS, LIMITED_RARITIES, LIMITED_SORTS, LIMITED_TOP, MIN_QUERY, colorLabel, limitedCards, rarityLabel, togglePick, limitedSearch, limitedValue, overall, searchNorm } from "../lib/limitedCards";
import { delta, months, pct, pct1, rates, seriesWindow, shortDay, wilson } from "../lib/insightCharts";
import {
  EVENT_LABELS, EVENT_ORDER, FORMATS, PAIR_NAMES, WINDOWS, canHide, exampleFinish, formatParts, place, setHidden, sourcesCredit, visibleKeys, type Finish, type PartKey, afterWindow, archetypeName, archetypePage, cardPage, changeWords, colorsName, isBan,
  gridFor, gridShare, type ShareRow, loadInsights, loadInsightsDemo, loadInsightsExtras, matchup, matchupRows, mineFor, pick, setInsightsAlerts, yoursFirst, type Mine, useInsights, type ArchetypePage, type CardPage, type CardRow, type ConstructedPack, type Matchups,
  type LCard, type LimitedPack, type LView, type Tier,
  archetypeBar, archetypeDetail, cardMarkers, finishDetail, finishTitle, hitDetail, searchCards, type CardFinish, type CardHit,
} from "../lib/insights";
import { isLibraryDemo } from "../lib/libraryDemo";
import { limitedLabel, limitedPicker, rankableDetail, shownChips, soonText } from "../lib/limitedRank";
import { ICON, Icon, useCatalog } from "./Library";
import { createList, type Entry } from "../lib/lists";
import type { ProfileCard } from "../lib/friends";

/** An example list draws like a deck shared with you (View, Group by, Sort, card art, Export, Deck image). */
const ProfileCardsBody = lazy(() => import("./Friends").then((m) => ({ default: m.ProfileCardsBody })));
import { supabase } from "../lib/supabaseClient";
import { capture } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/* Insights (contract/insights-2026-10-24.md): the constructed metagame from Magic Online (and TopDeck.gg) results and
   Arena draft from 17Lands' public data. Every screen opens with its brief; the source is credited at the top. */

function useInsightsData() {
  const s = useInsights();
  const { session, ready } = useSession();
  useEffect(() => {
    if (import.meta.env.DEV && isLibraryDemo()) void loadInsightsDemo();
    else if (session) void loadInsights();
  }, [session]);
  return { ...s, session, ready: ready || s.demo };
}

const Scroll = ({ children }: { children: ReactNode }) => <div className="flex flex-col gap-px pb-8">{children}</div>;

function Brief({ text, scope, thin, credit }: { text: string | null | undefined; scope: string; thin?: boolean; credit?: { label: string; url: string } }) {
  return (
    <div className="bg-t1-surface px-4 py-4 flex flex-col gap-2">
      <p className="t1-label">In brief · {scope}</p>
      {text
        ? <p className="text-[14px] leading-[22px]">{text}</p>
        : <p className="text-[13px] text-t1-muted">{thin ? "Too few results in this window to say much yet." : "The summary is on its way."}</p>}
      {credit && (
        <a href={credit.url} target="_blank" rel="noreferrer" onClick={() => capture("insights_source_opened", { source: credit.label })}
           className="t1-label underline hover:text-t1-text">{credit.label}</a>
      )}
    </div>
  );
}

function Stats({ items }: { items: [string, string][] }) {
  return <div className="flex gap-px">{items.map(([l, v]) => <div key={l} className="flex-1 bg-t1-surface px-4 py-3"><Stat label={l} value={v} /></div>)}</div>;
}

const Chart = ({ children }: { children: ReactNode }) => <div className="bg-t1-surface px-3 py-3">{children}</div>;

function SignInFirst() {
  return <Notice tone="info">Sign in to see Insights.</Notice>;
}

/* ── home ─────────────────────────────────────────────────────────────── */

export function InsightsHome({ section }: { section: "constructed" | "limited" }) {
  const nav = useNavigate();
  const data = useInsightsData();
  const [moderator, setModerator] = useState(false);
  useEffect(() => {
    if (!data.session) return;
    void supabase.rpc("moderation_me").then(({ data: me }) => setModerator(!!(me as { moderator?: boolean } | null)?.moderator));
  }, [data.session]);
  return (
    <Screen>
      <TabNav />
      <Bar title="Insights" subtitle={section === "limited" ? "Arena draft" : "Constructed metagame"}
           right={section === "constructed" && (data.session || data.demo) ? (
             <button type="button" aria-label="Search cards" className="w-[50px] h-[50px] -my-3 -mr-4 flex items-center justify-center hover:text-t1-accent"
                     onClick={() => { capture("insights_card_search_opened", { format: data.picks.format }); nav(`/insights/${data.picks.format}/cards${data.demo ? "?demo" : ""}`); }}>
               <Icon d={ICON.search} />
             </button>) : undefined} />
      <Segmented options={[{ value: "constructed", label: "Constructed" }, { value: "limited", label: "Limited" }]} value={section}
                 onChange={(v) => { capture("insights_section_changed", { section: v }); nav(v === "limited" ? "/insights/limited" : "/insights"); }} />
      {!data.session && !data.demo ? (data.ready ? <SignInFirst /> : null)
        : section === "limited" ? <LimitedHome /> : <ConstructedHome />}
      {moderator && <Row title="Review" detail="Proposed archetypes and bans" onClick={() => nav("/insights/review")} />}
    </Screen>
  );
}

function ConstructedHome() {
  const nav = useNavigate();
  const { constructed, picks, error, index, stale } = useInsights();
  const [hl, setHl] = useState<number | null>(null);
  const [editing, setEditing] = useState(false);
  const shown = visibleKeys(FORMATS.map((f) => f.key as string), picks.hiddenFormats);
  const format = shown.includes(picks.format) ? picks.format : shown[0];
  const pack = constructed[format];
  const tier: Tier = picks.tier ?? pack?.default_tier ?? "big";
  const view = pack?.tiers[tier];
  const w = view?.windows[String(picks.days)];
  return (
    <Scroll>
      <FilterRow cells={[
        { name: "Format", value: FORMATS.find((f) => f.key === format)?.label ?? format, current: format,
          options: [...FORMATS.filter((f) => shown.includes(f.key)).map((f) => ({ value: f.key as string, label: f.label })), { value: EDIT_VALUE, label: "Shown formats…" }],
          onPick: (v) => (v === EDIT_VALUE ? setEditing(true) : pick({ format: v })) },
        tierCell(tier), daysCell(picks.days),
      ]} />
      {editing && <ShownEditor title="Shown formats" items={FORMATS.map((f) => ({ key: f.key as string, label: f.label }))} hidden={picks.hiddenFormats}
                               which="hiddenFormats" onDone={() => setEditing(false)} />}
      {stale && <Notice tone="info">{stale}</Notice>}
      {!pack && (error ? <Notice tone="error">{error}</Notice> : <Notice tone="info">{index ? "No results for this format yet." : "Loading the metagame…"}</Notice>)}
      {!pack && error && <GhostAction label="Try again" onClick={() => void loadInsights(true)} />}
      {pack && view && w && <ConstructedBody pack={pack} tier={tier} view={view} w={w} days={picks.days} hl={hl} setHl={setHl} go={(p) => nav(p)} />}
    </Scroll>
  );
}

/** Big events | All events as a filter cell. */
const tierCell = (tier: Tier): FilterCell => ({
  name: "Events", value: tier === "big" ? "Big events" : "All events", current: tier,
  options: [{ value: "big", label: "Big events" }, { value: "all", label: "All events" }], onPick: (v) => pick({ tier: v as Tier }),
});
/** The window, 7–90 days, as a filter cell. */
const daysCell = (days: number): FilterCell => ({
  name: "Window", value: `${days} days`, current: String(days),
  options: WINDOWS.map((d) => ({ value: String(d), label: `Last ${d} days` })), onPick: (v) => pick({ days: Number(v) }),
});

/** Big events | All events, then the window (7–90 days); `days` off where the part doesn't depend on it. */
function WindowPickers({ tier, days, showDays = true }: { tier: Tier; days: number; showDays?: boolean }) {
  return <FilterRow cells={showDays ? [tierCell(tier), daysCell(days)] : [tierCell(tier)]} />;
}

/** The format page: Meta over time and the matchup grid first, then the brief, and a row for each part, which opens
 *  on its own screen (InsightsPart). */
function ConstructedBody({ pack, tier, view, w, days, hl, setHl, go }: {
  pack: ConstructedPack; tier: Tier; view: ConstructedPack["tiers"]["big"]; w: ConstructedPack["tiers"]["big"]["windows"][string]; days: number;
  hl: number | null; setHl: (a: number) => void; go: (p: string) => void;
}) {
  const f = pack.format;
  const credit = sourcesCredit(pack.sources);
  // The chart covers the picked window; lines with no decks in it are left out.
  const span = seriesWindow(view.series.from, view.series.days, days);
  const lines = view.series.lines.map((l) => ({ a: l.a, v: l.v.slice(span.offset) })).filter((l) => l.v.some((v) => v != null));
  const highlighted = hl != null && lines.some((l) => l.a === hl) ? hl : lines[0]?.a;
  const grid = gridFor(pack, tier, days);
  const markers: Marker[] = [];
  for (const c of pack.changes) {   // one marker per day: a ban and an unban on May 18 read BAN/UNBAN
    const index = Math.round((Date.parse(c.on) - Date.parse(span.from)) / 86400000);
    const label = isBan(c) ? c.kind.toUpperCase() : (c.set_code ?? "").toUpperCase();
    const same = markers.find((m) => m.index === index);
    if (same) { same.label = `${same.label}/${label}`; same.ban ||= isBan(c); } else markers.push({ index, label, ban: isBan(c) });
  }
  return (
    <>
      {w.thin && <Notice tone="info">Few results in this window: these numbers can swing.</Notice>}
      <Section title="Meta over time · 7-day share" />
      <Chart>
        <LineChart count={span.days} xLabels={span.labels} markers={markers} height={320} endLabels={false}
                   series={lines.map((l) => ({ id: l.a, label: archetypeName(pack, l.a), values: l.v, highlighted: l.a === highlighted }))} />
      </Chart>
      <div className="flex gap-px overflow-x-auto">
        {lines.map((l) => (
          <button key={l.a} type="button" onClick={() => setHl(l.a)}
                  className={`shrink-0 px-3 py-2.5 text-[11px] uppercase tracking-[1.5px] ${l.a === highlighted ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>
            {/* the picked line's latest share, since the chart has no end labels */}
            {l.a === highlighted ? [archetypeName(pack, l.a), ...l.v.filter((v) => v != null).slice(-1).map(pct)].join(" · ") : archetypeName(pack, l.a)}
          </button>
        ))}
      </div>
      {grid.m.cells.length > 0 && (
        <>
          <Section title={`Matchups · ${grid.scope}`} />
          <MatchupGrid key={`${tier}-${days}`} pack={pack} m={grid.m} share={gridShare(pack, tier, days)} />
        </>
      )}
      <Brief text={w.brief} scope={`${tier === "big" ? "Big events" : "All events"}, last ${days} days`} thin={w.thin} credit={credit} />
      <Stats items={[["Decks", String(w.decks)], ["Events", String(w.events)], ["Through", shortDay(pack.through)]]} />
      {formatParts(pack, tier, days).map((p) => (
        <Row key={p.key} title={p.title} detail={p.detail}
             onClick={() => { capture("insights_part_opened", { format: f, part: p.key }); go(`/insights/${f}/part/${p.key}`); }} />
      ))}
    </>
  );
}

/* ── format page parts ────────────────────────────────────────────────── */

/** One part of the format page on its own screen: Meta now, Cards rising and falling, New set, bans and their kin,
 *  or events, for the tier and window picked on the format page (changeable here too). */
export function InsightsPart() {
  const { format = "", part = "" } = useParams();
  const nav = useNavigate();
  const { constructed, picks, session, demo, ready } = useInsightsData();
  const [board, setBoard] = useState<"main" | "side">("main");
  useEffect(() => { window.scrollTo(0, 0); }, [format, part]);   // its row sits at the bottom of the format page
  const pack = constructed[format];
  const tier: Tier = picks.tier ?? pack?.default_tier ?? "big";
  const view = pack?.tiers[tier];
  const w = view?.windows[String(picks.days)];
  const days = picks.days;
  const key = part as PartKey;
  const title = (pack && formatParts(pack, tier, days).find((p) => p.key === key)?.title)
    ?? { meta: "Meta now", cards: "Cards rising and falling", new_set: "New set", changes: "Bans and unbans", events: tier === "big" ? "Big events" : "Events" }[key] ?? "Insights";
  const scope = `${tier === "big" ? "Big events" : "All events"}, last ${days} days`;
  if (!session && !demo) return <Screen><Bar title={title} onBack={() => nav(-1)} />{ready && <SignInFirst />}</Screen>;
  const go = (p: string) => nav(p);
  const f = pack?.format ?? format;
  const cardRow = (c: CardRow, up: boolean) => (
    <Row key={c.c} title={c.n} onClick={() => go(`/insights/${f}/card/${c.c}?n=${encodeURIComponent(c.n)}`)}
         detail={`in ${pct(c.rate)} of decks · was ${pct(c.prev ?? 0)}${c.copies != null ? ` · ${c.copies.toFixed(1)} copies` : ""}`}
         value={`${up ? "▲" : "▼"} ${delta(c.rate - (c.prev ?? 0)).slice(1)}`} accentValue={up} />
  );
  const body = (): ReactNode => {
    if (!pack) return <Notice tone="info">Loading the metagame…</Notice>;
    switch (key) {
      case "meta": {
        if (!w) return null;
        const maxShare = Math.max(0.1, ...w.share.map((s) => s.share));
        const lead = w.share.find((s) => s.a !== 0)?.a;
        return (
          <>
            <WindowPickers tier={tier} days={days} />
            <Section title="Share of top finishes" />
            {w.share.map((s) => (
              <ShareBar key={s.a} label={archetypeName(pack, s.a)} value={s.share} max={maxShare} change={s.prev == null ? null : s.share - s.prev}
                        highlighted={s.a === lead} onClick={() => go(`/insights/${f}/archetype/${s.a}`)}
                        detail={rates(s.wr, s.t8r, s.won, w.won_of) || null} />
            ))}
            {!w.share.length && <Notice tone="info">No decks in this window.</Notice>}
          </>
        );
      }
      case "cards": {
        if (!w) return null;
        const movers = w.cards[board];
        return (
          <>
            <WindowPickers tier={tier} days={days} />
            <Segmented options={[{ value: "main" as const, label: "Main deck" }, { value: "side" as const, label: "Sideboard" }]} value={board} onChange={setBoard} />
            {movers.up.length > 0 && <Section title="Rising" />}
            {movers.up.map((c) => cardRow(c, true))}
            {movers.down.length > 0 && <Section title="Falling" />}
            {movers.down.map((c) => cardRow(c, false))}
            {!movers.up.length && !movers.down.length && <Notice tone="info">No card moved much in this window.</Notice>}
          </>
        );
      }
      case "new_set": {
        const ns = view?.new_set;
        return (
          <>
            <WindowPickers tier={tier} days={days} showDays={false} />
            {ns?.cards.map((c) => (
              <Row key={c.c} title={c.n} value={pct(c.rate)} onClick={() => go(`/insights/${f}/card/${c.c}?n=${encodeURIComponent(c.n)}`)}
                   detail={`in ${pct(c.rate)} of decks${c.in?.[0] != null ? ` · most in ${archetypeName(pack, c.in[0])}` : ""}`} />
            ))}
            {!ns?.cards.length && <Notice tone="info">No new set cards played yet.</Notice>}
          </>
        );
      }
      case "changes":
        return pack.bans.map((b) => {
          const ch = pack.changes.find((c) => c.id === b.change);
          return ch && <Row key={b.change} title={changeWords(ch)} onClick={() => go(`/insights/${f}/ban/${b.change}`)}
                            detail={`${shortDay(ch.on)}${b.settled_days != null ? ` · settled after ${b.settled_days} days` : ""}`} />;
        });
      case "events": {
        const events = pack.events.filter((e) => tier === "all" || e.tier === "major" || e.tier === "large");
        return (
          <>
            <WindowPickers tier={tier} days={days} showDays={false} />
            {events.map((e, i) => (
              <Row key={i} title={e.name} value={e.tier.toUpperCase()}
                   detail={[shortDay(e.on), e.players ? `${e.players} players` : null, e.winner != null ? `won by ${archetypeName(pack, e.winner)}` : null].filter(Boolean).join(" · ")}
                   onClick={e.url ? () => { capture("insights_source_opened", { source: e.source }); window.open(e.url!, "_blank", "noopener"); } : undefined} />
            ))}
            {!events.length && <Notice tone="info">No events in the pack yet.</Notice>}
          </>
        );
      }
      default:
        return <Notice tone="info">This part isn't in the pack.</Notice>;
    }
  };
  return (
    <Screen>
      <Bar title={title} subtitle={`${pack?.name ?? format}${key === "meta" || key === "cards" ? ` · ${scope}` : ""}`} onBack={() => nav(-1)} />
      <Scroll>{body()}</Scroll>
    </Screen>
  );
}

/* ── archetype ────────────────────────────────────────────────────────── */

/** A finish's names in their original printings, non-foil, like Add to my decks; and how many cards it couldn't name. */
const finishRowsMemo = new WeakMap<Finish, { rows: ProfileCard[]; missing: number }>();
function finishRows(fin: Finish, catalog: Catalog): { rows: ProfileCard[]; missing: number } {
  const had = finishRowsMemo.get(fin);
  if (had) return had;
  const byName = printingsByName(catalog, [...fin.main, ...fin.side].map(([n]) => n));
  const rows: ProfileCard[] = [];
  let missing = 0;
  for (const [board, lines] of [["main", fin.main], ["side", fin.side]] as const) {
    for (const [n, q] of lines) { const p = byName.get(n); if (p !== undefined) rows.push({ cardId: catalog.pId[p], board, qty: q }); else missing += q; }
  }
  const out = { rows, missing };
  finishRowsMemo.set(fin, out);
  return out;
}

export function InsightsArchetype() {
  const { format = "", id = "0", i } = useParams();
  const nav = useNavigate();
  const { constructed, picks, session, demo, ready } = useInsightsData();
  const [page, setPage] = useState<ArchetypePage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<{ text: string; listId?: string } | null>(null);
  const { catalog } = useCatalog();
  const pack = constructed[format];
  useEffect(() => {
    if (!session && !demo) return;
    archetypePage(format, Number(id), "all", picks.days).then(setPage, (e) => setError(String(e?.message ?? e)));
  }, [format, id, picks.days, session, demo]);
  const back = () => nav(-1);
  const name = page?.archetype.name ?? archetypeName(pack, Number(id));
  if (!session && !demo) return <Screen><Bar title={name} onBack={back} />{ready && <SignInFirst />}</Screen>;

  /** A finish's list as a new private deck in the viewer's Library (original printings), then a link to it. */
  const addToDecks = async (fin: Finish, where: "example" | "finish", deckName = name) => {
    if (!catalog) { setCopied({ text: "The card catalog is still loading" }); return; }
    const byName = printingsByName(catalog, [...fin.main, ...fin.side].map(([n]) => n));
    const entries: Entry[] = [];
    let missing = 0;
    for (const [board, lines] of [["main", fin.main], ["side", fin.side]] as const) {
      for (const [n, q] of lines) { const p = byName.get(n); if (p !== undefined) entries.push({ cardId: catalog.pId[p], board, qty: q }); else missing += q; }
    }
    let listId: string;
    try {
      listId = await createList("deck", deckName.slice(0, 60), format, entries, `From ${fin.event}, ${fin.on}`.slice(0, 120), "insights");
    } catch (e) {
      setCopied({ text: `Couldn't add it: ${(e as { message?: string })?.message ?? String(e)}` });
      return;
    }
    capture("insights_copy_to_library", { format, archetype: name, from: where });
    setCopied({ text: `Added to your decks as ${deckName}${missing ? ` (${missing} card${missing === 1 ? "" : "s"} not found)` : ""}`, listId });
  };
  if (i != null) {
    const fin = page?.finishes[Number(i)];
    // an Other group's example is named for its colors
    const group = Number(id) === 0 ? page?.groups?.find((g) => g.example === Number(i)) : undefined;
    const title = group ? colorsName(group.colors || "C", "") : name;
    const loading = (
      <Screen>
        <Bar title={title} subtitle={fin ? `${fin.event} · ${shortDay(fin.on)}` : undefined} onBack={back} />
        <Notice tone="info">Loading…</Notice>
      </Screen>
    );
    if (!fin || !catalog) return loading;
    const { rows, missing } = finishRows(fin, catalog);
    const byline = [`${fin.rank != null ? `${place(fin.rank)} at ` : ""}${fin.event}`, shortDay(fin.on), fin.players != null ? `${fin.players} players` : null,
                    missing ? `${missing} card${missing === 1 ? "" : "s"} not found` : null].filter(Boolean).join(" · ");
    return (
      <Suspense fallback={loading}>
        <ProfileCardsBody userId="" section="deck" item={null} onBack={back} onList={(listId) => nav(`/library/list/${listId}`)}
                          onCard={(o) => nav(`/library/card/${o}`, { state: { search: true } })}
                          preset={{ rows, name: title, format, byline,
                                    actions: <AddRow copied={copied} onAdd={() => void addToDecks(fin, "finish", title)} onOpen={(listId) => nav(`/library/list/${listId}`)} /> }} />
      </Suspense>
    );
  }

  const share = pack?.tiers.all.windows[String(picks.days)]?.share.find((s) => s.a === Number(id));
  const example = page ? exampleFinish(page.finishes) : -1;
  const cards = (title: string, rows: CardRow[]) => rows.length > 0 && (
    <>
      <Section title={title} />
      {rows.slice(0, 16).map((c) => <Row key={c.c} title={c.n} value={pct(c.rate)} detail={c.copies != null ? `${c.copies.toFixed(1)} copies` : undefined}
                                         onClick={() => nav(`/insights/${format}/card/${c.c}?n=${encodeURIComponent(c.n)}`)} />)}
    </>
  );
  return (
    <Screen>
      <Bar title={name} subtitle={`${pack?.name ?? format} · all events, last ${picks.days} days`} onBack={back} />
      {error && <Notice tone="error">{error}</Notice>}
      {!page && !error && <Notice tone="info">Loading…</Notice>}
      {page && (
        <Scroll>
          <Brief text={page.brief} scope="last 30 days, all events" thin={page.decks < 20} />
          <Stats items={[["Share", pct(share?.share)], ["Decks", String(page.decks)], ["Record", page.record ? `${page.record.wins}-${page.record.losses}` : "–"]]} />
          {page.record && <Notice tone="info">{page.record.basis === "topdeck" ? "Record from paper events' rounds." : "Record of players who reached a Challenge's top 32, so it runs high."}</Notice>}
          {Number(id) === 0 && (page.groups?.length ?? 0) > 0 && (
            <>
              <Section title="Inside Other · by colors" />
              <Notice tone="info">Decks no archetype names yet, grouped by their colors. Open one for an example list.</Notice>
              {page.groups!.map((g) => (
                <Row key={g.colors} title={colorsName(g.colors || "C", "")} value={pct(g.share)}
                     detail={[`${g.decks} deck${g.decks === 1 ? "" : "s"}`, g.cards.join(", ")].filter(Boolean).join(" · ")}
                     onClick={g.example != null ? () => nav(`/insights/${format}/archetype/${id}/finish/${g.example}`) : undefined} />
              ))}
            </>
          )}
          {Number(id) !== 0 && example >= 0 && (() => {
            const fin = page.finishes[example];
            const count = (l: [string, number][]) => l.reduce((n, [, q]) => n + q, 0);
            return (
              <>
                <Section title={`Example list · ${fin.rank != null ? `${place(fin.rank)} at ` : ""}${fin.event}`} />
                <Row title={[shortDay(fin.on), fin.players ? `${fin.players} players` : null, fin.tier === "major" || fin.tier === "large" ? "big event" : null].filter(Boolean).join(" · ")}
                     detail={`${count(fin.main)} cards · sideboard ${count(fin.side)}`} />
                <AddRow copied={copied} onAdd={() => void addToDecks(fin, "example")} onOpen={(listId) => nav(`/library/list/${listId}`)} />
                {fin.main.slice(0, 12).map(([n, q]) => <Row key={n} title={n} value={q} />)}
                <Row title="See the whole list" detail={fin.main.length > 12 ? `${fin.main.length - 12} more cards and the sideboard` : "With the sideboard"}
                     onClick={() => nav(`/insights/${format}/archetype/${id}/finish/${example}`)} />
              </>
            );
          })()}
          <Section title="Share by week" />
          <Chart><LineChart count={page.series.weeks} height={150} labelWidth={50} series={[{ id: "a", label: "", values: page.series.v, highlighted: true }]} /></Chart>
          {Number(id) !== 0 && cards("Core · in 80%+ of lists", page.core)}
          {Number(id) !== 0 && cards("Flex slots", page.flex)}
          {Number(id) !== 0 && cards("Sideboard", page.side)}
          {page.matchups.length > 0 && (
            <>
              <Section title="Matchups · last 90 days" />
              {page.matchups.slice(0, 8).map((m) => {
                const n = m.wins + m.losses;
                const [lo, hi] = wilson(m.wins, n);
                return <Row key={m.vs} title={`vs ${archetypeName(pack, m.vs)}`} value={`${m.wins}-${m.losses}`}
                            detail={n >= 30 ? `${pct(lo)}–${pct(hi)} likely` : "Too few matches to say"} />;
              })}
            </>
          )}
          {page.finishes.length > 0 && (
            <>
              <Section title="Best finishes" />
              {page.finishes.map((fin, k) => (
                <Row key={k} title={fin.event} onClick={() => nav(`/insights/${format}/archetype/${id}/finish/${k}`)}
                     detail={[fin.rank != null ? `#${fin.rank}` : null, shortDay(fin.on), fin.players ? `${fin.players} players` : null].filter(Boolean).join(" · ")} />
              ))}
            </>
          )}
        </Scroll>
      )}
    </Screen>
  );
}

/* ── card ─────────────────────────────────────────────────────────────── */

export function InsightsCard() {
  const { format = "", oracleId = "", i } = useParams();
  const nav = useNavigate();
  const name = new URLSearchParams(location.search).get("n") ?? "Card";
  const { constructed, picks, session, demo, ready } = useInsightsData();
  const [page, setPage] = useState<CardPage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<{ text: string; listId?: string } | null>(null);
  const { catalog } = useCatalog();
  const pack = constructed[format];
  const tier: Tier = picks.tier ?? pack?.default_tier ?? "big";
  useEffect(() => {
    if (!session && !demo) return;
    let live = true;
    cardPage(format, oracleId, tier, picks.days).then((p) => { if (live) { setPage(p); setError(null); } }, (e) => live && setError(String(e?.message ?? e)));
    return () => { live = false; };
  }, [format, oracleId, tier, picks.days, session, demo]);
  const back = () => nav(-1);
  const title = page?.n ?? name;
  if (!session && !demo) return <Screen><Bar title={title} onBack={back} />{ready && <SignInFirst />}</Screen>;

  if (i != null) {
    // one of the card's best lists, drawn like an archetype's example list
    const fin = page?.finishes?.[Number(i)];
    const deck = fin ? archetypeName(pack, fin.a) : title;
    const loading = <Screen><Bar title={deck} onBack={back} /><Notice tone="info">Loading…</Notice></Screen>;
    if (!fin || !catalog) return loading;
    const { rows, missing } = finishRows(fin, catalog);
    const byline = [`${fin.rank != null ? `${place(fin.rank)} at ` : ""}${fin.event}`, shortDay(fin.on), fin.players != null ? `${fin.players} players` : null,
                    missing ? `${missing} card${missing === 1 ? "" : "s"} not found` : null].filter(Boolean).join(" · ");
    const add = async () => {
      const byName = printingsByName(catalog, [...fin.main, ...fin.side].map(([n]) => n));
      const entries: Entry[] = [];
      for (const [board, lines] of [["main", fin.main], ["side", fin.side]] as const) {
        for (const [n, q] of lines) { const p = byName.get(n); if (p !== undefined) entries.push({ cardId: catalog.pId[p], board, qty: q }); }
      }
      try {
        const listId = await createList("deck", deck.slice(0, 60), format, entries, `From ${fin.event}, ${fin.on}`.slice(0, 120), "insights");
        capture("insights_copy_to_library", { format, archetype: deck, from: "card" });
        setCopied({ text: `Added to your decks as ${deck}${missing ? ` (${missing} card${missing === 1 ? "" : "s"} not found)` : ""}`, listId });
      } catch (e) { setCopied({ text: `Couldn't add it: ${(e as { message?: string })?.message ?? String(e)}` }); }
    };
    return (
      <Suspense fallback={loading}>
        <ProfileCardsBody userId="" section="deck" item={null} onBack={back} onList={(listId) => nav(`/library/list/${listId}`)}
                          onCard={(o) => nav(`/library/card/${o}`, { state: { search: true } })}
                          preset={{ rows, name: deck, format, byline,
                                    actions: <AddRow copied={copied} onAdd={() => void add()} onOpen={(listId) => nav(`/library/list/${listId}`)} /> }} />
      </Suspense>
    );
  }

  const w = page?.window;
  const days = w?.days ?? picks.days;
  const s = page?.series;
  const last = (v: (number | null)[] | undefined) => (v ? [...v].reverse().find((x) => x != null) ?? null : null);
  const max = Math.max(0.01, ...(page?.by_archetype.map(archetypeBar) ?? []));
  const monthLabels = (from: string, weeks: number): [number, string][] => {
    const m = months(from, weeks * 7).map(([d, l]) => [Math.floor(d / 7), l] as [number, string]);
    return m.filter((_, k) => k % 2 === (m.length % 2 === 0 ? 1 : 0));
  };
  return (
    <Screen>
      <Bar title={title} onBack={back} />
      {pack && <WindowPickers tier={tier} days={picks.days} />}
      {error && <Notice tone="error">{error}</Notice>}
      {!page && !error && <Notice tone="info">Loading…</Notice>}
      {page && s && (
        <Scroll>
          <Stats items={[["Main", pct(w ? w.main : last(s.main))], ["Side", pct(w ? w.side : last(s.side))], ["Copies", (w ? w.copies : page.copies)?.toFixed(1) ?? "–"]]} />
          <Stats items={[["Lists", w ? `${w.decks}/${w.of}` : "–"], ["First seen", page.first_seen ? shortDay(page.first_seen) : "–"], ["Last seen", page.last_seen ? shortDay(page.last_seen) : "–"]]} />
          <Section title={`Share of ${pack?.name ?? format} lists by week`} />
          <Chart><LineChart count={s.weeks} height={190} labelWidth={70} xLabels={monthLabels(s.from, s.weeks)}
                            markers={pack ? cardMarkers(pack.changes, page.n ?? name, s.from, s.weeks) : []}
                            series={[{ id: "m", label: "Main", values: s.main, highlighted: true }, { id: "s", label: "Side", values: s.side }]} /></Chart>
          {w?.decks === 0 && <Notice tone="info">No lists played it in the last {days} days.</Notice>}
          {page.by_archetype.length > 0 && <Section title={`Played in · last ${days} days`} />}
          {page.by_archetype.map((a) => (
            <ShareBar key={a.a} label={archetypeName(pack, a.a)} value={archetypeBar(a)} max={max} onClick={() => nav(`/insights/${format}/archetype/${a.a}`)}
                      detail={archetypeDetail(a)} />
          ))}
          {(page.finishes?.length ?? 0) > 0 && <Section title={`Best lists · last ${days} days`} />}
          {page.finishes?.map((f: CardFinish, k) => (
            <Row key={k} title={finishTitle(f)} detail={finishDetail(f, archetypeName(pack, f.a))}
                 onClick={() => { capture("insights_card_list_opened", { format, tier: f.tier }); nav(`/insights/${format}/card/${oracleId}/list/${k}${location.search}`); }} />
          ))}
          <Row title="Open the card" detail="Prices, printings and your copies" onClick={() => nav(`/library/card/${oracleId}`)} />
        </Scroll>
      )}
    </Screen>
  );
}

/** Insights → search: cards played in the format this year, by name (meta_card_search), each opening its card page. */
export function InsightsCardSearch() {
  const { format = "" } = useParams();
  const nav = useNavigate();
  const { session, demo, ready } = useInsightsData();
  const label = FORMATS.find((f) => f.key === format)?.label ?? format;
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<{ q: string; hits: CardHit[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const q = query.trim();
  useEffect(() => {
    if (q.length < 2 || (!session && !demo)) { setFound(null); setError(null); return; }
    let live = true;
    const t = setTimeout(() => {
      searchCards(format, q).then((hits) => {
        if (!live) return;  // a newer query took over: an older answer never lands over it
        setFound({ q, hits }); setError(null);
        capture("insights_card_search", { format, results: hits.length });
      }, (e) => live && setError(`Search didn't work: ${String(e?.message ?? e)}`));
    }, 250);
    return () => { live = false; clearTimeout(t); };
  }, [q, format, session, demo]);
  if (!session && !demo) return <Screen><Bar title={`${label} cards`} onBack={() => nav(-1)} />{ready && <SignInFirst />}</Screen>;
  return (
    <Screen>
      <Bar title={`${label} cards`} onBack={() => nav(-1)} />
      <label className="shrink-0 bg-t1-surface px-4 py-3 flex flex-col gap-1">
        <span className="t1-label">Search</span>
        <input type="search" value={query} autoFocus placeholder="Card name" autoCapitalize="off" autoCorrect="off" spellCheck={false}
               onChange={(e) => setQuery(e.target.value)}
               className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full" />
      </label>
      <Scroll>
        {error && <Notice tone="error">{error}</Notice>}
        {!error && found && found.q === q && found.hits.length === 0 && <Notice tone="info">No {label} lists played a card called that this year.</Notice>}
        {q.length >= 2 && found?.hits.map((h) => (
          <Row key={h.c} title={h.n} detail={hitDetail(h)}
               onClick={() => { capture("insights_card_opened", { format, from: "search" }); nav(`/insights/${format}/card/${h.c}?n=${encodeURIComponent(h.n)}${demo ? "&demo" : ""}`); }} />
        ))}
      </Scroll>
    </Screen>
  );
}

/* ── ban study ────────────────────────────────────────────────────────── */

export function InsightsBan() {
  const { format = "", id = "0" } = useParams();
  const nav = useNavigate();
  const { constructed, session, demo, ready } = useInsightsData();
  const pack = constructed[format];
  const b = pack?.bans.find((x) => x.change === Number(id));
  const ch = pack?.changes.find((c) => c.id === Number(id));
  if (!session && !demo) return <Screen><Bar title="Format change" onBack={() => nav(-1)} />{ready && <SignInFirst />}</Screen>;
  const aw = b ? afterWindow(b) : null;
  const losers = new Set(b?.losers.map((l) => l.a));
  const ids = b && aw ? [...new Set([...b.before.slice(0, 6).map((x) => x.a), ...aw.shares.slice(0, 6).map((x) => x.a)])].slice(0, 8) : [];
  return (
    <Screen>
      <Bar title={ch ? changeWords(ch) : "Format change"} subtitle={ch ? `${pack?.name} · ${shortDay(ch.on)}` : undefined} onBack={() => nav(-1)} />
      {!b || !pack ? <Notice tone="info">This change isn't in the pack.</Notice> : (
        <Scroll>
          <Brief text={b.brief} scope="what changed after" thin={!b.before.length || !aw} />
          {aw ? (
            <>
              <Section title={`Share before → ${aw.days} days after`} />
              <Chart>
                <SlopeChart leftTitle="Before" rightTitle="After" rows={ids.map((a) => ({
                  id: a, label: archetypeName(pack, a), before: b.before.find((x) => x.a === a)?.share ?? 0, after: aw.shares.find((x) => x.a === a)?.share ?? 0,
                  highlighted: losers.has(a) || b.gainers[0]?.a === a,
                }))} />
              </Chart>
            </>
          ) : <Notice tone="info">No window after the change has ended yet.</Notice>}
          <Stats items={[["Settled", b.settled_days != null ? `${b.settled_days} days` : "Not yet"], ["Lost most", b.losers[0] ? archetypeName(pack, b.losers[0].a) : "–"],
                         ["Gained most", b.gainers[0] ? archetypeName(pack, b.gainers[0].a) : "–"]]} />
          {b.replacements.length > 0 && <Section title={ch?.kind === "unban" || ch?.kind === "unrestrict" ? "Where it's played" : "What replaced it"} />}
          {b.replacements.map((r) => (
            <Row key={`${r.in}-${r.c}`} title={r.n} onClick={() => nav(`/insights/${format}/card/${r.c}?n=${encodeURIComponent(r.n)}`)}
                 detail={`in ${archetypeName(pack, r.in)} · ${pct(r.before)} → ${pct(r.after)} of lists`} />
          ))}
        </Scroll>
      )}
    </Screen>
  );
}

/* ── matchups ─────────────────────────────────────────────────────────── */

export function InsightsMatchups() {
  const { format = "" } = useParams();
  const nav = useNavigate();
  const { constructed, picks, session, demo, ready } = useInsightsData();
  const pack = constructed[format];
  const tier: Tier = picks.tier ?? pack?.default_tier ?? "big";
  const grid = pack ? gridFor(pack, tier, picks.days) : null;
  if (!session && !demo) return <Screen><Bar title="Matchups" onBack={() => nav(-1)} />{ready && <SignInFirst />}</Screen>;
  return (
    <Screen>
      <Bar title="Matchups" subtitle={`${pack?.name ?? format} · ${grid?.scope ?? "last 90 days"}`} onBack={() => nav(-1)} />
      {pack && grid && <Scroll><WindowPickers tier={tier} days={picks.days} /><MatchupGrid key={`${tier}-${picks.days}`} pack={pack} m={grid.m} share={gridShare(pack, tier, picks.days)} /></Scroll>}
    </Screen>
  );
}

/** The matchup grid (rows against labelled columns) and the record of the square last tapped; on the format page
 *  under Meta over time, and on its own screen for older links. */
function MatchupGrid({ pack, m: grid, share }: { pack: ConstructedPack; m: Matchups; share: ShareRow[] }) {
  const [picked, setPicked] = useState<[number, number] | null>(null);
  const [mine, setMine] = useState<Mine | null>(null);
  useEffect(() => {
    let live = true;
    void mineFor(pack.format).then((x) => {
      if (!live) return;
      setMine(x);
      setPicked(null);   // the rows just moved
      const own = x?.decks.filter((d) => d.a !== 0).length ?? 0;
      if (x) capture("insights_yours", { format: pack.format, decks: own, close: yoursFirst(matchupRows(grid), x).filter((r) => r.note?.startsWith("You have")).length });
    });
    return () => { live = false; };
    // once per format, not per window
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pack.format]);
  const cols = grid.archetypes;
  const ordered = yoursFirst(matchupRows(grid), mine);
  const rows = ordered.map((r) => r.a);
  const m = picked && picked[0] < rows.length && picked[1] >= 0 && picked[1] < cols.length ? matchup(grid, rows[picked[0]], cols[picked[1]]) : null;
  const o = picked && picked[0] < rows.length && picked[1] < 0 ? overall(share, grid, rows[picked[0]]) : null;
  const on = o ? o.wins + o.losses : 0;
  const [olo, ohi] = o ? wilson(o.wins, on) : [0, 1];
  const n = m ? m.wins + m.losses : 0;
  const [lo, hi] = m ? wilson(m.wins, n) : [0, 1];
  return (
    <>
      <Notice tone="info">Each archetype with 1% of decks (rows) against the 10 most played (columns): the row's match win rate, and first its win rate against every archetype. Your decks come first, then archetypes your collection nearly builds. Faded: fewer than 30 matches, so treat it as a hint. Tap a square for the record. From MTGO top 8 brackets and paper events' rounds.</Notice>
      <Heatmap rows={rows.map((a) => archetypeName(pack, a))} notes={ordered.map((r) => r.note)} cols={cols.map((a) => archetypeName(pack, a))} same={(r, c) => rows[r] === cols[c]}
               picked={picked} onPick={(r, c) => { setPicked([r, c]); capture("insights_matchup_opened", { format: pack.format, overall: c < 0 }); }}
               cell={(r, c) => matchup(grid, rows[r], cols[c])} overall={(r) => overall(share, grid, rows[r])} />
      {o && picked && (
        <Row title={`${archetypeName(pack, rows[picked[0]])} overall`} value={`${o.wins}-${o.losses}${o.draws ? `-${o.draws}` : ""}`}
             detail={on >= 30 ? `${pct1(o.wins / on)} · likely ${pct(olo)}–${pct(ohi)}` : `Only ${on} matches: too few to say`} />
      )}
      {m && picked && picked[0] < rows.length && (
        <Row title={`${archetypeName(pack, rows[picked[0]])} vs ${archetypeName(pack, cols[picked[1]])}`} value={`${m.wins}-${m.losses}${m.draws ? `-${m.draws}` : ""}`}
             detail={n >= 30 ? `${pct1(m.wins / n)} · likely ${pct(lo)}–${pct(hi)}` : `Only ${n} matches: too few to say`} />
      )}
    </>
  );
}

/* ── limited ──────────────────────────────────────────────────────────── */


/** Add to my decks, then what happened with Open (the new deck) once it's there. */
function AddRow({ copied, onAdd, onOpen }: { copied: { text: string; listId?: string } | null; onAdd: () => void; onOpen: (listId: string) => void }) {
  if (copied?.listId) return <Row title={copied.text} detail="A new private deck" action={{ label: "Open", onClick: () => onOpen(copied.listId!) }} />;
  return <Row title="Add to my decks" detail={copied?.text ?? "A new private deck with these cards"} action={{ label: "Add", onClick: onAdd }} />;
}

/** Insights → Edit: a switch per format or set; the last one shown can't be hidden. Kept in this browser. */
function ShownEditor({ title, items, hidden, which, onDone }: {
  title: string; items: { key: string; label: string; detail?: string }[]; hidden: string[]; which: "hiddenFormats" | "hiddenSets"; onDone: () => void;
}) {
  const all = items.map((i) => i.key);
  return (
    <>
      <Section title={title} />
      {items.map((i) => {
        const on = !hidden.includes(i.key);
        return <SwitchRow key={i.key} label={i.label} detail={i.detail} on={on} disabled={on && !canHide(all, hidden, i.key)}
                          onChange={(next) => setHidden(which, i.key, !next)} />;
      })}
      <Row title="Done" onClick={onDone} />
    </>
  );
}

function limitedPick(packs: Record<string, LimitedPack>, set: string | undefined, eventPicked: string, groupPicked: "all" | "top") {
  const pack = set ? packs[set] : undefined;
  const events = pack ? EVENT_ORDER.filter((e) => pack.events[e]) : [];
  const event = events.includes(eventPicked) ? eventPicked : events[0];
  const groups = pack && event ? pack.events[event].groups : {};
  const group: "all" | "top" = groups[groupPicked] ? groupPicked : "all";
  return { set, pack, events, event, group, view: groups[group] as LView | undefined };
}

/** A set's or Arena cube version's Rankings (contract/cube-rankings-2026-10-21.md § Sets). */
function useRankSet() {
  const nav = useNavigate();
  return (key: string, kind: string, from: string) => {
    capture("insights_rank_opened", { set: key, kind, from });
    nav(`/insights/limited/${encodeURIComponent(key)}/rankings`);
  };
}

/** Sets out (or about to be) with no 17Lands data yet: rank them now. */
function NewSetsToRank() {
  const { rankable } = useInsights();
  const rank = useRankSet();
  const fresh = (rankable ?? []).filter((s) => !s.pack);
  if (!fresh.length) return null;
  return (<>
    <Section title="New sets to rank" />
    {fresh.map((s) => <Row key={s.key} title={`Rank ${s.name}`} detail={rankableDetail(s)} onClick={() => rank(s.key, s.kind, "new_sets")} />)}
  </>);
}

const oracleMaps = new WeakMap<Catalog, Map<string, number>>();

/** Each card's mana cost and its printing in the set (art), by name; a cube's cards take their original printing. */
function limitedFaces(catalog: Catalog | null, set: string, cards: LCard[]): Map<string, { cost: string; p: number }> {
  const out = new Map<string, { cost: string; p: number }>();
  if (!catalog) return out;
  let ids = oracleMaps.get(catalog);
  if (!ids) { ids = new Map(catalog.oId.map((id, i) => [id, i])); oracleMaps.set(catalog, ids); }
  const code = set.toLowerCase();
  for (const c of cards) {
    const oi = c.c ? ids.get(c.c) : undefined;
    if (oi == null) continue;
    let pick = -1;
    for (let p = catalog.pFirst[oi]; p < catalog.pFirst[oi] + catalog.pCount[oi]; p++) {
      if (catalog.pSet[p] === code && (pick < 0 || (catalog.pLang[p] === "en" && catalog.pLang[pick] !== "en"))) pick = p;
    }
    if (pick < 0) pick = catalog.oOriginal[oi] >= 0 ? catalog.oOriginal[oi] : catalog.pFirst[oi];
    out.set(c.n, { cost: catalog.oCost[oi], p: pick });
  }
  return out;
}

/** One card on the Limited page: its place, art, name, mana cost, rarity and games, and the sort's number with how far
 *  it sits from the average under it. */
function LimitedCardRow({ rank, c, face, catalog, value, vs, onClick }: {
  rank: number | null; c: LCard; face?: { cost: string; p: number }; catalog: Catalog | null; value: string; vs: string | null; onClick: () => void;
}) {
  return (
    <button type="button" onClick={onClick} className="w-full flex items-center gap-2.5 bg-t1-surface hover:bg-t1-surface-hover px-4 py-2 text-left">
      {rank != null && <span className="w-[22px] shrink-0 text-right text-[11px] text-t1-muted tabular-nums">{rank}</span>}
      <span className="w-[52px] h-[38px] shrink-0 bg-t1-bg overflow-hidden">
        {catalog && face && face.p >= 0 && <img src={cardImageUrl(catalog, face.p, "art_crop")} alt="" loading="lazy" className="w-full h-full object-cover" />}
      </span>
      <span className="flex-1 min-w-0 flex flex-col gap-1">
        <span className="text-[14px] truncate">{c.n}</span>
        <span className="flex items-center gap-1.5 min-w-0">
          {face?.cost && <ManaCost cost={face.cost} size={12} />}
          <span className="t1-label truncate">{[c.r ? c.r[0].toUpperCase() : null, `${c.gih_n.toLocaleString()} in hand`].filter(Boolean).join(" · ")}</span>
        </span>
      </span>
      <span className="shrink-0 flex flex-col items-end gap-0.5">
        <span className={`text-[14px] tabular-nums ${c.gih == null ? "text-t1-disabled" : ""}`}>{value}</span>
        {vs && <span className={`t1-label ${vs.startsWith("+") ? "text-t1-text" : ""}`}>{vs}</span>}
      </span>
    </button>
  );
}

/** A screen's one big action with a line of data under it (Rank this set): the words large, the data small. */
function RankAction({ title, detail, onClick }: { title: string; detail?: string; onClick: () => void }) {
  return (
    <button type="button" onClick={onClick} className="w-full min-h-[88px] px-4 flex flex-col items-center justify-center gap-2 bg-t1-surface hover:bg-t1-surface-hover border-t border-t1-text">
      <span className="text-[15px] font-semibold uppercase tracking-[4px]">{title}</span>
      {detail && <span className="t1-label text-center">{detail}</span>}
    </button>
  );
}

function LimitedHome() {
  const nav = useNavigate();
  const { limited, picks, index, error, stale, rankable, alerts } = useInsights();
  const { catalog } = useCatalog();
  const rank = useRankSet();
  useEffect(() => { void loadInsightsExtras(); }, []);
  const [sort, setSort] = useState("gih");
  const [rarity, setRarity] = useState<string[]>([]);
  const [color, setColor] = useState<string[]>([]);
  const [editing, setEditing] = useState(false);
  const [query, setQuery] = useState("");
  const [all, setAll] = useState(false);
  // Sets with no 17Lands data yet (spoiler season, or just out) lead the picker and open Rank this set; the packs follow
  // in the index's order. Edit hides any of them.
  const today = new Date().toISOString().slice(0, 10);
  const allChips = limitedPicker((index ?? []).filter((e) => e.kind === "limited").map((e) => ({ key: e.key, name: e.name })), rankable ?? [], today);
  const chips = shownChips(allChips, picks.hiddenSets);
  const current = chips.find((c) => c.key === picks.set) ?? chips.find((c) => c.pack) ?? chips[0];
  const soon = current && !current.pack ? (rankable ?? []).find((r) => r.key === current.key) : undefined;
  const nameOf = (k: string) => index?.find((e) => e.kind === "limited" && e.key === k)?.name ?? rankable?.find((r) => r.key === k)?.name;
  const { set, pack, events, event, group, view } = limitedPick(limited, current?.pack ? current.key : undefined, picks.event, picks.group);
  const rated = !!view?.cards.some((c) => c.r);
  const cards = useMemo(() => (view ? limitedCards(view.cards, sort, rarity, color) : []), [view, sort, rarity, color]);
  const faces = useMemo(() => (pack && view ? limitedFaces(catalog, pack.set_code, view.cards) : new Map()), [catalog, pack, view]);
  // The picker waits for the index and the sets to rank (kept on the device after the first visit), so it draws whole.
  if (!index || !rankable || !chips.length) {
    return (<>
      {stale && <Notice tone="info">{stale}</Notice>}
      {error ? <Notice tone="error">{error}</Notice>
        : <Notice tone="info">{index && rankable ? "No set has 17Lands data yet. A new set's numbers arrive about three weeks after it comes out on Arena." : "Loading draft data…"}</Notice>}
      {error && <GhostAction label="Try again" onClick={() => void loadInsights(true)} />}
      <NewSetsToRank />
    </>);
  }
  const setCell: FilterCell = {
    name: "Set", value: current.label, current: current.key,
    options: [...chips.map((c) => ({ value: c.key, label: c.label, detail: nameOf(c.key) !== c.label ? nameOf(c.key) : undefined })), { value: EDIT_VALUE, label: "Shown sets…" }],
    onPick: (v) => { if (v === EDIT_VALUE) setEditing(true); else { pick({ set: v }); setQuery(""); setAll(false); } },
  };
  const editor = editing && <ShownEditor title="Shown sets" which="hiddenSets" hidden={picks.hiddenSets} onDone={() => setEditing(false)}
                                          items={allChips.map((c) => ({ key: c.key, label: c.label, detail: nameOf(c.key) !== c.label ? nameOf(c.key) : undefined }))} />;
  const alertsRow = alerts != null && <SwitchRow label="New in Insights" detail="A push when a new set, cube or format arrives (in the apps)" on={alerts}
                                                 onChange={(v) => void setInsightsAlerts(v)} />;
  if (soon) {
    return (
      <Scroll>
        {stale && <Notice tone="info">{stale}</Notice>}
        <FilterRow cells={[setCell]} />
        {editor}
        <Notice tone="info">{soonText(soon, today)}</Notice>
        <RankAction title="Rank this set" detail={rankableDetail(soon)} onClick={() => rank(soon.key, soon.kind, "soon")} />
        {alertsRow}
      </Scroll>
    );
  }
  if (!pack || !view || !event) return <Scroll><FilterRow cells={[setCell]} />{editor}<Notice tone="info">Loading {set ? limitedLabel(set, nameOf(set)) : ""}…</Notice></Scroll>;
  const base = `/insights/limited/${pack.set_code}/${event}/${group}`;
  const cells: FilterCell[] = [setCell];
  if (events.length > 1) cells.push({ name: "Event", value: EVENT_LABELS[event] ?? event, current: event, options: events.map((e) => ({ value: e, label: EVENT_LABELS[e] ?? e })), onPick: (v) => pick({ event: v }) });
  if (pack.events[event].groups.top) {
    cells.push({ name: "Players", value: group === "top" ? "Top players" : "All players", current: group,
                 options: [{ value: "all", label: "All players" }, { value: "top", label: "Top players", detail: "60%+ win rate" }], onPick: (v) => pick({ group: v as "all" | "top" }) });
  }
  const shown = view.pairs.filter((p) => p.share >= 0.01).sort((a, b) => b.wr - a.wr);
  const lo = Math.max(0.4, Math.min(...shown.map((p) => p.wr)) - 0.02), hi = Math.min(0.7, Math.max(...shown.map((p) => p.wr)) + 0.01);
  const two = shown.filter((p) => p.p.length === 2 && p.p !== "3C").slice(0, 5);
  const pts = view.cards.filter((c) => c.gih != null && c.ata != null && c.gih_n >= 1000).map((c) => ({ id: c.n, label: c.n, x: c.ata!, y: c.gih! }));
  const sortOpt = LIMITED_SORTS.find((x) => x.value === sort);
  const searching = searchNorm(query).length >= MIN_QUERY;
  const hits = searching ? limitedSearch(query, view.cards.map((c) => c.n), Object.values(limited).filter((p) => p.set_code !== pack.set_code)
    .sort((a, b) => (b.released ?? "").localeCompare(a.released ?? ""))
    .map((p) => ({ key: p.set_code, names: [...new Set(Object.values(p.events).flatMap((e) => e.groups.all?.cards.map((c) => c.n) ?? []))].sort() }))) : null;
  const row = (c: LCard, i: number | null) => {
    const v = limitedValue(c, sort, view.wr);
    return <LimitedCardRow key={c.n} rank={i} c={c} face={faces.get(c.n)} catalog={catalog} value={v.value} vs={v.vs}
                           onClick={() => nav(`${base}/card/${encodeURIComponent(c.n)}`)} />;
  };
  const r = rankable?.find((x) => x.key === pack.set_code);
  const kind = r?.kind ?? (pack.cube ? "cube" : "set");
  return (
    <Scroll>
      {stale && <Notice tone="info">{stale}</Notice>}
      <FilterRow cells={cells} />
      {editor}
      <Section title={`Top cards · ${sortOpt?.label.toLowerCase() ?? sort}`} />
      <FilterRow cells={[
        { name: "Sort", value: sortOpt?.code ?? sort, current: sort, options: LIMITED_SORTS.map((x) => ({ value: x.value, label: x.label, detail: x.code })),
          onPick: (v) => { setSort(v); setAll(false); capture("insights_sort_changed", { sort: v }); } },
        ...(rated ? [{ name: "Rarity", value: rarityLabel(rarity), current: null, picked: rarity, options: LIMITED_RARITIES,
                       onPick: (v: string) => { setRarity((p) => togglePick(p, v)); setAll(false); } }] : []),
        { name: "Color", value: colorLabel(color), current: null, picked: color, options: LIMITED_COLORS.map((x) => ({ value: x.value, label: x.label })),
          onPick: (v) => { setColor((p) => togglePick(p, v)); setAll(false); } },
      ]} />
      <label className="flex items-center gap-2 bg-t1-surface px-4">
        <Icon d={ICON.search} />
        <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search cards" aria-label="Search cards"
               className="flex-1 min-w-0 bg-transparent py-3.5 outline-0 border-0 text-[15px] placeholder:text-t1-muted" />
        {query && <button type="button" className="t1-label" onClick={() => setQuery("")}>Clear</button>}
      </label>
      {hits ? (
        <>
          {hits.here.map((n) => { const c = view.cards.find((x) => x.n === n); return c ? row(c, null) : null; })}
          {!hits.here.length && hits.elsewhere.length > 0 && (
            <>
              <Section title={`Not in ${limitedLabel(pack.set_code, pack.name)} · in other sets`} />
              {hits.elsewhere.map(([k, n]) => (
                <Row key={`${k}|${n}`} title={n} detail={limitedLabel(k, nameOf(k))}
                     onClick={() => {
                       capture("insights_card_search_elsewhere", { set: k });
                       const other = limited[k];
                       const e = other ? EVENT_ORDER.find((x) => other.events[x]) ?? "PremierDraft" : "PremierDraft";
                       nav(`/insights/limited/${k}/${e}/all/card/${encodeURIComponent(n)}`);
                     }} />
              ))}
            </>
          )}
          {!hits.here.length && !hits.elsewhere.length && <Notice tone="info">No card in any set's draft data is called that.</Notice>}
        </>
      ) : (
        <>
          {(all ? cards : cards.slice(0, LIMITED_TOP)).map((c, i) => row(c, i + 1))}
          {!cards.length && <Notice tone="info">No card matches these filters.</Notice>}
          {cards.length > LIMITED_TOP && (
            <GhostAction label={all ? `Show the top ${LIMITED_TOP}` : `Show all ${cards.length}`}
                         onClick={() => { setAll(!all); if (!all) capture("insights_cards_expanded", { set: pack.set_code, count: cards.length }); }} />
          )}
        </>
      )}
      <Notice tone="info">GIH WR: win rate with the card in hand · OH: in the opening hand · IWD: improvement when drawn · ATA: average pick taken · under it: points above or below the average</Notice>
      <Section title="Color pairs · game win rate" />
      {shown.map((p) => (
        <ShareBar key={p.p} label={`${PAIR_NAMES[p.p] ?? p.p} ${p.p === "3C" ? "" : p.p}`} value={p.wr} max={hi} min={lo} reference={view.wr} format={pct1}
                  highlighted={p.p === shown[0]?.p} detail={`${pct(p.share)} of games · splash ${pct(p.splash)}`} onClick={() => nav(`${base}/pair/${p.p}`)} />
      ))}
      {(view.colors?.length ?? 0) > 0 && (() => {
        const rows = view.colors!.slice(0, 15);
        const clo = Math.max(0.35, Math.min(...rows.map((c) => c.wr)) - 0.02), chi = Math.min(0.75, Math.max(...rows.map((c) => c.wr)) + 0.01);
        const best = [...rows].sort((a, b) => b.wr - a.wr)[0];
        return (
          <>
            <Section title="Deck colors · with splashes, most played first" />
            {rows.map((c) => (
              <ShareBar key={`${c.m}+${c.s}`} label={colorsName(c.m, c.s)} value={c.wr} max={chi} min={clo} reference={view.wr} format={pct1}
                        highlighted={c === best} detail={`${pct(c.share)} of games · ${c.games.toLocaleString()} games`} />
            ))}
          </>
        );
      })()}
      {view.weeks >= 2 && (
        <>
          <Section title="Pairs by week · win rate" />
          <Chart>
            <LineChart count={view.weeks} height={170} labelWidth={90} format={pct1} fitY reference={{ label: "AVG", value: view.wr }} xLabels={Array.from({ length: view.weeks }, (_, i) => [i, `W${i + 1}`] as [number, string])}
                       series={two.map((p, k) => ({ id: p.p, label: p.p, values: p.week_wr, highlighted: k === 0 }))} />
          </Chart>
        </>
      )}
      {pts.length >= 20 && (
        <>
          <Section title="Taken vs win rate · above the line is taken too late" />
          <Chart><Scatter points={pts} onPick={(n) => nav(`${base}/card/${encodeURIComponent(n)}`)} /></Chart>
        </>
      )}
      <Section title="Game facts" />
      <Stats items={[["On the play", pct1(view.facts.play_wr)], ["On the draw", pct1(view.facts.draw_wr)], ["Turns", view.facts.turns?.toFixed(1) ?? "–"]]} />
      <Stats items={[["Mulligans", pct(view.facts.mull_rate)], ["Kept 7", pct1(view.facts.keep7_wr)], ["After a mull", pct1(view.facts.mull_wr)]]} />
      <Brief text={view.brief} scope={`${pack.name ?? pack.set_code} ${EVENT_LABELS[event] ?? event}${group === "top" ? ", top players (60%+)" : ""}`} thin={view.games < 20000}
             credit={{ label: "Data from 17Lands", url: pack.credit.url }} />
      <Stats items={[["Games", view.games.toLocaleString()], ["Average", pct1(view.wr)], ["Weeks", String(view.weeks)]]} />
      {alertsRow}
      <RankAction title={`Rank this ${kind === "cube" ? "cube" : "set"}`} onClick={() => rank(pack.set_code, kind, "set")}
                  detail={r && r.rankings > 0 ? rankableDetail(r) : "Stack-rank its cards by color, then a top 100. Compare with friends."} />
      <NewSetsToRank />
    </Scroll>
  );
}

export function InsightsPair() {
  const { set = "", event = "", group = "all", pair = "" } = useParams();
  const nav = useNavigate();
  const { limited, session, demo, ready } = useInsightsData();
  const pack = limited[set];
  const view = pack?.events[event]?.groups[group as "all" | "top"];
  const p = view?.pairs.find((x) => x.p === pair);
  if (!session && !demo) return <Screen><Bar title={pair} onBack={() => nav(-1)} />{ready && <SignInFirst />}</Screen>;
  const best = (view?.cards ?? []).flatMap((c) => (c.pair_gih?.[pair] != null ? [[c, c.pair_gih[pair]] as const] : [])).sort((a, b) => b[1] - a[1]).slice(0, 20);
  return (
    <Screen>
      <Bar title={`${PAIR_NAMES[pair] ?? pair} ${pair}`} subtitle={`${limitedLabel(set, pack?.name)} ${EVENT_LABELS[event] ?? event}`} onBack={() => nav(-1)} />
      {!p || !view || !pack ? <Notice tone="info">This pair isn't in the pack.</Notice> : (
        <Scroll>
          <a href={pack.credit.url} target="_blank" rel="noreferrer" className="bg-t1-surface px-4 py-2.5 t1-label underline">Data from 17Lands</a>
          <Stats items={[["Win rate", pct1(p.wr)], ["Of games", pct(p.share)], ["Splash", pct(p.splash)]]} />
          <Stats items={[["On the play", pct1(p.play_wr)], ["On the draw", pct1(p.draw_wr)], ["Games", p.games.toLocaleString()]]} />
          {view.weeks >= 2 && (
            <>
              <Section title="Win rate by week" />
              <Chart><LineChart count={view.weeks} height={150} labelWidth={60} format={pct1} xLabels={Array.from({ length: view.weeks }, (_, i) => [i, `W${i + 1}`] as [number, string])}
                                series={[{ id: pair, label: pair, values: p.week_wr, highlighted: true }]} /></Chart>
            </>
          )}
          <Section title={`Best cards in ${pair} · win rate in hand`} />
          {best.map(([c, wr]) => <Row key={c.n} title={c.n} value={pct1(wr)} detail={[(c.r ? c.r[0].toUpperCase() + c.r.slice(1) : null), c.col].filter(Boolean).join(" · ")}
                                      onClick={() => nav(`/insights/limited/${set}/${event}/${group}/card/${encodeURIComponent(c.n)}`)} />)}
        </Scroll>
      )}
    </Screen>
  );
}

export function InsightsLimitedCard() {
  const { set = "", event = "", group = "all", name = "" } = useParams();
  const nav = useNavigate();
  const { limited, session, demo, ready } = useInsightsData();
  const pack = limited[set];
  const view = pack?.events[event]?.groups[group as "all" | "top"];
  const c = view?.cards.find((x) => x.n === name);
  const { catalog } = useCatalog();
  const face = useMemo(() => (c ? limitedFaces(catalog, set, [c]).get(c.n) : undefined), [catalog, set, c]);
  if (!session && !demo) return <Screen><Bar title={name} onBack={() => nav(-1)} />{ready && <SignInFirst />}</Screen>;
  const pairs = Object.entries(c?.pair_gih ?? {}).sort((a, b) => b[1] - a[1]);
  const lo = Math.max(0.35, Math.min(...pairs.map(([, v]) => v)) - 0.02), hi = Math.min(0.8, Math.max(...pairs.map(([, v]) => v)) + 0.01);
  return (
    <Screen>
      <Bar title={name} subtitle={`${limitedLabel(set, pack?.name)} ${EVENT_LABELS[event] ?? event}`} onBack={() => nav(-1)} />
      {!c || !view || !pack ? <Notice tone="info">This card isn't in the pack.</Notice> : (
        <Scroll>
          {face && catalog && (
            <div className="flex flex-col items-center gap-3 py-5">
              {face.p >= 0 && <img src={cardImageUrl(catalog, face.p, "normal")} alt={c.n} className="w-[220px] rounded-[9px]" />}
              {face.cost && <ManaCost cost={face.cost} size={16} />}
            </div>
          )}
          <a href={pack.credit.url} target="_blank" rel="noreferrer" className="bg-t1-surface px-4 py-2.5 t1-label underline">Data from 17Lands</a>
          {c.gih == null && <Notice tone="info">Fewer than 500 games with this card in hand: no win rates yet.</Notice>}
          <Stats items={[["In hand", pct1(c.gih)], ["Opening hand", pct1(c.oh)], ["Drawn", pct1(c.gd)]]} />
          <Stats items={[["Not seen", pct1(c.gns)], ["IWD", c.iwd == null ? "–" : delta(c.iwd)], ["Taken at", c.ata?.toFixed(1) ?? "–"]]} />
          <Stats items={[["In decks", pct(c.deck)], ["Games in hand", c.gih_n.toLocaleString()], ["Rarity", c.r ?? "–"]]} />
          {c.week_gih && view.weeks >= 2 && (
            <>
              <Section title="Win rate in hand by week" />
              <Chart><LineChart count={view.weeks} height={150} labelWidth={50} format={pct1} xLabels={Array.from({ length: view.weeks }, (_, i) => [i, `W${i + 1}`] as [number, string])}
                                series={[{ id: "w", label: "", values: c.week_gih, highlighted: true }]} /></Chart>
            </>
          )}
          {pairs.length > 0 && <Section title="By color pair · in hand" />}
          {pairs.map(([k, wr], i) => (
            <ShareBar key={k} label={`${PAIR_NAMES[k] ?? k} ${k}`} value={wr} max={hi} min={lo} reference={c.gih} format={pct1} highlighted={i === 0}
                      onClick={() => nav(`/insights/limited/${set}/${event}/${group}/pair/${k}`)} />
          ))}
          {c.c && <Row title="Open the card" detail="Prices, printings and your copies" onClick={() => nav(`/library/card/${c.c}`)} />}
        </Scroll>
      )}
    </Screen>
  );
}

/* ── review (moderators) ──────────────────────────────────────────────── */

interface Review {
  archetypes: { id: number; format: string; name: string; family: string; colors: string; signature: string[]; decks: number | null; missing: string[]; blocked: boolean }[];
  changes: { id: number; format: string; on: string; kind: string; cards: string[] }[];
  unmatched: { source: string; name: string; seen: number; last_seen: string }[];
}

export function InsightsReview() {
  const nav = useNavigate();
  const [review, setReview] = useState<Review | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [names, setNames] = useState<Record<number, string>>({});
  const load = async () => {
    const { data, error: e } = await supabase.rpc("insights_review");
    if (e) setError(e.message); else { setReview(data as Review); setError(null); }
  };
  useEffect(() => { void load(); }, []);
  const act = async (fn: string, args: Record<string, unknown>) => {
    const { error: e } = await supabase.rpc(fn, args);
    if (e) { setError(e.message); return; }
    capture("insights_review_action", { what: fn, action: String(args.p_action) });
    await load();
  };
  const btn = (label: string, onClick: () => void) => (
    <button type="button" onClick={onClick} className="flex-1 bg-t1-surface hover:bg-t1-surface-hover py-3 t1-label text-t1-text">{label}</button>
  );
  return (
    <Screen>
      <Bar title="Review" subtitle="Archetypes and bans" onBack={() => nav(-1)} />
      {error && <Notice tone="error">{error}</Notice>}
      {!review && !error && <Notice tone="info">Loading…</Notice>}
      {review && (
        <Scroll>
          <Section title="Proposed archetypes" count={review.archetypes.length} />
          {!review.archetypes.length && <Notice tone="info">Nothing proposed.</Notice>}
          {review.archetypes.map((a) => (
            <div key={a.id} className="flex flex-col gap-px">
              <Row title={a.name} detail={`${a.format} · ${a.family} · ${a.colors || "colorless"} · ${a.decks ?? 0} decks`} />
              <Notice tone="info">{a.signature.slice(0, 10).join(", ")}{a.missing.length ? ` · Not in the catalog: ${a.missing.join(", ")}` : ""}</Notice>
              <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
                <span className="t1-label">Name</span>
                <input value={names[a.id] ?? a.name} onChange={(e) => setNames({ ...names, [a.id]: e.target.value })}
                       className="bg-transparent outline-0 text-[15px]" />
              </label>
              <div className="flex gap-px">
                {btn("Approve", () => void act("insights_review_archetype", { p_id: a.id, p_action: "approve", p_name: names[a.id] ?? null }))}
                {btn("Reject", () => void act("insights_review_archetype", { p_id: a.id, p_action: "reject" }))}
              </div>
            </div>
          ))}
          <Section title="Proposed format changes" count={review.changes.length} />
          {!review.changes.length && <Notice tone="info">Nothing proposed.</Notice>}
          {review.changes.map((c) => (
            <div key={c.id} className="flex flex-col gap-px">
              <Row title={`${c.kind}: ${c.cards.slice(0, 4).join(", ")}${c.cards.length > 4 ? "…" : ""}`} detail={`${c.format} · ${shortDay(c.on)}`} />
              <div className="flex gap-px">
                {btn("Confirm", () => void act("insights_review_change", { p_id: c.id, p_action: "confirm" }))}
                {btn("Reject", () => void act("insights_review_change", { p_id: c.id, p_action: "reject" }))}
              </div>
            </div>
          ))}
          <Section title="Names the catalog doesn't know" />
          {review.unmatched.map((u) => <Row key={`${u.source}${u.name}`} title={u.name} detail={`${u.source} · seen ${u.seen}× · last ${shortDay(u.last_seen)}`} />)}
        </Scroll>
      )}
    </Screen>
  );
}
