// Roto pieces that sit inside the existing event screens: Create and Details (Pairing), Setup (cube, picks per
// player, order, pick clock, pick order, Start draft) and Live (the round-robin Schedule). Same as
// apps/ios/Table1/Roto/RotoSetup.swift.
import { useEffect, useRef, useState } from "react";
import type { EventBundle } from "../../lib/api";
import { loadCatalog } from "../../lib/catalog";
import { countOf, createList, listsNow, startLists, useLists } from "../../lib/lists";
import { rotoSetCube, rotoStart, rotoStore, useRoto } from "../../lib/roto";
import { roundRobinPairs, roundRobinRoster, roundRobinRounds } from "../../lib/roundrobin";
import {
  addClockRange, CLOCK_DURATIONS, durationText, roundRobinRoundsFor, type RotoClockRange,
} from "../../lib/rotoMath";
import { supabase } from "../../lib/supabaseClient";
import { capture, reportError } from "../../lib/telemetry";
import { useSession } from "../../lib/useSession";
import type { Participant, Table1Event } from "../../lib/types";
import { BigAction, Dialog, Field, GhostAction, Notice, Row, Section, Segmented, Stepper, SwitchRow } from "../../components/kit";

/* ── Create / Details: pairing ────────────────────────────────────── */

/** Roto only: Swiss · Round robin. Round robin hides the Rounds stepper ("7 rounds · everyone plays everyone"). */
export function RotoPairingFields({ pairing, onPairing, players }: {
  pairing: "swiss" | "round_robin"; onPairing: (p: "swiss" | "round_robin") => void; players: number;
}) {
  const n = roundRobinRoundsFor(Math.max(2, players));
  return (
    <>
      <Segmented label="Pairing" value={pairing} onChange={onPairing}
                 options={[{ value: "swiss", label: "Swiss" }, { value: "round_robin", label: "Round robin" }]} />
      {pairing === "round_robin" && (
        <Notice tone="info">
          {n} round{n === 1 ? "" : "s"} · everyone plays everyone{players % 2 === 1 && players > 1 ? ", one bye a round" : ""}. Set from
          the players when round 1 is paired.
        </Notice>
      )}
    </>
  );
}

/* ── Setup → Seating (pick order) ─────────────────────────────────── */

/** Pick order 1…n. Seats are drawn at random when the draft starts unless the organizer seats them first. */
export function RotoPickOrder({ participants, meId, busy, onSeat }: {
  participants: Participant[]; meId: string | null; busy: boolean; onSeat: () => void;
}) {
  const seated = participants.filter((p) => p.status === "active" && p.seat != null).sort((a, b) => (a.seat ?? 0) - (b.seat ?? 0));
  return (
    <>
      <button type="button" onClick={onSeat} disabled={busy}
              className={`shrink-0 py-3.5 text-[11px] uppercase tracking-[1px] disabled:bg-t1-disabled ${seated.length ? "bg-t1-surface hover:bg-t1-surface-hover" : "bg-t1-accent text-t1-ink"}`}>
        {busy ? "Working…" : seated.length ? "Re-draw" : "Draw pick order"}
      </button>
      {seated.length === 0 ? (
        <Notice tone="info">Seat 1 picks first. Draw the order now, or Start draft draws it at random.</Notice>
      ) : (
        <>
          <Section title={`Pick order · snake: 1 → ${seated.length}, then back`} />
          {seated.map((p) => (
            <Row key={p.id} title={p.id === meId ? `You · ${p.displayName}` : p.displayName}
                 detail={p.userId ? undefined : "Guest · picks once they claim their seat"} value={p.seat} />
          ))}
        </>
      )}
    </>
  );
}

/* ── Setup → Details (roto) ───────────────────────────────────────── */

/** A Cube Cobra link → a cube in your Library (through list-import), so roto_set_cube can use it at once. */
async function importCube(url: string): Promise<string> {
  const { data, error } = await supabase.functions.invoke("list-import", { body: { url } });
  if (error) {
    const body = await (error as { context?: Response }).context?.json?.().catch(() => null);
    throw new Error(body?.error ?? "That cube couldn't be read.");
  }
  // The Library's import resolver, loaded only when a link is imported.
  const { resolveImport } = await import("../ListImport");
  const r = data as { name?: string; format?: string; source_url?: string; entries?: Parameters<typeof resolveImport>[1] };
  if (!r.entries?.length) throw new Error("No cards in that cube.");
  const { entries } = resolveImport(await loadCatalog(), r.entries, "cube");
  if (!entries.length) throw new Error("None of that cube's cards are in the card data.");
  const host = r.source_url ? new URL(r.source_url).host : null;
  const id = await createList("cube", (r.name ?? "Cube").slice(0, 60), r.format ?? "vintage", entries, host ? `Imported from ${host}` : "Imported", "import");
  capture("list_imported", { kind: "cube", from: "link", cards: entries.reduce((n, e) => n + e.qty, 0) });
  return id;
}

