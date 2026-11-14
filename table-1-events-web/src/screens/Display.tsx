import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { T1Logo, useNow } from "../components/kit";
import { fetchPublicEvent, fetchPublicStandingsAndBracket, subscribeToEvent, type PublicEvent, type PublicStandingRow, type PublicTeamRow } from "../lib/api";
import {
  PAGE_SECONDS,
  RELOAD_SECONDS,
  clockWord,
  displayClock,
  displayPages,
  displaySize,
  displayView,
  elapsedSeconds,
  fitScale,
  fitType,
  listScale,
  pageAt,
  pairingsByPlayer,
  pairingsByTable,
  parseShow,
  resultsCount,
  scaled,
  showForKey,
  type ClockState,
  type DisplayData,
  type DisplayShow,
  type DisplaySize,
  type DisplayView,
  type PlayerRow,
  type TableRow,
} from "../lib/display";
import { roundName, when } from "../lib/scheduledEvents";
import { formatPct } from "../lib/standings";
import { capture } from "../lib/telemetry";
import { useQr } from "../lib/useQr";
import { useWakeLock } from "../lib/useWakeLock";

/**
 * table-1.site/d/<event>: the event on a TV, projector or cast tab (contract/public-events-leagues-2026-11-13.md § 5).
 * Full screen and nothing to press: the round clock, the pairings (by table and A–Z) and the standings, each as
 * large as fits, paging every 10 s when a list is longer than the screen. Before round 1 it's the event's name, start
 * time and sign-up QR; after the finish, the final standings. It reads what the shared standings page reads
 * (event_public and the engine's standings), so it works signed out for public and link events, and reloads on the
 * event's broadcast and every 15 s. `?show=auto|clock|pairings|standings`; keys 1 2 3 A F and the arrows.
 */
