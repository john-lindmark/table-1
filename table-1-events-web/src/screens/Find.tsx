import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Avatar } from "../components/Avatar";
import { FoundEventRow, Over } from "../components/EventListing";
import { FilterRow, type FilterCell } from "../components/FilterRow";
import { BAR_ICON, Icon, IconButton } from "../components/icons";
import { Bar, BigAction, Field, GhostAction, Notice, Row, Screen, Section, TabBar } from "../components/kit";
import {
  FORMAT_KEYS, KM_PICKS, NO_FILTERS, WHEN_PICKS, boardLine, filterLabels, filtersWire, findEvents, formatBoards, formatKeyLabel,
  formatLeaderboard, demoPath, isFiltered, isMissing, leagueCreate, leagueLine, leaguesDemoOn, leaguesError, leaguesHome, loadFindFilters, recordText,
  saveFindFilters,
  type Board, type BoardRow, type FindFilters, type FindScope, type FoundEvent, type LeagueCard, type Leaderboard, type LeaguesHome, type WhenPick,
} from "../lib/leagues";
import { currentFix } from "../lib/nearby";
import { useOpenProfile } from "../lib/personLink";
import { capture } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/* Finding events, leagues and boards (contract/public-events-leagues-2026-11-13.md §§ 1, 3, 4): the Events home's
   Find events section, Find (/find: Events | Leagues | Boards, signed in or out) and a board (/boards/<key>). */

type Here = { lat: number; lng: number };

/** One location reading for distances, asked only when a distance is picked. Never stored. */
async function place(): Promise<Here | null> {
  if (leaguesDemoOn()) return { lat: 39.74, lng: -104.99 };
  const fix = await currentFix(8000);
  return fix ? { lat: fix.lat, lng: fix.lng } : null;
}

/** Whether the browser already lets this site read the location (so a kept distance can apply without asking). */
async function placeAllowed(): Promise<boolean> {
  if (leaguesDemoOn()) return true;
  try {
    const p = await navigator.permissions?.query({ name: "geolocation" as PermissionName });
    return p?.state === "granted";
  } catch {
    return false;
  }
}