/**
 * After Create: use the Library cube with the typed name, else import the Cube Cobra link into the Library and use
 * that. Quietly leaves it for Setup → Details when neither works.
 */
export async function linkRotoCube(eventId: string, name: string, url: string) {
  try {
    const { data } = await supabase.auth.getSession();
    const uid = data.session?.user.id;
    if (!uid) return;
    await startLists(uid);
    const wanted = name.trim().toLowerCase();
    const library = listsNow().find((l) => l.kind === "cube" && l.name.trim().toLowerCase() === wanted);
    if (library) await rotoSetCube(eventId, library.id, "library");
    else if (url.trim()) await rotoSetCube(eventId, await importCube(url.trim()), "cube_cobra");
    else return;
    await rotoStore(eventId).refresh(true);
  } catch (e) {
    reportError(e, "roto");
  }
}

/**
 * The cube (one of your Library cubes, or a Cube Cobra link imported into your Library first), picks per player,
 * pick order and the pick clock. Picks per player and order are sent with Start draft.
 */
export function RotoSetupFields({ event, players, onChanged }: { event: Table1Event; players: number; onChanged: () => void }) {
  const s = useRoto(event.id);
  const { userId } = useSession();
  const lists = useLists(userId);
  const [link, setLink] = useState("");
  const [working, setWorking] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [maxPicks, setMaxPicks] = useState<number | null>(null);
  if (!s) return null;
  const store = s;
  const cubes = lists.lists.filter((l) => l.kind === "cube");
  const chosen = store.draft.sourceListId;
  const n = Math.max(1, players);
  const maxPerPlayer = Math.min(100, maxPicks ?? (store.draft.poolCount > 0 ? Math.floor(store.draft.poolCount / n) : 100));
  const picks = Math.max(1, Math.min(store.planPicks, maxPerPlayer));

  async function use(listId: string, from: "library" | "cube_cobra", load?: () => Promise<string>) {
    setWorking(listId);
    setError(null);
    try {
      const id = load ? await load() : listId;
      const r = await rotoSetCube(event.id, id, from);
      setMaxPicks(r.maxPicksPerPlayer);
      if (store.planPicks > r.maxPicksPerPlayer) store.setPlan({ picks: r.maxPicksPerPlayer });
      if (load) setLink("");
      await store.refresh(true);
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e));
    } finally {
      setWorking(null);
    }
  }

  return (
    <>
      <Section title="Cube for the draft" />
      {cubes.length === 0 && <Notice tone="info">{lists.ready ? "No cubes in your Library yet. Paste a Cube Cobra link below to import one." : "Loading your cubes…"}</Notice>}
      {cubes.map((c) => (
        <Row key={c.id} title={c.name} detail={`${countOf(c, "main")} cards · Library`} value={chosen === c.id ? "Selected" : "Use"}
             accentValue={chosen === c.id} onClick={working ? undefined : () => void use(c.id, "library")} />
      ))}
      <Field label="Or a Cube Cobra link" value={link} onChange={setLink} type="url" placeholder="https://cubecobra.com/cube/overview/…" />
      {link.trim() !== "" && (
        <div className="flex">
          <GhostAction label={working === "import" ? "Importing…" : "Import into Library and use"} disabled={!!working}
                       onClick={() => {
                         const url = link.trim();
                         if (!/^https:\/\//i.test(url)) return setError("Paste a Cube Cobra link (https://cubecobra.com/…)");
                         void use("import", "cube_cobra", () => importCube(url));
                       }} />
        </div>
      )}
      {working && working !== "import" && <Notice tone="info">Setting the cube…</Notice>}
      {error && <Notice tone="error">{error}</Notice>}
      {store.draft.poolCount > 0 && (
        <Notice tone="info">{store.draft.poolCount} cards in the pool · up to {maxPerPlayer} picks each for {n} players.</Notice>
      )}

      <Section title="Picks" />
      <Stepper label="Picks per player" value={picks} min={1} max={Math.max(1, maxPerPlayer)}
               onChange={(v) => store.setPlan({ picks: v })} />
      <Segmented label="Order" value={store.planOrder} onChange={(v) => store.setPlan({ order: v })}
                 options={[{ value: "snake", label: "Snake" }, { value: "fixed", label: "Same order" }]} />
      <Notice tone="info">{store.planOrder === "snake" ? `1 → ${n}, then ${n} → 1, and so on.` : "Seat 1 picks first every round."}</Notice>

      <RotoClockEditor ranges={store.draft.clock ?? []} rounds={picks} save={(r) => store.setClock(r)} />
    </>
  );
}

