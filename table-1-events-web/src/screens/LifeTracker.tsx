import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent, type ReactNode } from "react";
import { reportFromHome, trackerNext } from "../lib/api";
import { decideNext, NEXT_EVERY_MS, NEXT_SOON_MS } from "../lib/trackerNext";
import { useSession } from "../lib/useSession";
import { capture } from "../lib/telemetry";
import { TrackerSync, type TrackerSnapshot } from "../lib/trackerSync";
import {
  COMMANDER_LOSS,
  EXTRA_COUNTERS,
  MAX_COUNTERS,
  POISON_LOSS,
  clampDelta,
  clockProgress,
  clockRemaining,
  clockTone,
  currentGameNo,
  formatDelta,
  formatTrackerClock,
  commanderFrom,
  counterLabel,
  counterShort,
  historyGroups,
  makeOp,
  matchDecided,
  matchScore,
  pickerCounters,
  resetOps,
  scoreLabel,
  settledWinner,
  shownCounters,
  toggleCounter,
  totals,
  undoLast,
  type ClockTone,
  type Counter,
  type CounterPrefs,
  type Side,
  type TrackerClock,
  type TrackerGame,
  type TrackerOp,
} from "../lib/tracker";
import { GhostAction, Modal, Notice, useNow } from "../components/kit";
import {
  SEAT_DEGREES,
  opensPicker,
  saveSetup,
  sideways,
  tableLayout,
  tableNames,
  tableScore,
  tracksCommander,
  type Seat,
  type TableRow,
} from "../lib/trackerTable";
import { TrackerChooser, TrackerDicePanel, TrackerOptionsPanel, TrackerSetup } from "./TrackerOptions";
import { paneStyle, useWindowFold } from "../lib/fold";

/* ── model ─────────────────────────────────────────────────────────────────
   One board for both kinds of session. Local: no event, stored on this device, 2–5 players set up on Setup
   (contract/life-tracker-commander-2026-11-03.md). Synced: one match, shared with the opponent (and watchable
   by the organizer). */

interface Model {
  /** Two for every synced match; 2–5 at a local table. */
  names: string[];
  startingLife: number;
  /** The side at the bottom of the screen that this person plays; null = watching. */
  mySide: Side | null;
  readOnly: boolean;
  ops: TrackerOp[];
  games: TrackerGame[];
  synced: boolean;
  matchId?: string;
  /** "R2 | Table 13 | Kai Budde" — the right side of the strip. */
  subtitle?: string;
  /** Offline / sending; shown in place of the subtitle while it lasts. */
  status?: string | null;
  /** The round clock; null for local sessions and matches without a timer. */
  clock: TrackerClock | null;
}

interface Controller {
  model: Model | null;
  error: string | null;
  add: (ops: TrackerOp[]) => void;
  record: (gameNo: number, winner: Side | null, draw: boolean) => Promise<void>;
  resetGame: () => void;
  newMatch?: () => void;
  /** Local only: a new table from Setup (clears games and history, names the players). */
  configure?: (players: number, life: number) => void;
}

const errorText = (e: unknown) =>
  e instanceof Error ? e.message : typeof e === "object" && e && "message" in e ? String((e as { message: unknown }).message) : String(e);

/* ── local session ─────────────────────────────────────────────────────── */

const LOCAL_KEY = "table1.lifeTracker.local";

interface LocalSession {
  names: string[];
  startingLife: number;
  ops: TrackerOp[];
  games: TrackerGame[];
}

const blankLocal = (keep?: Partial<LocalSession>): LocalSession => ({
  names: keep?.names ?? ["You", "Opponent"],
  startingLife: keep?.startingLife ?? 20,
  ops: [],
  games: [],
});

function loadLocal(): LocalSession {
  try {
    const raw = localStorage.getItem(LOCAL_KEY);
    if (!raw) return blankLocal();
    const s = JSON.parse(raw) as Partial<LocalSession>;
    return {
      names: Array.isArray(s.names) && s.names.length >= 2 && s.names.length <= 5 ? s.names.map(String) : ["You", "Opponent"],
      startingLife: typeof s.startingLife === "number" ? s.startingLife : 20,
      ops: Array.isArray(s.ops) ? s.ops : [],
      games: Array.isArray(s.games) ? s.games : [],
    };
  } catch {
    return blankLocal();
  }
}

function useLocalTracker(): Controller {
  const [s, setS] = useState<LocalSession>(loadLocal);
  useEffect(() => {
    try {
      localStorage.setItem(LOCAL_KEY, JSON.stringify(s));
    } catch {
      /* private mode: the session just won't survive a reload */
    }
  }, [s]);

  const model = useMemo<Model>(
    () => ({
      names: s.names,
      startingLife: s.startingLife,
      mySide: 0,
      readOnly: false,
      ops: s.ops,
      games: s.games,
      synced: false,
      subtitle: s.names.length > 2 ? `Local game | ${s.names.length} players` : "Local game",
      clock: null,
    }),
    [s],
  );

  return {
    model,
    error: null,
    add: (ops) => setS((p) => ({ ...p, ops: [...p.ops, ...ops] })),
    record: async (gameNo, winner, draw) =>
      setS((p) =>
        currentGameNo(p.games) !== gameNo
          ? p
          : {
              ...p,
              games: [
                ...p.games,
                { game_no: gameNo, winner_side: draw ? null : winner, is_draw: draw, recorded_at: new Date().toISOString() },
              ],
            },
      ),
    resetGame: () =>
      setS((p) => {
        const g = currentGameNo(p.games);
        return { ...p, ops: p.ops.filter((o) => o.game_no !== g) };
      }),
    newMatch: () => setS((p) => blankLocal(p)),
    configure: (players, life) => setS(blankLocal({ names: tableNames(players), startingLife: life })),
  };
}

/* ── synced session ────────────────────────────────────────────────────── */

