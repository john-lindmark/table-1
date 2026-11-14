import { useEffect, useState } from "react";
import { extensionText, judgeLine } from "../lib/leagues";
import { EXTRA_PICKS, judgeCall, judgeCallCancel, judgeCallResolve, matchTimeExtend, type EventRoom, type JudgeCall } from "../lib/room";
import { Dialog, GhostAction, Notice, useNow } from "./kit";

/* The room on the organizer's and a player's screens (contract/room-tools-2026-11-13.md §§ 2, 3): open judge calls
   leading the Round tab, Extra time for a table, and a player's Call a judge / JUDGE CALLED. Each draws nothing while
   the server has no room (`room` null). */

const message = (e: unknown) => (e instanceof Error ? e.message : String((e as { message?: unknown } | null)?.message ?? e));

/** Organizer, Live → Round: open calls oldest first, each `JUDGE · TABLE 7 · BEA · 2 MIN` with Done. */
export function JudgeCalls({ eventId, calls, onChanged }: { eventId: string; calls: JudgeCall[] | null | undefined; onChanged: () => void }) {
  const now = useNow(!!calls?.length, 15000);
  const [gone, setGone] = useState<ReadonlySet<string>>(new Set());
  const [error, setError] = useState<string | null>(null);
  const open = (calls ?? []).filter((c) => !gone.has(c.call_id));
  if (open.length === 0 && !error) return null;
  const done = (c: JudgeCall) => {
    // The row goes at once; the reload follows. If the server refuses, it comes back.
    setGone((s) => new Set(s).add(c.call_id));
    setError(null);
    judgeCallResolve(c.call_id, eventId).then(onChanged, (e) => {
      setGone((s) => { const next = new Set(s); next.delete(c.call_id); return next; });
      setError(message(e));
    });
  };
  return (
    <div className="flex flex-col gap-px" role="status" aria-label="Judge calls">
      {open.map((c) => (
        <div key={c.call_id} className="bg-t1-surface outline outline-1 -outline-offset-1 outline-t1-accent px-4 py-3 flex items-center gap-3">
          <span className="flex-1 min-w-0 text-[12px] uppercase tracking-[1.5px] truncate">{judgeLine(c, now)}</span>
          <button type="button" onClick={() => done(c)} className="shrink-0 t1-label !text-t1-text hover:!text-t1-accent px-2 py-1 -my-1">Done</button>
        </div>
      ))}
      {error && <Notice tone="error">{error}</Notice>}
    </div>
  );
}

/** Extra time for a table: +3 min, +5 min, +10 min, and Take it back when it has some. */
export function ExtraTime({ eventId, matchId, seconds, onChanged }: { eventId: string; matchId: string; seconds: number; onChanged: (next: number) => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(seconds);
  useEffect(() => setNow(seconds), [seconds]);
  const add = (by: number) => {
    setBusy(true);
    setError(null);
    matchTimeExtend(matchId, by, eventId).then((r) => { setNow(r.extra_seconds); onChanged(r.extra_seconds); }, (e) => setError(message(e))).finally(() => setBusy(false));
  };
  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-2 flex items-center justify-between t1-label">
        <span>Extra time</span>
        {now > 0 && <span className="!text-t1-text tabular-nums">{extensionText(now)}</span>}
      </div>
      <div className="flex gap-px">
        {EXTRA_PICKS.map((s) => <GhostAction key={s} label={`+${s / 60} min`} disabled={busy} onClick={() => add(s)} />)}
      </div>
      {now > 0 && <div className="flex"><GhostAction label="Take it back" disabled={busy} onClick={() => add(-now)} /></div>}
      {error && <Notice tone="error">{error}</Notice>}
    </div>
  );
}

/** A player's table: Call a judge (a confirm); while a call is open, JUDGE CALLED in the accent with Cancel. */
export function JudgeCallRow({ eventId, room, token, onChanged }: {
  eventId: string; room: EventRoom | null; token?: string | null; onChanged: () => void;
}) {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** What this device just did, shown until the room is read again. */
  const [local, setLocal] = useState<boolean | null>(null);
  const my = room?.my_match ?? null;
  useEffect(() => setLocal(null), [my?.call_open, my?.match_id]);
  if (!my) return null;
  const open = local ?? my.call_open;
  const run = (call: () => Promise<void>, next: boolean) => {
    setBusy(true);
    setError(null);
    call().then(() => { setLocal(next); setAsking(false); onChanged(); }, (e) => setError(message(e))).finally(() => setBusy(false));
  };
  return (
    <>
      {open ? (
        <div className="flex gap-px">
          <div className="flex-1 bg-t1-surface outline outline-1 -outline-offset-1 outline-t1-accent px-4 py-3 text-[12px] uppercase tracking-[2px] text-t1-accent">Judge called</div>
          <button type="button" disabled={busy} onClick={() => run(() => judgeCallCancel(my.match_id, token, eventId), false)}
                  className="bg-t1-surface hover:bg-t1-surface-hover px-5 text-[11px] uppercase tracking-[1px] disabled:opacity-40">
            Cancel
          </button>
        </div>
      ) : (
        <div className="flex"><GhostAction label="Call a judge" disabled={busy} onClick={() => { setError(null); setAsking(true); }} /></div>
      )}
      {error && !asking && <Notice tone="error">{error}</Notice>}
      {asking && (
        <Dialog title="Call a judge?" message={`The organizers are told table ${my.table_number ?? "–"} needs a judge.`} cancelLabel="Not now" confirmLabel="Call a judge"
                busyLabel="Calling…" busy={busy} error={error} onCancel={() => setAsking(false)}
                onConfirm={() => run(() => judgeCall(my.match_id, token, eventId), true)} />
      )}
    </>
  );
}