export function DisplayScreen({ eventId }: { eventId: string }) {
  const params = new URLSearchParams(window.location.search);
  const demo = import.meta.env.DEV && params.has("demo");
  const [data, setData] = useState<DisplayData | null>(null);
  const [missing, setMissing] = useState(false);
  const [show, setShow] = useState<DisplayShow>(() => parseShow(params.get("show")));
  const [turns, setTurns] = useState({ pairings: 0, standings: 0 });
  // Bumped by an arrow key, so the next automatic page turn waits a full 10 s again.
  const [nudge, setNudge] = useState(0);
  const [window_, setWindow] = useState(() => ({ width: window.innerWidth, height: window.innerHeight }));
  const opened = useRef(Date.now());
  const now = useNow(true, 500);

  const load = useCallback(async () => {
    try {
      if (import.meta.env.DEV && demo) {
        // Dev only (a production build drops this branch and the file): stand-in events from lib/displayDemo.ts.
        // The round's clock runs from when the page opened.
        const { demoDisplay } = await import("../lib/displayDemo");
        const q = new URLSearchParams(window.location.search);
        const num = (k: string) => (q.has(k) ? Number(q.get(k)) : undefined);
        const made = demoDisplay(eventId, { now: opened.current, elapsed: num("elapsed"), resultsIn: num("in") });
        if (!made) throw new Error("That event isn't available");
        setData(made);
      } else {
        const [event, standings] = await Promise.all([fetchPublicEvent(eventId), fetchPublicStandingsAndBracket(eventId)]);
        setData({ event, standings });
      }
      setMissing(false);
    } catch {
      // A failed refresh keeps what's on screen; with nothing to show yet, the event isn't available (and the next
      // read may find it: a private event once its organizer signs in, or the network coming back).
      setMissing(true);
    }
  }, [eventId, demo]);

  useEffect(() => {
    void load();
    const unsubscribe = demo ? () => {} : subscribeToEvent(eventId, () => void load());
    const poll = window.setInterval(() => void load(), RELOAD_SECONDS * 1000);
    return () => {
      unsubscribe();
      window.clearInterval(poll);
    };
  }, [eventId, demo, load]);

  // Once per mount, also under StrictMode's double effects.
  const counted = useRef(false);
  useEffect(() => {
    if (counted.current) return;
    counted.current = true;
    capture("display_opened", { show: parseShow(new URLSearchParams(window.location.search).get("show")) });
  }, []);

  useEffect(() => {
    const onResize = () => setWindow({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  // The screen is kept awake while the display is open.
  useWakeLock();
  useIdleCursor();

  const event = data?.event ?? null;
  const size = displaySize(window_.width, window_.height);
  const view = event ? viewOf(show, event, now, opened.current) : null;

  // Lists longer than the screen turn a page every 10 s, each from where it left off the last time it showed.
  useEffect(() => {
    if (view !== "pairings" && view !== "standings") return;
    const id = window.setInterval(() => setTurns((t) => ({ ...t, [view]: t[view] + 1 })), PAGE_SECONDS * 1000);
    return () => window.clearInterval(id);
  }, [view, nudge]);

  // A new round's pairings start on their first page.
  const round = event?.currentRound ?? 0;
  useEffect(() => setTurns((t) => ({ ...t, pairings: 0 })), [round]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const picked = showForKey(e.key);
      if (picked) {
        setShow(picked);
        // The address keeps the pick, so a reload (or the TV's browser restoring the tab) comes back to it.
        const q = new URLSearchParams(window.location.search);
        if (picked === "auto") q.delete("show");
        else q.set("show", picked);
        const rest = q.toString().replace(/=(?=&|$)/g, "");
        window.history.replaceState(window.history.state, "", `${window.location.pathname}${rest ? `?${rest}` : ""}`);
      } else if (e.key.toLowerCase() === "f") {
        if (document.fullscreenElement) void document.exitFullscreen?.();
        else void document.documentElement.requestFullscreen?.().catch(() => {});
      } else if (e.key.startsWith("Arrow") && (view === "pairings" || view === "standings")) {
        const by = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : -1;
        setTurns((t) => ({ ...t, [view]: t[view] + by }));
        setNudge((n) => n + 1);
      } else {
        return;
      }
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [view]);

  if (!data || !view) return <DisplayMessage size={size}>{missing ? "This event isn't available" : null}</DisplayMessage>;
  if (data.event.status === "cancelled") return <DisplayMessage size={size}>This event was cancelled</DisplayMessage>;
  return <DisplayFrame data={data} view={view} now={now} size={size} height={window_.height} width={window_.width}
                       turns={turns} origin={window.location.origin} />;
}

/** The matches the open round holds (between rounds, the last round's). */
const roundMatches = (event: PublicEvent) => (event.round ? event.pairings : event.rounds[0]?.matches ?? []);

/** The view for an event right now: the pick from `?show=` or the keys, or what auto says. */
export function viewOf(show: DisplayShow, event: PublicEvent, now: number, opened: number): DisplayView {
  const { resultsIn, matches } = resultsCount(roundMatches(event));
  return displayView(show, {
    status: event.status, round: event.currentRound, roundOpen: !!event.round, resultsIn, matches,
    elapsed: event.round ? elapsedSeconds(event.round, now) : 0, t: Math.max(0, Math.floor((now - opened) / 1000)),
  });
}

/** "ROUND 3 OF 5", "SEMIFINALS". */
export function roundLabel(event: PublicEvent): string {
  return roundName(event.round?.stage, event.round?.number ?? event.currentRound, event.numberOfRounds).toUpperCase();
}

const CLOCK_COLOR: Record<ClockState, string> = {
  off: "text-t1-text", running: "text-t1-text", low: "text-t1-warning", over: "text-t1-danger", paused: "text-t1-muted",
};
const LABEL = "uppercase text-t1-muted";
const label = (px: number): CSSProperties => ({ fontSize: px, letterSpacing: `${Math.max(1, px * 0.12)}px`, lineHeight: 1.2 });

/** The whole screen for an event that can be shown: one bar, the view, one foot line. Pure: everything comes in. */
export function DisplayFrame({ data, view, now, size, width, height, turns, origin }: {
  data: DisplayData; view: DisplayView; now: number; size: DisplaySize; width: number; height: number;
  turns: { pairings: number; standings: number }; origin: string;
}) {
  const { event, standings } = data;
  const u = (n: number) => Math.round(n * size.unit);
  const final = event.status === "completed" || event.status === "archived";
  const clock = displayClock(event.round, now, event.showClock);
  const { resultsIn, matches } = resultsCount(roundMatches(event));
  const counted = matches > 0 ? `${resultsIn}/${matches} IN` : null;

  if (view === "welcome") {
    return (
      <Shell>
        <Welcome event={event} size={size} origin={origin} />
      </Shell>
    );
  }
  return (
    <Shell>
      <div className="shrink-0 bg-t1-surface flex items-center" style={{ height: u(96), padding: `0 ${u(48)}px`, gap: u(40) }}>
        <p className="flex-1 min-w-0 truncate" style={{ fontSize: u(34), letterSpacing: u(1) }}>{event.name}</p>
        {final ? (
          <p className={`shrink-0 ${LABEL}`} style={label(u(24))}>Final standings</p>
        ) : (
          <>
            {/* The clock view says the round itself, large. */}
            {view !== "clock" && <p className={`shrink-0 ${LABEL}`} style={label(u(24))}>{roundLabel(event)}</p>}
            {counted && view !== "clock" && <p className={`shrink-0 ${LABEL}`} style={label(u(24))}>{counted}</p>}
            {clock.text && view !== "clock" && (
              <p role="timer" className={`shrink-0 tabular-nums ${CLOCK_COLOR[clock.state]}`} style={{ fontSize: u(48), fontWeight: 600, letterSpacing: u(1) }}>
                {clock.text}
              </p>
            )}
          </>
        )}
      </div>
      <div className="flex-1 min-h-0 flex flex-col">
        {view === "clock" && (
          <ClockView label={roundLabel(event)} clock={clock} counted={counted} size={size} width={width} height={height - u(96) - u(64)} />
        )}
        {view === "pairings" && <PairingsView event={event} size={size} width={width} height={height} turns={turns.pairings} />}
        {view === "standings" && (
          standings.teams
            ? <TeamStandings teams={standings.teams} size={size} width={width} height={height} turns={turns.standings} />
            : <StandingsView rows={standings.rows} final={final} size={size} width={width} height={height} turns={turns.standings} />
        )}
      </div>
      <div className="shrink-0 flex items-center justify-between" style={{ height: u(64), padding: `0 ${u(48)}px`, gap: u(40) }}>
        <Mark height={u(22)} />
        <p className={`min-w-0 truncate ${LABEL}`} style={label(u(20))}>
          {[event.formatLabel, event.venueName].filter(Boolean).join(" · ")}
        </p>
      </div>
    </Shell>
  );
}

/** Over everything, edge to edge: no tab bar, sidebar or back arrow reaches a TV. */
function Shell({ children }: { children: ReactNode }) {
  return (
    <div className="t1-display fixed inset-0 z-40 bg-t1-bg text-t1-text flex flex-col gap-px overflow-hidden select-none">
      {children}
    </div>
  );
}

/** The Table 1 mark at a height in px. */
function Mark({ height }: { height: number }) {
  return (
    <div className="shrink-0" style={{ height }}>
      <T1Logo className="h-full w-auto text-t1-muted" />
    </div>
  );
}

/** Loading (the mark alone), or one line when there's no event to show. */
export function DisplayMessage({ size, children }: { size: DisplaySize; children: ReactNode }) {
  const u = (n: number) => Math.round(n * size.unit);
  return (
    <Shell>
      <div className="flex-1 flex flex-col items-center justify-center" style={{ gap: u(64), padding: u(48) }}>
        <Mark height={u(72)} />
        {children && <p className="text-center" style={{ fontSize: u(48), letterSpacing: u(1) }}>{children}</p>}
      </div>
    </Shell>
  );
}

/* ── clock ─────────────────────────────────────────────────────────────── */

function ClockView({ label: round, clock, counted, size, width, height }: {
  label: string; clock: { text: string | null; state: ClockState }; counted: string | null; size: DisplaySize; width: number; height: number;
}) {
  const u = (n: number) => Math.round(n * size.unit);
  const word = clockWord(clock.state);
  // "Round timer off": the round is the subject, as large as the clock would be.
  const big = clock.text ?? round;
  const type = fitType(big, width * 0.92, height * (clock.text ? 0.62 : 0.34));
  return (
    <div className="flex-1 min-h-0 flex flex-col items-center justify-center" style={{ gap: u(24) }}>
      {clock.text && <p className={LABEL} style={label(u(44))}>{round}</p>}
      <p role={clock.text ? "timer" : undefined} className={`tabular-nums leading-none whitespace-nowrap ${CLOCK_COLOR[clock.state]}`}
         style={{ fontSize: type, fontWeight: 600 }}>
        {big}
      </p>
      <div className="flex items-baseline" style={{ gap: u(48), minHeight: u(60) }}>
        {word && <p className={`uppercase ${CLOCK_COLOR[clock.state]}`} style={label(u(44))}>{word}</p>}
        {counted && <p className="uppercase tabular-nums" style={label(u(52))}>{counted}</p>}
      </div>
    </div>
  );
}

/* ── lists ─────────────────────────────────────────────────────────────── */

/** A list's heading line: its name, column labels and, when it has more than one, the page it's on. */
function Heading({ size, rows = size, title, page, pages, children }: {
  size: DisplaySize; rows?: DisplaySize; title: string; page: number; pages: number; children?: ReactNode;
}) {
  const u = (n: number) => Math.round(n * size.unit);
  // The labels sit over their columns, so the sides and gaps follow the rows' size.
  const r = (n: number) => Math.round(n * rows.unit);
  return (
    <div className={`shrink-0 flex items-center ${LABEL}`} style={{ ...label(u(20)), height: u(56), padding: `0 ${r(32)}px`, gap: r(24) }}>
      <span className="flex-1 min-w-0 flex items-center truncate" style={{ gap: u(24) }}>
        <span className="text-t1-text">{title}</span>
        {pages > 1 && <span className="tabular-nums">{page + 1}/{pages}</span>}
      </span>
      {children}
    </div>
  );
}

function ListRow({ size, tall = 1, children, dim }: { size: DisplaySize; tall?: number; children: ReactNode; dim?: boolean }) {
  const u = (n: number) => Math.round(n * size.unit);
  return (
    <div className={`bg-t1-surface flex items-center min-w-0 ${dim ? "opacity-50" : ""}`}
         style={{ height: Math.round(size.row * tall) - 1, marginBottom: 1, padding: `0 ${u(32)}px`, gap: u(24), fontSize: u(30) }}>
      {children}
    </div>
  );
}

/** Side margins and the gap between two lists, in design px. */
const SIDE = 16;
const BETWEEN = 48;
/** The longest of some names, in characters (held to 28: past that a name is cut either way). */
const longest = (names: string[]) => Math.min(28, Math.max(0, ...names.map((n) => n.length)));

function PairingsView({ event, size: base, width, height, turns }: { event: PublicEvent; size: DisplaySize; width: number; height: number; turns: number }) {
  const matches = roundMatches(event);
  const tables = pairingsByTable(matches);
  const players = pairingsByPlayer(matches);
  const t = displayPages(tables.length, height, base.row, base.header);
  const p = displayPages(players.length, height, base.row, base.header);
  // A small event's lists are drawn larger, both alike: by the longer one, and only as far as the names still fit
  // (a row is its sides and gaps, the table, and two names; by table also the score).
  const room = base.wide ? (width / base.unit - 2 * SIDE - BETWEEN) / 2 : width / base.unit - 2 * SIDE;
  const names = 2 * longest(players.map((r) => r.name));
  const size = scaled(base, fitScale(fitScale(listScale(players.length, p.perPage), room, 64 + 48 + 110, names, 30), room, 64 + 72 + 96 + 110, names, 30));
  const u = (n: number) => Math.round(n * size.unit);

  const byTable = (page: number) => (
    <div className="flex-1 min-w-0 flex flex-col">
      <Heading size={base} rows={size} title="By table" page={page} pages={t.pages} />
      {tables.slice(page * t.perPage, (page + 1) * t.perPage).map((r: TableRow, i) => (
        <ListRow key={`${page}-${i}`} size={size}>
          <span className={`shrink-0 tabular-nums ${r.bye ? "text-t1-muted" : "font-bold"}`} style={{ width: u(96), fontSize: u(r.bye ? 24 : 34) }}>{r.table}</span>
          <span className="flex-1 min-w-0 truncate">{r.a}</span>
          {!r.bye && (
            <>
              <span className={`shrink-0 text-center tabular-nums ${r.score ? "text-t1-accent" : "text-t1-muted"}`} style={{ width: u(110), fontSize: u(r.score ? 30 : 22) }}>
                {r.score ?? "VS"}
              </span>
              <span className="flex-1 min-w-0 truncate text-right">{r.b}</span>
            </>
          )}
        </ListRow>
      ))}
    </div>
  );
  const byPlayer = (page: number) => (
    <div className="flex-1 min-w-0 flex flex-col">
      <Heading size={base} rows={size} title="A–Z" page={page} pages={p.pages}>
        <span style={{ width: u(110) }} className="shrink-0 text-right">Table</span>
        <span className="flex-1 min-w-0">Opponent</span>
      </Heading>
      {players.slice(page * p.perPage, (page + 1) * p.perPage).map((r: PlayerRow, i) => (
        <ListRow key={`${page}-${i}`} size={size}>
          <span className="flex-1 min-w-0 truncate">{r.name}</span>
          <span className={`shrink-0 text-right tabular-nums ${r.bye ? "text-t1-muted" : "font-bold"}`} style={{ width: u(110), fontSize: u(r.bye ? 24 : 34) }}>{r.table}</span>
          <span className="flex-1 min-w-0 truncate text-t1-muted">{r.opponent ?? ""}</span>
        </ListRow>
      ))}
    </div>
  );

  if (matches.length === 0) return <Empty size={base}>No pairings yet</Empty>;
  if (size.wide) {
    return (
      <div className="flex-1 min-h-0 flex" style={{ gap: Math.round(BETWEEN * base.unit), padding: `0 ${Math.round(SIDE * base.unit)}px` }}>
        {byPlayer(pageAt(turns, p.pages))}
        {byTable(pageAt(turns, t.pages))}
      </div>
    );
  }
  // A narrow window holds one list at a time: every A–Z page, then every page by table.
  const at = pageAt(turns, p.pages + t.pages);
  return (
    <div className="flex-1 min-h-0 flex" style={{ padding: `0 ${Math.round(SIDE * base.unit)}px` }}>
      {at < p.pages ? byPlayer(at) : byTable(at - p.pages)}
    </div>
  );
}

const record = (w: number, l: number, d: number) => (d > 0 ? `${w}-${l}-${d}` : `${w}-${l}`);

function StandingsView({ rows, final, size: base, width, height, turns }: {
  rows: PublicStandingRow[]; final: boolean; size: DisplaySize; width: number; height: number; turns: number;
}) {
  if (rows.length === 0) return <Empty size={base}>No players yet</Empty>;
  // A wide screen takes two columns of a list longer than one.
  const one = displayPages(rows.length, height, base.row, base.header);
  const columns = base.wide && one.pages > 1 ? 2 : 1;
  const { perPage, pages } = displayPages(Math.ceil(rows.length / columns), height, base.row, base.header);
  const room = width / base.unit - 2 * SIDE;
  const size = scaled(base, fitScale(listScale(rows.length, perPage), room, 64 + 96 + 64 + 90 + 150 + 150, longest(rows.map((r) => r.displayName)), 30));
  const u = (n: number) => Math.round(n * size.unit);
  const page = pageAt(turns, pages);
  const shown = rows.slice(page * perPage * columns, (page + 1) * perPage * columns);
  const column = (part: PublicStandingRow[], n: number) => (
    <div key={n} className="flex-1 min-w-0 flex flex-col">
      <Heading size={base} rows={size} title={n === 0 ? "Standings" : ""} page={page} pages={n === 0 ? pages : 1}>
        <span style={{ width: u(90) }} className="shrink-0 text-right">Pts</span>
        <span style={{ width: u(150) }} className="shrink-0 text-right">Record</span>
        <span style={{ width: u(150) }} className="shrink-0 text-right">OMW</span>
      </Heading>
      {part.map((r) => {
        const won = final && r.rank === 1;
        return (
          <ListRow key={r.participantId} size={size} dim={r.status === "dropped"}>
            <span className={`shrink-0 tabular-nums ${won ? "text-t1-accent" : "text-t1-muted"}`} style={{ width: u(64) }}>{r.rank}</span>
            <span className={`flex-1 min-w-0 truncate ${r.status === "dropped" ? "line-through" : ""} ${won ? "text-t1-accent" : ""}`}>{r.displayName}</span>
            <span className="shrink-0 text-right tabular-nums font-bold" style={{ width: u(90), fontSize: u(34) }}>{r.matchPoints}</span>
            <span className="shrink-0 text-right tabular-nums" style={{ width: u(150) }}>{record(r.matchWins, r.matchLosses, r.matchDraws)}</span>
            <span className="shrink-0 text-right tabular-nums text-t1-muted" style={{ width: u(150), fontSize: u(26) }}>{formatPct(r.omw)}</span>
          </ListRow>
        );
      })}
    </div>
  );
  return (
    <div className="flex-1 min-h-0 flex" style={{ gap: Math.round(BETWEEN * base.unit), padding: `0 ${Math.round(SIDE * base.unit)}px` }}>
      {Array.from({ length: columns }, (_, n) => column(shown.slice(n * perPage, (n + 1) * perPage), n))}
    </div>
  );
}

/** Team events: the teams in order, each with its members best first. */
const membersLine = (t: PublicTeamRow) => t.members.map((m) => `${m.displayName} ${record(m.matchWins, m.matchLosses, m.matchDraws)}`).join(" · ");

function TeamStandings({ teams, size: base, width, height, turns }: { teams: PublicTeamRow[]; size: DisplaySize; width: number; height: number; turns: number }) {
  const tall = 1.5;
  const { perPage, pages } = displayPages(teams.length, height, Math.round(base.row * tall), base.header);
  const page = pageAt(turns, pages);
  // Two teams fill the screen, as far as the line of members still fits.
  const members = Math.max(0, ...teams.map((t) => membersLine(t).length));
  const size = scaled(base, fitScale(listScale(teams.length, perPage), width / base.unit - 2 * SIDE, 64 + 96 + 64 + 90 + 150 + 220, members, 22));
  const u = (n: number) => Math.round(n * size.unit);
  if (teams.length === 0) return <Empty size={base}>No teams yet</Empty>;
  return (
    <div className="flex-1 min-h-0 flex flex-col" style={{ padding: `0 ${Math.round(SIDE * base.unit)}px` }}>
      <Heading size={base} rows={size} title="Team standings" page={page} pages={pages}>
        <span style={{ width: u(90) }} className="shrink-0 text-right">Pts</span>
        <span style={{ width: u(150) }} className="shrink-0 text-right">Record</span>
        <span style={{ width: u(220) }} className="shrink-0 text-right">Match wins</span>
      </Heading>
      {teams.slice(page * perPage, (page + 1) * perPage).map((t) => (
        <ListRow key={t.teamId} size={size} tall={tall}>
          <span className="shrink-0 tabular-nums text-t1-muted" style={{ width: u(64) }}>{t.rank}</span>
          <span className="flex-1 min-w-0 flex flex-col" style={{ gap: u(6) }}>
            <span className="truncate" style={{ fontSize: u(34) }}>{t.name}</span>
            <span className="truncate text-t1-muted" style={{ fontSize: u(22) }}>{membersLine(t)}</span>
          </span>
          <span className="shrink-0 text-right tabular-nums font-bold" style={{ width: u(90), fontSize: u(40) }}>{t.points}</span>
          <span className="shrink-0 text-right tabular-nums" style={{ width: u(150) }}>{record(t.wins, t.losses, t.draws)}</span>
          <span className="shrink-0 text-right tabular-nums text-t1-muted" style={{ width: u(220) }}>{t.matchWins}</span>
        </ListRow>
      ))}
    </div>
  );
}

function Empty({ size, children }: { size: DisplaySize; children: ReactNode }) {
  return (
    <div className={`flex-1 flex items-center justify-center ${LABEL}`} style={label(Math.round(32 * size.unit))}>{children}</div>
  );
}

/* ── before round 1 ────────────────────────────────────────────────────── */

function Welcome({ event, size, origin }: { event: PublicEvent; size: DisplaySize; origin: string }) {
  const u = (n: number) => Math.round(n * size.unit);
  const qr = useQr(`${origin}/s/${event.eventId}`, 720);
  const starts = when(event.startsAt);
  const players = event.capacity != null ? `${event.players}/${event.capacity} players` : event.players > 0 ? `${event.players} ${event.players === 1 ? "player" : "players"}` : null;
  const action = event.signUp === "open" ? "Sign up" : event.signUp === "full" ? "Join the waitlist" : "Event page";
  const side = u(size.wide ? 520 : 400);
  return (
    <div className={`flex-1 min-h-0 flex items-center ${size.wide ? "" : "flex-col justify-center"}`} style={{ gap: u(size.wide ? 96 : 56), padding: u(size.wide ? 96 : 48) }}>
      <div className={`min-w-0 flex flex-col ${size.wide ? "flex-1" : "items-center text-center"}`} style={{ gap: u(36) }}>
        <Mark height={u(40)} />
        <p className="break-words" style={{ fontSize: u(event.name.length > 36 ? 76 : 104), lineHeight: 1.06, fontWeight: 600, letterSpacing: u(1) }}>{event.name}</p>
        {starts && <p className="uppercase tabular-nums" style={{ fontSize: u(60), letterSpacing: u(3) }}>{starts}</p>}
        <p className={LABEL} style={label(u(28))}>{[event.formatLabel, event.venueName, players].filter(Boolean).join(" · ")}</p>
      </div>
      <div className="shrink-0 flex flex-col items-center" style={{ gap: u(28) }}>
        <div className="bg-white" style={{ width: side, height: side, padding: u(20) }}>
          {qr && <img src={qr} alt={`${action}: ${origin}/s/${event.eventId}`} className="w-full h-full" style={{ imageRendering: "pixelated" }} />}
        </div>
        <p className="uppercase" style={label(u(34))}>{action}</p>
      </div>
    </div>
  );
}

/* ── the screen itself ─────────────────────────────────────────────────── */

/** Nothing here is clicked, so the pointer goes away once it has been still for 3 s. */
function useIdleCursor() {
  useEffect(() => {
    let timer: number | undefined;
    const root = document.documentElement;
    const moved = () => {
      root.style.cursor = "";
      window.clearTimeout(timer);
      timer = window.setTimeout(() => { root.style.cursor = "none"; }, 3000);
    };
    moved();
    window.addEventListener("mousemove", moved);
    return () => {
      window.clearTimeout(timer);
      window.removeEventListener("mousemove", moved);
      root.style.cursor = "";
    };
  }, []);
}
