import { useCallback, useEffect, useState } from "react";
import { Over } from "../../components/EventListing";
import { BAR_ICON, Icon } from "../../components/icons";
import { BigAction, Notice, Row, Section } from "../../components/kit";
import { finalInvitable, finalLine, finalStateLabel, leagueFinalInvite, leagueFinalStatus, leaguesError, type FinalRow, type FinalStatus } from "../../lib/leagues";

/* A season's final (contract/teams-finals-alerts-2026-11-13.md § 3): on a final you organize, Setup → Players gains a
   Qualified row (`3 of 23 in`) opening the list. Nothing for every other event, or while the server has no finals. */

export function QualifiedRow({ eventId, version }: { eventId: string; version?: unknown }) {
  const [status, setStatus] = useState<FinalStatus | null>(null);
  const [open, setOpen] = useState(false);
  const load = useCallback(async () => setStatus(await leagueFinalStatus(eventId)), [eventId]);
  useEffect(() => {
    void load();
  }, [load, version]);
  if (!status) return null;
  return (
    <>
      <Row title="Qualified" value={<span className="flex items-center gap-3"><span className="t1-label !text-t1-text">{finalLine(status)}</span><Icon d={BAR_ICON.arrow} /></span>}
           onClick={() => setOpen(true)} />
      {open && <QualifiedList eventId={eventId} status={status} onChanged={load} onClose={() => setOpen(false)} />}
    </>
  );
}

function QualifiedList({ eventId, status, onChanged, onClose }: { eventId: string; status: FinalStatus; onChanged: () => Promise<void>; onClose: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const waiting = finalInvitable(status.qualified).length;
  const invite = async (keys: string[] | null) => {
    setBusy(keys ? keys[0] : "all");
    setError(null);
    try {
      const r = await leagueFinalInvite(eventId, keys);
      setNote(r.invited === 0 ? "Nobody new to invite." : `Invited ${r.invited}.`);
      await onChanged();
    } catch (e) {
      setError(leaguesError(e));
    } finally {
      setBusy(null);
    }
  };
  const row = (r: FinalRow) => {
    const label = finalStateLabel(r.state);
    return (
      <div key={r.key} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
        <span className="w-7 shrink-0 text-[13px] tabular-nums text-t1-muted">{r.rank}</span>
        <span className="flex-1 min-w-0 flex flex-col gap-0.5">
          <span className="text-[14px] truncate">{r.name}</span>
          <span className="t1-label truncate">{[r.how ? r.how.toUpperCase() : null, `${r.points} PTS`].filter(Boolean).join(" · ")}</span>
        </span>
        {label ? <span className={`shrink-0 t1-label ${r.state === "in" ? "!text-t1-accent" : ""}`}>{label}</span> : (
          <button type="button" disabled={busy != null} onClick={() => void invite([r.key])}
                  className="shrink-0 t1-label !text-t1-text hover:!text-t1-accent disabled:opacity-40 px-2 py-1 -my-1">
            {busy === r.key ? "Inviting…" : "Invite"}
          </button>
        )}
      </div>
    );
  };
  return (
    <Over title="Qualified" onBack={onClose}
          bottom={<BigAction label={waiting > 0 ? "Invite the qualified" : "Everyone is invited"} tone="accent" disabled={waiting === 0} busy={busy === "all"} onClick={() => void invite(null)} />}>
      <Section title="Qualified" right={finalLine(status).toUpperCase()} />
      {status.qualified.length === 0 && <Notice tone="info">Nobody has qualified yet.</Notice>}
      {status.qualified.map(row)}
      {note && <Notice tone="info">{note}</Notice>}
      {error && <Notice tone="error">{error}</Notice>}
      {status.next.length > 0 && <Section title="Next in line" />}
      {status.next.map(row)}
    </Over>
  );
}