/**
 * Follows the player into the next round (contract/life-tracker-options-2026-10-20.md § Next round): asks
 * tracker_next once the tracker is open, every 15 s while the page is visible, and on returning to it. Players only;
 * an organizer watching stays put (the server answers null for them too).
 */
function useNextRound(matchId: string, eventId: string | null | undefined, player: boolean,
                      onNext: ((matchId: string) => void) | undefined) {
  const [notice, setNotice] = useState<string | null>(null);
  const onNextRef = useRef(onNext);
  onNextRef.current = onNext;
  useEffect(() => {
    if (!player || !eventId) return;
    let live = true;
    let busy = false;
    const check = async (how: string) => {
      if (busy || document.visibilityState !== "visible") return;
      busy = true;
      try {
        for (let i = 0; i < 4 && live; i++) {
          const answer = await trackerNext(matchId, eventId);
          const next = decideNext(matchId, answer);
          if (next.do === "soon") {
            await new Promise((r) => setTimeout(r, NEXT_SOON_MS));
            continue;
          }
          if (!live) return;
          if (next.do === "notice") setNotice(next.text);
          if (next.do === "move") {
            // Unmounting this tracker closes its sync, which sends anything still queued.
            capture("tracker_next_round", { how, round: answer?.round ?? 0 });
            onNextRef.current?.(next.match_id);
          }
          return;
        }
      } catch {
        /* offline: the next tick asks again */
      } finally {
        busy = false;
      }
    };
    void check("open");
    const timer = window.setInterval(() => void check("poll"), NEXT_EVERY_MS);
    const onVisibility = () => {
      if (document.visibilityState === "visible") void check("foreground");
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      live = false;
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [matchId, eventId, player]);
  return notice;
}

function useSyncedTracker(matchId: string, onNext?: (matchId: string) => void): Controller {
  const { userId } = useSession();
  const uid = useRef(userId);
  uid.current = userId;
  const [snap, setSnap] = useState<TrackerSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const syncRef = useRef<TrackerSync | null>(null);
  const nextNotice = useNextRound(matchId, snap?.meta.event_id, snap != null && snap.meta.my_side != null, onNext);

  useEffect(() => {
    const sync = new TrackerSync(matchId, () => uid.current, setSnap);
    syncRef.current = sync;
    setError(null);
    sync.open().catch((e) => setError(errorText(e)));
    return () => {
      sync.close();
      if (syncRef.current === sync) syncRef.current = null;
    };
  }, [matchId]);

  const model = useMemo<Model | null>(() => {
    if (!snap) return null;
    const m = snap.meta;
    const names = [m.names?.[0] ?? "Player 1", m.names?.[1] ?? "Player 2"];
    const status = snap.status === "offline" ? (snap.unsent ? `Offline | ${snap.unsent} unsent` : "Offline") : snap.unsent ? "Sending…" : nextNotice;
    const who = m.my_side == null ? `Watching | ${names[0]} vs ${names[1]}` : names[m.my_side === 0 ? 1 : 0];
    return {
      names,
      startingLife: m.starting_life ?? 20,
      mySide: m.my_side,
      readOnly: m.my_side == null,
      ops: snap.ops,
      games: snap.games,
      synced: true,
      matchId: m.match_id,
      subtitle: [m.round ? `R${m.round}` : null, m.table ? `Table ${m.table}` : null, who].filter(Boolean).join(" | "),
      status,
      clock: m.clock ?? null,
    };
  }, [snap, nextNotice]);

  const add = useCallback((ops: TrackerOp[]) => syncRef.current?.add(ops), []);
  return {
    model,
    error,
    add,
    record: async (gameNo, winner, draw) => {
      if (!syncRef.current) throw new Error("The tracker isn't open yet");
      await syncRef.current.recordGame(gameNo, winner, draw);
    },
    resetGame: () => {
      if (!model) return;
      add(resetOps(model.ops, currentGameNo(model.games), model.startingLife));
    },
  };
}

/* ── screen ────────────────────────────────────────────────────────────── */

/** Keeps the screen on while the tracker is visible (Screen Wake Lock; ignored where unsupported). */
function useWakeLock() {
  useEffect(() => {
    type Sentinel = { release: () => Promise<void> };
    const nav = navigator as Navigator & { wakeLock?: { request: (type: "screen") => Promise<Sentinel> } };
    if (!nav.wakeLock) return;
    let sentinel: Sentinel | null = null;
    let live = true;
    const request = async () => {
      if (document.visibilityState !== "visible") return;
      try {
        const s = await nav.wakeLock!.request("screen");
        if (live) sentinel = s;
        else void s.release().catch(() => {});
      } catch {
        /* denied (battery saver, iframe policy): the screen may sleep */
      }
    };
    void request();
    const onVisibility = () => {
      if (document.visibilityState === "visible") void request();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      live = false;
      document.removeEventListener("visibilitychange", onVisibility);
      void sentinel?.release().catch(() => {});
    };
  }, []);
}

/** `onNext`: the next round is paired and this player has a match in it; open that one instead. */
export function LifeTracker({ matchId, onClose, onNext }: { matchId?: string; onClose: () => void; onNext?: (matchId: string) => void }) {
  useWakeLock();
  const opened = useRef(false); // once per mount, also under StrictMode's double effects
  useEffect(() => {
    if (opened.current) return;
    opened.current = true;
    capture("life_tracker_opened", { mode: matchId ? "match" : "local" });
  }, [matchId]);
  return matchId ? <SyncedBoard matchId={matchId} onClose={onClose} onNext={onNext} /> : <LocalBoard onClose={onClose} />;
}

function LocalBoard({ onClose }: { onClose: () => void }) {
  return <Board ctl={useLocalTracker()} prefsKey="local" onClose={onClose} setupFirst />;
}

function SyncedBoard({ matchId, onClose, onNext }: { matchId: string; onClose: () => void; onNext?: (matchId: string) => void }) {
  return <Board ctl={useSyncedTracker(matchId, onNext)} prefsKey={matchId} onClose={onClose} />;
}

type RecordFlow = { step: "pick" } | { step: "confirm"; winner: Side | null; draw: boolean };

/* ── counter columns ──────────────────────────────────────────────────────
   Which counters each side shows is a per-device choice, kept per match ("local" for local games). */

/** One entry per side; a missing one reads as nothing turned on or off. */
type SidePrefs = CounterPrefs[];
const noPrefs = (): SidePrefs => [];
const prefsOf = (prefs: SidePrefs, side: Side): CounterPrefs => prefs[side] ?? { on: [], off: [] };
const prefsStorageKey = (key: string) => `table1.trackerCounters.${key}`;
const knownCounter = (c: Counter) => (EXTRA_COUNTERS as Counter[]).includes(c) || commanderFrom(c) != null;

function readPrefs(key: string): SidePrefs {
  try {
    const raw = localStorage.getItem(prefsStorageKey(key));
    // Older builds kept {0: …, 1: …}.
    const p = raw ? (JSON.parse(raw) as Record<string, Partial<CounterPrefs>>) : null;
    const side = (x?: Partial<CounterPrefs>): CounterPrefs => ({
      on: Array.isArray(x?.on) ? x.on.filter(knownCounter) : [],
      off: Array.isArray(x?.off) ? x.off.filter(knownCounter) : [],
    });
    return p ? Array.from({ length: 5 }, (_, i) => side(p[i])) : noPrefs();
  } catch {
    return noPrefs();
  }
}

function useCounterPrefs(key: string) {
  const [prefs, setPrefs] = useState<SidePrefs>(() => readPrefs(key));
  useEffect(() => {
    try {
      localStorage.setItem(prefsStorageKey(key), JSON.stringify(prefs));
    } catch {
      /* storage unavailable: columns reset on reload */
    }
  }, [key, prefs]);
  return [prefs, setPrefs] as const;
}

/** Figma "Native/Label": 11/16, 1.5 tracking, uppercase. */
const LABEL = "text-[11px] leading-4 tracking-[1.5px] uppercase";

const TONE_TEXT: Record<ClockTone, string> = {
  normal: "text-t1-accent",
  warning: "text-t1-warning",
  overtime: "text-t1-error",
};
const TONE_FILL: Record<ClockTone, string> = {
  normal: "bg-t1-accent",
  warning: "bg-t1-warning",
  overtime: "bg-t1-error",
};

function Board({
  ctl,
  prefsKey,
  onClose,
  setupFirst = false,
}: {
  ctl: Controller;
  prefsKey: string;
  onClose: () => void;
  /** Local trackers open on Setup. */
  setupFirst?: boolean;
}) {
  const [prefs, setPrefs] = useCounterPrefs(prefsKey);
  const [setup, setSetup] = useState(setupFirst);
  const commanderTapped = useRef<Set<number>>(new Set());
  const [picker, setPicker] = useState<Side | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [panel, setPanel] = useState<"options" | "dice" | "chooser" | null>(null);
  const [resetOpen, setResetOpen] = useState(false);
  const [flow, setFlow] = useState<RecordFlow | null>(null);
  const [recording, setRecording] = useState(false);
  const [flowError, setFlowError] = useState<string | null>(null);
  const [decided, setDecided] = useState(false);

  const m = ctl.model;
  const now = useNow(m?.clock?.timer_status === "running");
  // Foldables (contract/foldables-2026-11-10.md § The screens): tabletop and book split the tracker at the fold.
  const fold = useWindowFold("tracker");

  if (!m) {
    return (
      <div className="fixed inset-0 bg-t1-bg text-t1-text flex flex-col gap-px">
        <div className="flex-1 flex items-center justify-center t1-label px-6 text-center">
          {ctl.error ? "" : "Opening the life tracker…"}
        </div>
        {ctl.error && <Notice tone="error">{ctl.error}</Notice>}
        <div className="flex gap-px">
          <GhostAction label="Close" onClick={onClose} />
        </div>
      </div>
    );
  }

  if (setup && ctl.configure) {
    return (
      <TrackerSetup
        canContinue={m.games.length > 0 || m.ops.some((o) => o.game_no === currentGameNo(m.games))}
        onStart={(players, life) => {
          ctl.configure!(players, life);
          saveSetup(players, life);
          setPrefs(noPrefs());
          setPicker(null);
          commanderTapped.current = new Set();
          setSetup(false);
          setPanel("chooser");
          capture("tracker_setup_started", { players, life });
        }}
        onContinue={() => {
          setSetup(false);
          capture("tracker_setup_continued", { players: m.names.length });
        }}
        onClose={onClose}
      />
    );
  }

  const players = m.names.length;
  const gameNo = currentGameNo(m.games);
  const t = totals(m.ops, gameNo, m.startingLife, players);
  const commander = tracksCommander(m.synced, m.startingLife);
  const bottom: Side = m.mySide ?? 0;
  const top: Side = bottom === 0 ? 1 : 0;
  const score = matchScore(m.games, players);
  const myWins = score.wins[bottom];
  const theirWins = score.wins[top];
  const winner = settledWinner(t, commander, top, bottom);
  const canEdit = !m.readOnly;
  const meLabel = m.synced || m.names[bottom] === "You" ? "Me" : m.names[bottom];
  const currentHistory = historyGroups(m.ops, gameNo, m.startingLife);

  const remaining = m.clock ? clockRemaining(m.clock, now) : null;
  const tone = remaining == null ? null : clockTone(remaining);

  function tap(side: Side, counter: Counter, delta: number) {
    if (!canEdit || !m) return;
    const live = totals(m.ops, gameNo, m.startingLife, players);
    const d = clampDelta(live[side][counter] ?? 0, delta, counter);
    if (d === 0) return;
    ctl.add([makeOp(gameNo, side, counter, d)]);
    if (commanderFrom(counter) != null && !commanderTapped.current.has(gameNo)) {
      commanderTapped.current.add(gameNo);
      capture("tracker_commander_damage", { players });
    }
  }

  function newMatch() {
    ctl.newMatch?.();
    setPrefs(noPrefs());
  }

  /** Back to Setup (local only). */
  function newTable() {
    setPicker(null);
    setSetup(true);
  }

  const gamesAfter = (winner: Side | null, draw: boolean): TrackerGame[] => [
    ...m.games,
    { game_no: gameNo, winner_side: draw ? null : winner, is_draw: draw, recorded_at: new Date().toISOString() },
  ];

  async function commitRecord(winner: Side | null, draw: boolean) {
    setRecording(true);
    setFlowError(null);
    try {
      await ctl.record(gameNo, winner, draw);
      setFlow(null);
      if (matchDecided(gamesAfter(winner, draw), players)) setDecided(true);
    } catch (e) {
      setFlowError(errorText(e));
    } finally {
      setRecording(false);
    }
  }

  const seat = (side: Side, at: Seat) => {
    const candidates = pickerCounters(side, players, commander);
    return (
      <SeatBox key={side} seat={at}>
        <TrackerHalf
          name={m.names[side]}
          names={m.names}
          values={t[side]}
          counters={shownCounters(t[side], prefsOf(prefs, side), candidates)}
          candidates={candidates}
          seat={at}
          small={players > 2}
          readOnly={!canEdit}
          onDelta={(c, d) => tap(side, c, d)}
          pickerOpen={picker === side}
          onPicker={(open) => setPicker(open ? side : null)}
          onToggle={(c) =>
            setPrefs((p) => {
              const next = [...p];
              const mine = prefsOf(p, side);
              next[side] = toggleCounter(mine, shownCounters(t[side], mine, candidates), c);
              return Array.from({ length: Math.max(next.length, players) }, (_, i) => next[i] ?? { on: [], off: [] });
            })
          }
        />
      </SeatBox>
    );
  };

  // Two players: mine at the bottom (the organizer watching sees side 0 there), the opponent's facing them.
  const rows: TableRow[] =
    players === 2 ? [[{ side: top, seat: "top" }], "strip", [{ side: bottom, seat: "bottom" }]] : tableLayout(players);
  const scoreText = tableScore(score.wins, m.names, bottom, top, score.draws);

  const winnerText = (winner: Side | null, draw: boolean) =>
    draw ? "a draw" : winner === bottom && m.mySide != null && players === 2 ? "you won" : `${m.names[winner ?? 0]} won`;
  const scoreAfter = (winner: Side | null, draw: boolean) => {
    const s = matchScore(gamesAfter(winner, draw), players);
    return scoreLabel(s.wins[bottom], s.wins[top], s.draws);
  };

  const folded = fold.mode === "tabletop" || fold.mode === "book";

  const strip = (
      /* Lifetracker Info (Figma 73:5617): clock + context, progress bar, Record / Options / Reset. */
      <div key="strip" className="shrink-0 flex flex-col gap-px bg-t1-bg">
        <div className="h-12 flex items-center">
          {remaining != null && tone && (
            <span role="timer" className={`${LABEL} px-4 tabular-nums shrink-0 ${TONE_TEXT[tone]}`}>
              {formatTrackerClock(remaining)}
            </span>
          )}
          <span className={`${LABEL} flex-1 min-w-0 px-4 truncate text-right text-t1-disabled`}>{m.status || m.subtitle}</span>
        </div>
        <div className="relative h-1 bg-t1-surface">
          {remaining != null && tone && m.clock && (
            <div
              className={`absolute inset-y-0 left-0 ${TONE_FILL[tone]}`}
              style={{ width: `${clockProgress(remaining, m.clock.timer_duration_seconds) * 100}%` }}
            />
          )}
        </div>
        <div className="h-12 flex items-stretch">
          <div className="flex-1 flex">
            {canEdit && (
              <StripButton
                accent={winner != null}
                onClick={() => setFlow(winner != null ? { step: "confirm", winner, draw: false } : { step: "pick" })}
              >
                Record
              </StripButton>
            )}
          </div>
          <StripButton onClick={() => setPanel("options")}>Options</StripButton>
          <div className="flex-1 flex justify-end">
            {canEdit && <StripButton onClick={() => setResetOpen(true)}>Reset</StripButton>}
          </div>
        </div>
      </div>
  );

  return (
    <div
      className={`fixed inset-0 text-t1-text flex flex-col gap-px overflow-hidden select-none ${
        // Hairlines between seats at a bigger table.
        players > 2 ? "bg-t1-surface" : "bg-t1-bg"
      }`}
      style={{ touchAction: "manipulation" }}
    >
      {folded ? (
        <>
          {/* Every seat upright, facing whoever holds the phone: the opponent first, you last. */}
          <div
            className={`absolute flex gap-px bg-t1-surface ${fold.mode === "book" ? "flex-col" : ""}`}
            style={paneStyle(fold.panes[0])}
          >
            {(players === 2 ? [top, bottom] : Array.from({ length: players }, (_, i) => i as Side)).map((side) => (
              <div key={side} className="relative flex-1 min-w-0 min-h-0 flex">
                {seat(side, "bottom")}
                <span className={`${LABEL} absolute bottom-3 inset-x-0 text-center text-t1-muted pointer-events-none`}>
                  {m.names[side]}
                </span>
              </div>
            ))}
          </div>
          {/* The strip grown to fill the flat half (tabletop) or the right page (book). */}
          <div className="absolute flex flex-col gap-px bg-t1-surface" style={paneStyle(fold.panes[1])}>
            <div className="flex-1 min-h-0 bg-t1-bg flex flex-col items-center justify-center gap-3 px-4">
              {remaining != null && tone && (
                <span role="timer" className={`font-mono text-[56px] font-semibold tabular-nums ${TONE_TEXT[tone]}`}>
                  {formatTrackerClock(remaining)}
                </span>
              )}
              <span className={`${LABEL} truncate max-w-full text-t1-disabled`}>{m.status || m.subtitle}</span>
              <span className={`${LABEL} text-t1-muted`}>Game {gameNo} · {scoreText}</span>
            </div>
            <div className={`flex gap-px ${fold.mode === "book" ? "flex-col" : "h-[72px]"}`}>
              {canEdit && (
                <FoldAction
                  accent={winner != null}
                  onClick={() => setFlow(winner != null ? { step: "confirm", winner, draw: false } : { step: "pick" })}
                >
                  Record
                </FoldAction>
              )}
              <FoldAction onClick={() => setPanel("options")}>Options</FoldAction>
              {canEdit && <FoldAction onClick={() => setResetOpen(true)}>Reset</FoldAction>}
            </div>
          </div>
        </>
      ) : (
        rows.map((row, i) =>
          row === "strip" ? (
            strip
          ) : (
            <div key={i} className="flex-1 min-h-0 flex gap-px bg-t1-surface">
              {row.map((p) => seat(p.side, p.seat))}
            </div>
          ),
        )
      )}

      {panel === "options" && (
        <TrackerOptionsPanel
          onClose={() => setPanel(null)}
          onChooser={() => setPanel("chooser")}
          onDice={() => setPanel("dice")}
          onHistory={() => setHistoryOpen(true)}
          onNewMatch={ctl.configure ? newTable : undefined}
          onLeave={onClose}
        />
      )}
      {panel === "dice" && <TrackerDicePanel onClose={() => setPanel(null)} />}
      {panel === "chooser" && <TrackerChooser onClose={() => setPanel(null)} />}

      {resetOpen && (
        <ResetDialog
          gameNo={gameNo}
          startingLife={m.startingLife}
          score={scoreText}
          // Only this device's own games can be cleared, never an event's recorded ones.
          canResetMatch={!m.synced && m.games.length > 0 && !!ctl.newMatch}
          keepsGames={m.synced && m.games.length > 0}
          onClose={() => setResetOpen(false)}
          onReset={(match) => {
            if (match) ctl.newMatch?.();
            else ctl.resetGame();
            setResetOpen(false);
            capture("tracker_reset", { scope: match ? "match" : "game", mode: m.synced ? "match" : "local" });
          }}
        />
      )}

      {historyOpen && (
        <Sheet title="History" onClose={() => setHistoryOpen(false)}
          action={
            canEdit ? (
              <button
                disabled={!currentHistory.length}
                onClick={() => ctl.add(undoLast(m.ops, gameNo, m.startingLife))}
                className="t1-label text-t1-accent! disabled:opacity-40"
              >
                Undo last
              </button>
            ) : null
          }
        >
          {[gameNo, ...m.games.map((g) => g.game_no).reverse()].map((g) => {
            const groups = g === gameNo ? currentHistory : historyGroups(m.ops, g, m.startingLife);
            const result = m.games.find((x) => x.game_no === g);
            return (
              <div key={g} className="flex flex-col gap-px">
                <div className="bg-t1-bg px-4 py-2 t1-label">
                  Game {g}
                  {result ? ` · ${result.is_draw ? "draw" : winnerText(result.winner_side, false)}` : " · now"}
                  {g === gameNo ? ` · ${players > 2 ? "games" : "match"} ${scoreText}` : ""}
                </div>
                {groups.length === 0 && <div className="bg-t1-surface px-4 py-3 t1-label">No changes yet</div>}
                {groups.map((gr) => (
                  <div key={gr.id} className="bg-t1-surface px-4 py-2.5 flex items-center gap-3">
                    <span className="flex-1 min-w-0 truncate text-[13px]">
                      {m.names[gr.side]} · {counterLabel(gr.counter, m.names)} {formatDelta(gr.delta)} → {gr.after}
                    </span>
                    <span className="t1-label shrink-0">
                      {new Date(gr.endedAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" })}
                      {m.synced && gr.mine !== undefined
                        ? gr.mine
                          ? " · by you"
                          : m.mySide != null
                            ? ` · by ${m.names[m.mySide === 0 ? 1 : 0]}`
                            : ""
                        : ""}
                    </span>
                  </div>
                ))}
              </div>
            );
          })}

          {/* What the old ⋯ menu held. */}
          <div className="flex flex-col gap-px pt-px">
            {canEdit && (
              <MenuItem
                onClick={() => {
                  ctl.resetGame();
                  setHistoryOpen(false);
                }}
              >
                Reset game
              </MenuItem>
            )}
            {m.synced && m.mySide != null && (
              <MenuItem
                onClick={() => {
                  setHistoryOpen(false);
                  setDecided(true);
                }}
              >
                Report now
              </MenuItem>
            )}
            {ctl.configure && (
              <MenuItem
                onClick={() => {
                  setHistoryOpen(false);
                  newTable();
                }}
              >
                New match · {players} · {m.startingLife}
              </MenuItem>
            )}
          </div>
        </Sheet>
      )}

      {flow?.step === "pick" && (
        <Modal title={`Who won game ${gameNo}?`} onClose={() => setFlow(null)}>
          <div className="flex flex-col gap-px">
            {[
              ...(players === 2
                ? [
                    { label: meLabel, winner: bottom as Side | null, draw: false },
                    { label: m.names[top], winner: top as Side | null, draw: false },
                  ]
                : m.names.map((name, side) => ({ label: name, winner: side as Side | null, draw: false }))),
              { label: "Draw", winner: null, draw: true },
            ].map((o) => (
              <button
                key={o.label + String(o.winner)}
                onClick={() => setFlow({ step: "confirm", winner: o.winner, draw: o.draw })}
                className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3.5 text-[13px] uppercase tracking-[1px] text-left"
              >
                {o.label}
              </button>
            ))}
          </div>
          <div className="flex gap-px">
            <GhostAction label="Cancel" onClick={() => setFlow(null)} />
          </div>
        </Modal>
      )}

      {flow?.step === "confirm" && (
        <Modal
          title={
            players > 2
              ? `Record game ${gameNo}: ${winnerText(flow.winner, flow.draw)}? Game ${gameNo + 1} starts at ${m.startingLife}.`
              : `Record game ${gameNo}: ${winnerText(flow.winner, flow.draw)}? Match is ${scoreAfter(flow.winner, flow.draw)}.`
          }
          onClose={() => !recording && setFlow(null)}
        >
          <button onClick={() => setFlow({ step: "pick" })} className="t1-label text-left">
            Change winner
          </button>
          {flowError && <Notice tone="error">{flowError}</Notice>}
          <div className="flex gap-px">
            <GhostAction label="Cancel" onClick={() => setFlow(null)} disabled={recording} />
            <button
              onClick={() => commitRecord(flow.winner, flow.draw)}
              disabled={recording}
              className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px] disabled:opacity-60"
            >
              {recording ? "Recording…" : "Record"}
            </button>
          </div>
        </Modal>
      )}

      {decided && (
        <DecidedDialog
          model={m}
          myWins={myWins}
          theirWins={theirWins}
          draws={score.draws}
          bottom={bottom}
          onClose={() => setDecided(false)}
          onDone={onClose}
          onNewMatch={
            ctl.newMatch
              ? () => {
                  newMatch();
                  setDecided(false);
                }
              : undefined
          }
        />
      )}
    </div>
  );
}

/** Reset asks first: life back to starting life and counters to 0; on this device's own games, the match too. */
function ResetDialog({
  gameNo,
  startingLife,
  score,
  canResetMatch,
  keepsGames,
  onClose,
  onReset,
}: {
  gameNo: number;
  startingLife: number;
  score: string;
  canResetMatch: boolean;
  keepsGames: boolean;
  onClose: () => void;
  onReset: (match: boolean) => void;
}) {
  const life = `Life goes back to ${startingLife} and counters to 0.`;
  const message = canResetMatch
    ? `${life} Reset match also clears the games (${score}).`
    : keepsGames
      ? `${life} Recorded games stay (${score}).`
      : life;
  return (
    <Modal title={canResetMatch ? "Reset?" : `Reset game ${gameNo}?`} onClose={onClose}>
      <p className="text-[12px] leading-[18px] text-t1-muted">{message}</p>
      <div className="flex gap-px">
        <GhostAction label="Cancel" onClick={onClose} />
        {canResetMatch && <GhostAction label="Reset game" onClick={() => onReset(false)} />}
        <button
          onClick={() => onReset(canResetMatch)}
          className="flex-1 bg-t1-text text-t1-bg px-4 py-3 text-[11px] uppercase tracking-[1px]"
        >
          {canResetMatch ? "Reset match" : "Reset"}
        </button>
      </div>
    </Modal>
  );
}

/** "Report 2–1 to the event?" for synced sessions; just the result for local ones. */
function DecidedDialog({
  model,
  myWins,
  theirWins,
  draws,
  bottom,
  onClose,
  onDone,
  onNewMatch,
}: {
  model: Model;
  myWins: number;
  theirWins: number;
  draws: number;
  bottom: Side;
  onClose: () => void;
  onDone: () => void;
  onNewMatch?: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const label = scoreLabel(myWins, theirWins, draws);

  if (!model.synced || model.mySide == null || !model.matchId) {
    const name = model.names[bottom];
    const title =
      myWins > theirWins
        ? `${name === "You" ? "You" : name} won ${label}`
        : theirWins > myWins
          ? `${model.names[bottom === 0 ? 1 : 0]} won ${scoreLabel(theirWins, myWins, draws)}`
          : `Draw ${label}`;
    return (
      <Modal title={title} onClose={onClose}>
        <div className="flex gap-px">
          <GhostAction label="Keep playing" onClick={onClose} />
          {onNewMatch && (
            <button onClick={onNewMatch} className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px]">
              New match
            </button>
          )}
        </div>
      </Modal>
    );
  }

  async function report() {
    setBusy(true);
    setError(null);
    try {
      await reportFromHome(model.matchId!, model.mySide!, myWins, theirWins, undefined, draws);
      setSent(true);
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  if (sent) {
    return (
      <Modal title={`Reported ${label}`} onClose={onClose}>
        <p className="text-[12px] leading-[18px] text-t1-muted">Your opponent confirms or disputes it on their side, as usual.</p>
        <div className="flex gap-px">
          <GhostAction label="Stay here" onClick={onClose} />
          <button onClick={onDone} className="flex-1 bg-t1-text text-t1-bg px-4 py-3 text-[11px] uppercase tracking-[1px]">
            Back to event
          </button>
        </div>
      </Modal>
    );
  }

  return (
    <Modal title={`Report ${label} to the event?`} onClose={() => !busy && onClose()}>
      <p className="text-[12px] leading-[18px] text-t1-muted">
        Your wins first. Your opponent confirms or disputes it, the same as reporting from the event screen.
      </p>
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex gap-px">
        <GhostAction label="Not now" onClick={onClose} disabled={busy} />
        <button
          onClick={report}
          disabled={busy}
          className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px] disabled:opacity-60"
        >
          {busy ? "Reporting…" : "Report"}
        </button>
      </div>
    </Modal>
  );
}

/* ── pieces ────────────────────────────────────────────────────────────── */

/** One of the folded tracker's controls: a full-size target on the flat half. */
function FoldAction({ children, onClick, accent }: { children: ReactNode; onClick: () => void; accent?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={`${LABEL} flex-1 min-h-[72px] bg-t1-bg active:bg-t1-surface transition-colors duration-150 ${
        accent ? "text-t1-accent" : "text-t1-text"
      }`}
    >
      {children}
    </button>
  );
}

/** Strip Button (Figma 73:5656): label, pressed = surface. Accent means "the result" (a game was lost). */
function StripButton({ children, onClick, accent }: { children: ReactNode; onClick: () => void; accent?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={`${LABEL} h-12 px-4 shrink-0 bg-t1-bg active:bg-t1-surface transition-colors duration-150 ${
        accent ? "text-t1-accent" : "text-t1-text"
      }`}
    >
      {children}
    </button>
  );
}

/* Number sizes from the Me / Counter Column components, capped so they fit the seat (its container, in the
   player's own orientation). Seats at a bigger table use 60% of the two-player sizes. */
type ColumnSize = "alone" | "life" | "L" | "M" | "S";
const COLUMN_PX: Record<ColumnSize, [number, number, number]> = {
  alone: [162, 37, 42],
  life: [120, 28, 33],
  L: [80, 19, 22],
  M: [64, 14, 18],
  S: [44, 10, 13],
};
const columnFont = (size: ColumnSize, small: boolean) => {
  const [px, w, h] = COLUMN_PX[size];
  return `min(${Math.round(px * (small ? 0.6 : 1))}px, ${w}cqw, ${h}cqh)`;
};

/**
 * A seat facing its own edge of the phone (contract/life-tracker-commander-2026-11-03.md). The half inside is
 * laid out in the player's frame (width and height swapped for side seats) and turned; the browser turns the
 * touches with it.
 */
function SeatBox({ seat, children }: { seat: Seat; children: ReactNode }) {
  const turned = sideways(seat);
  return (
    <div className="relative flex-1 min-w-0 min-h-0 overflow-hidden" style={{ containerType: "size" }}>
      <div
        className="absolute left-1/2 top-1/2 flex"
        style={{
          width: turned ? "100cqh" : "100cqw",
          height: turned ? "100cqw" : "100cqh",
          transform: `translate(-50%, -50%) rotate(${SEAT_DEGREES[seat]}deg)`,
          containerType: "size",
        }}
      >
        {children}
      </div>
    </div>
  );
}

const SWIPE_PX = 24;
const TAP_SLOP_PX = 10;

/**
 * One player's half (Figma "Me", Counters=0…3), drawn inside its SeatBox. Swipe down — in this player's
 * orientation — opens the counter picker inside the half; only Done closes it (swiping up scrolls its rows).
 */
function TrackerHalf({
  name,
  names,
  values,
  counters,
  candidates,
  seat,
  small,
  readOnly,
  onDelta,
  pickerOpen,
  onPicker,
  onToggle,
}: {
  name: string;
  names: string[];
  values: Record<Counter, number>;
  counters: Counter[];
  /** What the picker lists (commander damage first at 30+ life). */
  candidates: Counter[];
  seat: Seat;
  small: boolean;
  readOnly: boolean;
  onDelta: (counter: Counter, delta: number) => void;
  pickerOpen: boolean;
  onPicker: (open: boolean) => void;
  onToggle: (counter: Counter) => void;
}) {
  const start = useRef<{ id: number; x: number; y: number } | null>(null);

  function onMove(e: PointerEvent) {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    // Pointer moves are in screen pixels; a turned seat's "down" points elsewhere on screen.
    if (!opensPicker(seat, e.clientX - s.x, e.clientY - s.y, SWIPE_PX)) return;
    start.current = null;
    if (!pickerOpen) onPicker(true);
  }

  const size: ColumnSize = counters.length === 0 ? "alone" : "life";
  const counterSize: ColumnSize = counters.length === 1 ? "L" : counters.length === 2 ? "M" : "S";

  return (
    <section
      className="relative flex-1 min-h-0 overflow-hidden flex gap-px bg-t1-surface"
      aria-label={`${name}: ${values.life} life${counters.map((c) => `, ${counterLabel(c, names)} ${values[c] ?? 0}`).join("")}`}
      onPointerDown={(e) => (start.current = { id: e.pointerId, x: e.clientX, y: e.clientY })}
      onPointerMove={onMove}
      onPointerUp={() => (start.current = null)}
      onPointerCancel={() => (start.current = null)}
    >
      <Column
        name={`${name} life`}
        value={values.life}
        size={size}
        small={small}
        lost={values.life <= 0}
        readOnly={readOnly}
        onDelta={(d) => onDelta("life", d)}
      />
      {counters.length > 0 && (
        <div className="flex-1 min-w-0 flex gap-px">
          {counters.map((c) => (
            <Column
              key={c}
              name={`${name} ${counterLabel(c, names)}`}
              value={values[c] ?? 0}
              label={counterShort(c, names)}
              size={counterSize}
              small={small}
              lost={c === "poison" ? values[c] >= POISON_LOSS : commanderFrom(c) != null && (values[c] ?? 0) >= COMMANDER_LOSS}
              readOnly={readOnly}
              onDelta={(d) => onDelta(c, d)}
            />
          ))}
        </div>
      )}
      {counters.length === 0 && (
        <div className="absolute top-2 left-1/2 -translate-x-1/2 w-[26px] h-px bg-t1-surface pointer-events-none" />
      )}
      {pickerOpen && (
        <CounterPicker
          shown={counters}
          candidates={candidates}
          names={names}
          onToggle={onToggle}
          onDone={() => onPicker(false)}
        />
      )}
    </section>
  );
}

/** Counter Column (Figma): its own top +1 / bottom −1 zones, the total, and a label for counters. */
function Column({
  name,
  value,
  label,
  size,
  small,
  lost,
  readOnly,
  onDelta,
}: {
  name: string;
  value: number;
  label?: string;
  size: ColumnSize;
  small: boolean;
  lost: boolean;
  readOnly: boolean;
  onDelta: (delta: number) => void;
}) {
  return (
    <div className="relative flex-1 min-w-0 bg-t1-bg">
      {!readOnly && (
        <div className="absolute inset-0 flex flex-col gap-px">
          <TapZone onTap={() => onDelta(1)} label={`${name} +1`} />
          <TapZone onTap={() => onDelta(-1)} label={`${name} −1`} />
        </div>
      )}
      <div className="absolute inset-0 pb-8 px-1 flex flex-col items-center justify-center gap-2 pointer-events-none">
        <span
          className={`tabular-nums leading-none font-semibold ${lost ? "text-t1-error" : ""}`}
          style={{ fontSize: columnFont(size, small), letterSpacing: "-0.025em" }}
        >
          {value}
        </span>
        {label && <span className={`${LABEL} max-w-full truncate text-t1-disabled`}>{label}</span>}
      </div>
    </div>
  );
}

/** Counter Picker (Figma): which counters this side shows, three at most; commander damage from each opponent first. */
function CounterPicker({
  shown,
  candidates,
  names,
  onToggle,
  onDone,
}: {
  shown: Counter[];
  candidates: Counter[];
  names: string[];
  onToggle: (c: Counter) => void;
  onDone: () => void;
}) {
  const full = shown.length >= MAX_COUNTERS;
  return (
    <div
      className="absolute inset-0 z-10 flex flex-col gap-px bg-t1-surface animate-[t1-slide-down_150ms_ease-out]"
      role="dialog"
      aria-label="Counters"
    >
      <div className="shrink-0 flex items-center justify-between bg-t1-bg">
        <span className={`${LABEL} px-4 text-t1-disabled`}>
          Counters · {shown.length} of {MAX_COUNTERS}
        </span>
        <StripButton onClick={onDone}>Done</StripButton>
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {candidates.map((c) => {
          const on = shown.includes(c);
          const disabled = !on && full;
          return (
            <button
              key={c}
              type="button"
              disabled={disabled}
              aria-pressed={on}
              onClick={() => onToggle(c)}
              className={`${LABEL} shrink-0 h-12 px-4 flex items-center justify-between transition-colors duration-150 ${
                disabled ? "bg-t1-disabled text-t1-bg" : "bg-t1-bg text-t1-text active:bg-t1-surface"
              }`}
            >
              <span>{counterLabel(c, names)}</span>
              <span className={on || disabled ? "" : "text-t1-disabled"}>{on ? "On" : disabled ? "Max 3" : "Off"}</span>
            </button>
          );
        })}
        <div className="flex-1 bg-t1-bg" />
      </div>
    </div>
  );
}

/**
 * Increment Button (Figma 73:5558). A tap fires on release so a swipe never changes a total; moving more
 * than 10px cancels it. Holding fires after 0.5 s, then every 0.15 s.
 */
function TapZone({ onTap, label }: { onTap: () => void; label: string }) {
  const fire = useRef(onTap);
  fire.current = onTap;
  const [pressed, setPressed] = useState(false);
  const press = useRef<{ x: number; y: number; held: boolean; wait?: number; every?: number } | null>(null);
  const stop = useCallback(() => {
    if (press.current) {
      window.clearTimeout(press.current.wait);
      window.clearInterval(press.current.every);
    }
    press.current = null;
    setPressed(false);
  }, []);
  useEffect(() => stop, [stop]);

  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={label}
      onPointerDown={(e) => {
        if (e.pointerType === "mouse" && e.button !== 0) return;
        e.preventDefault();
        stop();
        try {
          e.currentTarget.setPointerCapture(e.pointerId);
        } catch {
          /* not capturable; pointercancel still ends the press */
        }
        const p: NonNullable<typeof press.current> = { x: e.clientX, y: e.clientY, held: false };
        p.wait = window.setTimeout(() => {
          p.held = true;
          fire.current();
          p.every = window.setInterval(() => fire.current(), 150);
        }, 500);
        press.current = p;
        setPressed(true);
      }}
      onPointerMove={(e) => {
        const p = press.current;
        if (p && !p.held && Math.hypot(e.clientX - p.x, e.clientY - p.y) > TAP_SLOP_PX) stop();
      }}
      onPointerUp={() => {
        if (press.current && !press.current.held) fire.current();
        stop();
      }}
      onPointerCancel={stop}
      onLostPointerCapture={stop}
      onContextMenu={(e) => e.preventDefault()}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          fire.current();
        }
      }}
      className={`flex-1 min-h-0 outline-none transition-colors duration-150 focus-visible:bg-t1-surface ${
        pressed ? "bg-t1-surface" : "bg-t1-bg"
      }`}
      style={{ touchAction: "none", WebkitTouchCallout: "none" } as CSSProperties}
    />
  );
}

function MenuItem({ children, onClick }: { children: ReactNode; onClick: () => void }) {
  return (
    <button onClick={onClick} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3.5 text-[12px] uppercase tracking-[1px] text-left">
      {children}
    </button>
  );
}

function Sheet({
  title,
  children,
  onClose,
  action,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
  action?: ReactNode;
}) {
  return (
    <div className="fixed inset-0 z-40 flex flex-col justify-end" role="dialog" aria-modal="true" aria-label={title}>
      <div className="absolute inset-0 bg-black/60" onClick={onClose} />
      <div className="relative bg-t1-bg max-h-[75dvh] flex flex-col gap-px border-t border-t1-surface select-text">
        <div className="bg-t1-surface px-4 py-3 flex items-center gap-4">
          <span className="flex-1 min-w-0 truncate text-[13px]">{title}</span>
          {action}
          <button onClick={onClose} className="t1-label">
            Close
          </button>
        </div>
        <div className="overflow-y-auto flex flex-col gap-px pb-[env(safe-area-inset-bottom)]">{children}</div>
      </div>
    </div>
  );
}