/** Setup's big action for a roto: Start draft (roto_start) instead of Pair round 1. */
export function RotoStartAction({ event, activePlayers, onStarted }: { event: Table1Event; activePlayers: number; onStarted: () => void }) {
  const s = useRoto(event.id);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!s) return null;
  const store = s;
  const blocker = activePlayers < 2 ? "Add at least 2 players" : !store.draft.sourceListId ? "Choose a cube in Details" : null;
  const maxPer = store.draft.poolCount > 0 ? Math.floor(store.draft.poolCount / Math.max(1, activePlayers)) : 100;
  const picks = Math.max(1, Math.min(store.planPicks, maxPer, 100));
  const start = async () => {
    setBusy(true);
    setError(null);
    try {
      await rotoStart(event.id, picks, store.planOrder, store.draft.clock?.length ?? 0);
      await store.refresh(true);
      setConfirm(false);
      onStarted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String((e as { message?: string })?.message ?? e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <BigAction label={blocker ?? "Start draft"} tone="accent" disabled={!!blocker} busy={busy} onClick={() => { setError(null); setConfirm(true); }} />
      {confirm && (
        <Dialog title="Start the draft?" cancelLabel="Not yet" confirmLabel="Start" busyLabel="Starting…" busy={busy} error={error}
                message={`${activePlayers} players, ${picks} picks each, ${store.planOrder === "snake" ? "snake order" : "the same order every round"}. Players and seats lock until the draft is done; everyone gets a deck in their Library that fills as they pick.`}
                onCancel={() => setConfirm(false)} onConfirm={() => void start()} />
      )}
    </>
  );
}

/* ── pick clock ───────────────────────────────────────────────────── */

/**
 * Optional time per pick on a schedule that quickens: ranges of rounds, each with a time (30 s to 24 h).
 * `ROUNDS 1–10 · 4 H`; Add a range splits the last one. Saved ~600 ms after the last change.
 */
export function RotoClockEditor({ ranges, rounds, save }: {
  ranges: RotoClockRange[]; rounds: number; save: (r: RotoClockRange[]) => Promise<boolean>;
}) {
  const [local, setLocal] = useState<RotoClockRange[] | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const saveRef = useRef(save);
  saveRef.current = save;
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);
  const shown = local ?? ranges;
  const change = (next: RotoClockRange[]) => {
    setLocal(next);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(async () => {
      timer.current = null;
      if (await saveRef.current(next)) setLocal(null);
    }, 600);
  };
  return (
    <>
      <Section title="Pick clock" />
      <SwitchRow label="Pick clock" detail={shown.length ? "Time per pick, by round" : "Off: no time limit"} on={shown.length > 0}
                 onChange={(on) => change(on ? [{ fromRound: 1, seconds: 14400 }] : [])} />
      {shown.map((r, i) => {
        const end = i + 1 < shown.length ? shown[i + 1].fromRound - 1 : Math.max(rounds, r.fromRound);
        const low = i > 0 ? shown[i - 1].fromRound + 1 : 1;
        const high = Math.max(low, (i + 1 < shown.length ? shown[i + 1].fromRound : rounds + 1) - 1);
        return (
          <div key={i} className="flex flex-col gap-px">
            <label className="bg-t1-surface px-4 py-3 flex items-center gap-3">
              <span className="flex-1 min-w-0 flex flex-col gap-0.5">
                <span className="text-[13px]">{end > r.fromRound ? `Rounds ${r.fromRound}–${end}` : `Round ${r.fromRound}`}</span>
                {i === 0 && <span className="t1-label">From the first pick</span>}
              </span>
              <select value={r.seconds} aria-label="Time per pick"
                      onChange={(e) => change(shown.map((x, j) => (j === i ? { ...x, seconds: Number(e.target.value) } : x)))}
                      className="bg-t1-bg text-t1-accent text-[11px] uppercase tracking-[1px] px-2 py-2 border-0 outline-0">
                {CLOCK_DURATIONS.map((d) => <option key={d} value={d}>{durationText(d)}</option>)}
              </select>
            </label>
            {i > 0 && (
              <div className="flex gap-px">
                <div className="flex-1">
                  <Stepper label="Starts at round" value={r.fromRound} min={low} max={high}
                           onChange={(v) => change(shown.map((x, j) => (j === i ? { ...x, fromRound: v } : x)))} />
                </div>
                <button type="button" onClick={() => change(shown.filter((_, j) => j !== i))}
                        className="w-[84px] bg-t1-surface hover:bg-t1-surface-hover t1-label text-t1-danger!">Remove</button>
              </div>
            )}
          </div>
        );
      })}
      {shown.length > 0 && shown.length < 10 && rounds - shown[shown.length - 1].fromRound >= 1 && (
        <div className="flex"><GhostAction label="Add a range" onClick={() => change(addClockRange(shown, rounds))} /></div>
      )}
      {shown.length > 0 && (
        <Notice tone="info">
          Your time starts when your turn does. When it runs out, the first card on your list is picked; with nothing listed the
          draft waits and the organizer can pick for you.
        </Notice>
      )}
    </>
  );
}