/** The events you can find under the picks this device keeps, and the filter row that changes them. */
function useFound(q: string, limit: number, signedIn: boolean) {
  const [filters, setFilters] = useState<FindFilters>(loadFindFilters);
  const [here, setHere] = useState<Here | null>(null);
  /** A kept distance waits for the place before the first load. */
  const [placing, setPlacing] = useState(() => filters.km != null);
  const [events, setEvents] = useState<FoundEvent[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const seq = useRef(0);

  const change = useCallback((next: FindFilters, filter: string) => {
    setFilters(next);
    saveFindFilters(next);
    capture("find_filtered", { filter });
  }, []);

  // A distance kept from last time applies only where location is already allowed; it never asks on its own.
  useEffect(() => {
    if (!placing) return;
    let live = true;
    void (async () => {
      const fix = (await placeAllowed()) ? await place() : null;
      if (!live) return;
      if (fix) setHere(fix);
      else setFilters((f) => { const next = { ...f, km: null }; saveFindFilters(next); return next; });
      setPlacing(false);
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Signed out there are no friends events: a kept Friends pick reads All.
  const used = useMemo(() => (signedIn || filters.scope !== "friends" ? filters : { ...filters, scope: "all" as FindScope }), [filters, signedIn]);
  const wire = useMemo(() => JSON.stringify(filtersWire(used, { here, q })), [used, here, q]);
  const load = useCallback(async () => {
    const mine = ++seq.current;
    try {
      const rows = await findEvents(JSON.parse(wire), limit);
      if (mine !== seq.current) return;
      setEvents(rows);
      setError(null);
    } catch (e) {
      if (mine === seq.current) setError(e);
    }
  }, [wire, limit]);
  useEffect(() => {
    if (!placing) void load();
  }, [load, placing]);

  const pickKm = async (km: number | null) => {
    setNotice(null);
    if (km == null) return change({ ...filters, km: null }, "where");
    const fix = here ?? (await place());
    if (!fix) {
      // Refused or unavailable: Everywhere.
      setNotice("Location is off, so this shows events everywhere.");
      return change({ ...filters, km: null }, "where");
    }
    setHere(fix);
    change({ ...filters, km }, "where");
  };

  const labels = filterLabels(used);
  const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : FORMAT_KEYS.map((k) => k.key).filter((k) => k === v || list.includes(k)));
  const cells: FilterCell[] = [
    { name: "Format", value: labels.format, current: null, picked: used.formats,
      options: [{ value: "all", label: "Any format" }, ...FORMAT_KEYS.map((f) => ({ value: f.key, label: f.label }))],
      onPick: (v) => change({ ...filters, formats: v === "all" ? [] : toggle(filters.formats, v) }, "format") },
    { name: "Where", value: labels.where, current: String(used.km ?? 0),
      options: [{ value: "0", label: "Everywhere" }, ...KM_PICKS.map((k) => ({ value: String(k), label: `${k} km` }))],
      onPick: (v) => void pickKm(Number(v) || null) },
    { name: "When", value: labels.when, current: used.when, options: WHEN_PICKS,
      onPick: (v) => change({ ...filters, when: v as WhenPick }, "when") },
    { name: "More", value: labels.more, current: null, picked: [],
      options: [
        ...(signedIn ? [
          { value: "scope_all", label: "All", detail: "Listed", on: used.scope === "all" },
          { value: "scope_public", label: "Public", detail: "Listed", on: used.scope === "public" },
          { value: "scope_friends", label: "Friends", detail: "Listed", on: used.scope === "friends" },
        ] : []),
        { value: "team", label: "Team events", on: used.team },
        { value: "league", label: "League events", on: used.league },
        { value: "open", label: "Seats left", on: used.open },
      ],
      onPick: (v) => change(
        v.startsWith("scope_") ? { ...filters, scope: v.slice(6) as FindScope }
          : v === "team" ? { ...filters, team: !filters.team } : v === "league" ? { ...filters, league: !filters.league } : { ...filters, open: !filters.open },
        "more") },
  ];
  const clear = () => {
    setNotice(null);
    change({ ...NO_FILTERS }, "clear");
  };
  return { filters: used, cells, events, error, notice, load, clear, filtered: isFiltered(used, q) };
}

const noTelemetry = () => {};

/**
 * The Events home's Find events (under your own events): the filter row, the first five and All N. An extra: while
 * the server part isn't live, or the call fails, it draws nothing.
 */
export function FindEventsSection({ onCreate }: { onCreate?: () => void }) {
  const f = useFound("", 50, true);
  if (f.error || f.events === null) return null;
  const rows = f.events;
  return (
    <>
      <Link to={demoPath("/find")} className="bg-t1-surface hover:bg-t1-surface-hover px-4 h-[50px] flex items-center justify-between gap-3">
        <span className="text-[12px] uppercase tracking-[2px]">Find events</span>
        <Icon d={BAR_ICON.arrow} />
      </Link>
      <FilterRow cells={f.cells} telemetry={noTelemetry} dense />
      {f.notice && <Notice tone="info">{f.notice}</Notice>}
      {rows.slice(0, 5).map((e) => <FoundEventRow key={e.event_id} event={e} from="home" />)}
      {rows.length > 5 && (
        <Link to={demoPath("/find")} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center justify-between gap-3">
          <span className="text-[13px]">All {rows.length}</span>
          <Icon d={BAR_ICON.arrow} />
        </Link>
      )}
      {rows.length === 0 && <NoEvents filtered={f.filtered} onClear={f.clear} onCreate={onCreate} />}
    </>
  );
}

function NoEvents({ filtered, onClear, onCreate }: { filtered: boolean; onClear: () => void; onCreate?: () => void }) {
  return filtered ? (
    <Row title="No events match" action={{ label: "Clear filters", onClick: onClear }} />
  ) : (
    <Row title="No public events yet" action={onCreate ? { label: "Create an event", onClick: onCreate } : undefined} />
  );
}

function SearchBox({ value, onChange, placeholder, label }: { value: string; onChange: (v: string) => void; placeholder: string; label: string }) {
  return (
    <label className="shrink-0 bg-t1-surface px-4 h-[50px] flex items-center gap-3">
      <span className="text-t1-muted"><Icon d={BAR_ICON.search} /></span>
      <input type="text" enterKeyHint="search" value={value} autoCapitalize="off" autoCorrect="off" spellCheck={false} aria-label={label}
             placeholder={placeholder} onChange={(e) => onChange(e.target.value)}
             className="flex-1 min-w-0 bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60" />
      {value && <button type="button" className="t1-label !text-t1-text" onClick={() => onChange("")}>Clear</button>}
    </label>
  );
}

/** What was typed, 0.25 s after the last key. */
function useDebounced(value: string, ms = 250): string {
  const [v, setV] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setV(value), ms);
    return () => window.clearTimeout(id);
  }, [value, ms]);
  return v;
}

/** A failed load: the error, and Try again. */
function Failed({ error, retry }: { error: unknown; retry: () => void }) {
  return (
    <>
      <Notice tone={isMissing(error) ? "info" : "error"}>{leaguesError(error)}</Notice>
      <div className="flex"><GhostAction label="Try again" onClick={retry} /></div>
    </>
  );
}

type FindTab = "events" | "leagues" | "boards";
const TABS: FindTab[] = ["events", "leagues", "boards"];

/** Find: Events | Leagues | Boards. Signed out: public events, the league search, boards by name. */
export function FindScreen({ onBack }: { onBack: () => void }) {
  const [params, setParams] = useSearchParams();
  const real = useSession();
  const signedIn = !!real.session || leaguesDemoOn();
  const tab: FindTab = TABS.find((t) => t === params.get("tab")) ?? "events";
  const [creating, setCreating] = useState(false);
  const navigate = useNavigate();
  useEffect(() => {
    capture("find_opened", { tab });
  }, [tab]);
  return (
    <Screen>
      <Bar title="Find" onBack={onBack}
           right={tab === "leagues" && signedIn ? <IconButton label="New league" onClick={() => setCreating(true)}><Icon d={BAR_ICON.plus} /></IconButton> : undefined} />
      <TabBar tabs={TABS} value={tab} labels={{ events: "Events", leagues: "Leagues", boards: "Boards" }}
              onChange={(t) => setParams({ ...(t === "events" ? {} : { tab: t }), ...(leaguesDemoOn() ? { demo: "" } : {}) }, { replace: true })} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {tab === "events" && real.ready && <EventsTab signedIn={signedIn} />}
        {tab === "leagues" && real.ready && <LeaguesTab signedIn={signedIn} />}
        {tab === "boards" && real.ready && <BoardsTab />}
      </div>
      {creating && <NewLeaguePanel onClose={() => setCreating(false)} onCreated={(slug) => navigate(demoPath(`/league/${slug}`))} />}
    </Screen>
  );
}

function EventsTab({ signedIn }: { signedIn: boolean }) {
  const [q, setQ] = useState("");
  const f = useFound(useDebounced(q), 100, signedIn);
  const navigate = useNavigate();
  return (
    <>
      <SearchBox value={q} onChange={setQ} placeholder="Name, venue or league" label="Search events" />
      <FilterRow cells={f.cells} telemetry={noTelemetry} dense />
      {f.notice && <Notice tone="info">{f.notice}</Notice>}
      {f.error ? <Failed error={f.error} retry={() => void f.load()} />
        : f.events === null ? <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>
        : f.events.length === 0 ? <NoEvents filtered={f.filtered} onClear={() => { setQ(""); f.clear(); }} onCreate={signedIn ? () => navigate("/") : undefined} />
        : f.events.map((e) => <FoundEventRow key={e.event_id} event={e} from="find" />)}
    </>
  );
}

function LeagueRow({ card }: { card: LeagueCard }) {
  return (
    <Link to={demoPath(`/league/${card.slug}`)} state={{ from: "find" }}
          className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex flex-col gap-0.5">
      <span className="text-[14px] truncate">{card.name}</span>
      {leagueLine(card) && <span className="t1-label truncate">{leagueLine(card)}</span>}
    </Link>
  );
}

function LeaguesTab({ signedIn }: { signedIn: boolean }) {
  const [q, setQ] = useState("");
  const query = useDebounced(q);
  const [home, setHome] = useState<LeaguesHome | null>(null);
  const [error, setError] = useState<unknown>(null);
  const load = useCallback(async () => {
    try {
      setHome(await leaguesHome(query));
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, [query]);
  useEffect(() => void load(), [load]);
  const searching = query.trim().length >= 2;
  return (
    <>
      {error ? <Failed error={error} retry={() => void load()} /> : home === null ? <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div> : (
        <>
          {home.mine.length > 0 && <Section title="Yours" />}
          {home.mine.map((c) => <LeagueRow key={c.id} card={c} />)}
          {home.following.length > 0 && <Section title="Following" />}
          {home.following.map((c) => <LeagueRow key={c.id} card={c} />)}
          {signedIn && (home.mine.length > 0 || home.following.length > 0) && <Section title="Search" />}
          <SearchBox value={q} onChange={setQ} placeholder="Name or region" label="Search leagues" />
          {home.found.map((c) => <LeagueRow key={c.id} card={c} />)}
          {searching && home.found.length === 0 && <div className="bg-t1-surface px-4 py-4 t1-label">No leagues match</div>}
        </>
      )}
    </>
  );
}

function BoardsTab() {
  const [boards, setBoards] = useState<Board[] | null>(null);
  const [error, setError] = useState<unknown>(null);
  const load = useCallback(async () => {
    try {
      setBoards((await formatBoards()).boards);
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, []);
  useEffect(() => void load(), [load]);
  if (error) return <Failed error={error} retry={() => void load()} />;
  if (!boards) return <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>;
  return (
    <>
      {boards.map((b) => (
        <Link key={b.board} to={demoPath(`/boards/${b.board}`)} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex flex-col gap-0.5">
          <span className="text-[13px] uppercase tracking-[1.5px] truncate">{b.label}</span>
          <span className="t1-label truncate">{boardLine(b)}</span>
        </Link>
      ))}
    </>
  );
}

/** Find → Leagues → +: a league's name, region, description and link. */
export function NewLeaguePanel({ onClose, onCreated }: { onClose: () => void; onCreated: (slug: string) => void }) {
  const [name, setName] = useState("");
  const [region, setRegion] = useState("");
  const [link, setLink] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const ok = name.trim().length >= 2;
  const save = async () => {
    setBusy(true);
    try {
      const l = await leagueCreate({ name, region, link, description });
      onCreated(l.slug);
    } catch (e) {
      setError(leaguesError(e));
      setBusy(false);
    }
  };
  return (
    <Over title="New league" onBack={onClose} bottom={<BigAction label="Create league" tone="accent" busy={busy} disabled={!ok} onClick={() => void save()} />}>
      <Field label="Name" value={name} onChange={(v) => setName(v.slice(0, 60))} autoFocus />
      <Field label="Region" value={region} onChange={(v) => setRegion(v.slice(0, 80))} placeholder="Denver, Colorado" />
      <Field label="Link" value={link} onChange={(v) => setLink(v.slice(0, 300))} placeholder="https://" />
      <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
        <span className="t1-label">Description</span>
        <textarea value={description} rows={5} onChange={(e) => setDescription(e.target.value.slice(0, 2000))}
                  className="bg-transparent border-0 outline-0 text-[15px] leading-[22px] resize-none w-full" />
      </label>
      {error && <Notice tone="error">{error}</Notice>}
    </Over>
  );
}

/* ── a board ─────────────────────────────────────────────────────────── */

const PAGE = 100;

/** A format board: your rating large with rank and record when you have one, then rank · name · rating. Signed out:
 *  names only. */
export function BoardScreen({ board, onBack }: { board: string; onBack: () => void }) {
  const [data, setData] = useState<Leaderboard | null>(null);
  const [rows, setRows] = useState<BoardRow[]>([]);
  const [error, setError] = useState<unknown>(null);
  const [more, setMore] = useState(false);
  const open = useOpenProfile("board");
  const load = useCallback(async () => {
    try {
      const d = await formatLeaderboard(board, 0, PAGE);
      setData(d);
      setRows(d.rows);
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, [board]);
  useEffect(() => {
    capture("board_opened", { board });
    void load();
  }, [board, load]);
  const loadMore = async () => {
    setMore(true);
    try {
      const d = await formatLeaderboard(board, rows.length, PAGE);
      setRows((r) => [...r, ...d.rows]);
    } catch (e) {
      setError(e);
    } finally {
      setMore(false);
    }
  };
  const me = data?.me;
  return (
    <Screen>
      <Bar title={data?.label ?? formatKeyLabel(board)} onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {error ? <Failed error={error} retry={() => void load()} /> : !data ? <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div> : (
          <>
            {me && (
              <div className="bg-t1-bg px-4 py-6 flex flex-col items-center gap-1">
                <p className="t1-label">Your rating</p>
                <p className="text-[48px] leading-[56px] tabular-nums tracking-[4px] text-t1-accent">{me.rating}</p>
                <p className="t1-label">
                  {[me.rank ? `#${me.rank} of ${data.count}` : me.to_go > 0 ? `${me.to_go} to go` : "Not listed", recordText(me),
                    `${me.events} ${me.events === 1 ? "event" : "events"}`].join(" · ")}
                </p>
              </div>
            )}
            {rows.length === 0 && <div className="bg-t1-surface px-4 py-6 t1-label">Nobody listed yet</div>}
            {rows.map((r, i) => {
              const tap = open(r.user_id);
              const body = (
                <>
                  <span className="w-8 shrink-0 text-[13px] tabular-nums text-t1-muted">{r.rank}</span>
                  {r.user_id && <Avatar name={r.name} userId={r.user_id} />}
                  <span className="flex-1 min-w-0 flex flex-col gap-0.5">
                    <span className="text-[14px] truncate">{r.name}</span>
                    <span className="t1-label">{recordText(r)}</span>
                  </span>
                  <span className="shrink-0 text-[15px] tabular-nums">{r.rating}</span>
                </>
              );
              const mine = !!me?.rank && me.rank === r.rank && me.rating === r.rating && r.matches === me.matches;
              const cls = `bg-t1-surface px-4 py-3 flex items-center gap-3 text-left w-full ${mine ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`;
              return tap ? <button key={`${r.rank}-${i}`} type="button" onClick={tap} className={`${cls} hover:bg-t1-surface-hover`}>{body}</button>
                : <div key={`${r.rank}-${i}`} className={cls}>{body}</div>;
            })}
            {rows.length < data.count && rows.length > 0 && (
              <div className="flex"><GhostAction label={more ? "Loading…" : `More · ${rows.length} of ${data.count}`} disabled={more} onClick={() => void loadMore()} /></div>
            )}
          </>
        )}
      </div>
    </Screen>
  );
}