/* ── Live: round robin schedule ───────────────────────────────────── */

/**
 * Each player's opponents by round (the engine's circle method over the pick order, lib/roundrobin.ts): played
 * rounds with scores, the current one marked, upcoming ones plain.
 */
export function RotoSchedule({ bundle, meId }: { bundle: EventBundle; meId: string | null }) {
  const roster = roundRobinRoster(bundle.participants);
  const total = Math.max(bundle.event.numberOfRounds, roundRobinRounds(roster.length));
  const [player, setPlayer] = useState<string | null>(null);
  const chosen = player ?? (roster.some((p) => p.id === meId) ? meId : null) ?? roster[0]?.id ?? null;
  const active = bundle.rounds.find((r) => r.status === "active");
  const current = active?.number ?? bundle.rounds.reduce((n, r) => Math.max(n, r.number), 0);
  const name = (id: string) => bundle.participants.find((p) => p.id === id)?.displayName ?? "—";
  const ids = roster.map((p) => p.id);
  const opponent = (id: string, round: number) => {
    for (const [a, b] of roundRobinPairs(ids, round)) {
      if (a === id) return b;
      if (b === id) return a;
    }
    return null;
  };
  return (
    <>
      <Section title={`Round ${Math.max(1, current)} of ${total} · everyone plays everyone`} />
      <div className="shrink-0 flex gap-px overflow-x-auto">
        {roster.map((p) => (
          <button key={p.id} type="button" onClick={() => setPlayer(p.id)}
                  className={`shrink-0 px-3.5 py-3.5 text-[11px] uppercase tracking-[1px] ${p.id === chosen ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover"}`}>
            {p.id === meId ? "You" : p.displayName}
          </button>
        ))}
      </div>
      {chosen && Array.from({ length: Math.max(1, total) }, (_, i) => i + 1).map((r) => {
        const opp = opponent(chosen, r);
        const m = bundle.rounds.find((x) => x.number === r)?.matches.find((x) => x.sides.some((s) => s.participantId === chosen));
        let value = "";
        if (m && (m.status !== "pending" || m.isBye)) {
          if (m.isBye) value = "Bye";
          else {
            const mine = m.sides.find((s) => s.participantId === chosen)?.gameWins ?? 0;
            const theirs = m.sides.find((s) => s.participantId !== chosen)?.gameWins ?? 0;
            value = `${mine > theirs ? "W" : mine < theirs ? "L" : "D"} ${mine}–${theirs}`;
          }
        } else if (r < current) value = "No result";
        return <Row key={r} title={opp ? name(opp) : "Bye"} detail={r === current ? `Round ${r} · playing now` : `Round ${r}`} value={value} />;
      })}
      {roster.length < 2 && <Notice tone="info">The schedule appears once round 1 is paired.</Notice>}
    </>
  );
}

