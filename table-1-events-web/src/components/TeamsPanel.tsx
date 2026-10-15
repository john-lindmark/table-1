import { useEffect, useState } from "react";
import { randomizeTeams, saveTeams, errorMessage } from "../lib/api";
import { slotLetter } from "../lib/formats";
import type { EventTeam, FormatName, Participant } from "../lib/types";
import { GhostAction, Notice } from "./kit";

interface DraftTeam {
  key: string;
  name: string;
  members: string[];
}

const fromRows = (rows: EventTeam[]): DraftTeam[] =>
  [...rows]
    .sort((a, b) => a.order - b.order)
    .map((t) => ({
      key: t.id,
      name: t.name,
      members: [...t.members].sort((a, b) => a.slot - b.slot).map((m) => m.participant_id),
    }));

/**
 * Organizer's Teams tab. Every change saves the whole layout with set_teams (member order = slot order).
 * Read-only once round 1 is paired.
 */
export function TeamsPanel({
  eventId,
  formatName,
  teamSize,
  participants,
  teams,
  locked,
  onSaved,
}: {
  eventId: string;
  formatName: FormatName;
  teamSize: number;
  participants: Participant[];
  teams: EventTeam[] | null;
  locked: boolean;
  onSaved: (rows: EventTeam[]) => void;
}) {
  const [draft, setDraft] = useState<DraftTeam[]>(() => fromRows(teams ?? []));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Server state wins whenever it changes (another organizer, randomize, save).
  useEffect(() => {
    if (teams) setDraft(fromRows(teams));
  }, [teams]);

  const byId = new Map(participants.map((p) => [p.id, p]));
  const placed = new Set(draft.flatMap((t) => t.members));
  const unassigned = participants.filter((p) => p.status === "active" && !placed.has(p.id));
  const teamDraft = formatName === "team_draft";
  const canAddTeam = !locked && (!teamDraft || draft.length < 2);

  async function persist(next: DraftTeam[]) {
    const prev = draft;
    setDraft(next);
    setBusy(true);
    setError(null);
    try {
      const rows = await saveTeams(
        eventId,
        next.map((t) => ({
          name: t.name.trim() || "Team",
          // Dropped players can't be placed; the server only takes active ones.
          members: t.members.filter((id) => byId.get(id)?.status === "active"),
        })),
      );
      onSaved(rows);
    } catch (e) {
      setDraft(prev);
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function randomize() {
    setBusy(true);
    setError(null);
    try {
      onSaved(await randomizeTeams(eventId));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  function move(participantId: string, toKey: string) {
    const next = draft.map((t) => ({ ...t, members: t.members.filter((id) => id !== participantId) }));
    if (toKey) {
      const target = next.find((t) => t.key === toKey);
      if (!target) return;
      target.members.push(participantId);
    }
    void persist(next);
  }

  function rename(key: string, name: string) {
    const current = draft.find((t) => t.key === key);
    const clean = name.trim().slice(0, 40);
    if (!current || !clean || clean === current.name) {
      setDraft((d) => d.map((t) => (t.key === key ? { ...t, name: current?.name ?? t.name } : t)));
      return;
    }
    void persist(draft.map((t) => (t.key === key ? { ...t, name: clean } : t)));
  }

  function addTeam() {
    void persist([...draft, { key: `new-${Date.now()}`, name: `Team ${draft.length + 1}`, members: [] }]);
  }

  function removeTeam(key: string) {
    void persist(draft.filter((t) => t.key !== key));
  }

  const playerRow = (id: string, slot: number | null, teamKey: string) => {
    const p = byId.get(id);
    if (!p) return null;
    return (
      <div key={id} className="bg-t1-surface px-4 py-2.5 flex items-center gap-3">
        <span className="w-5 t1-label text-t1-accent!">{slot ? slotLetter(slot) : "·"}</span>
        <span className={`flex-1 min-w-0 truncate text-[13px] ${p.status === "dropped" ? "line-through opacity-50" : ""}`}>
          {p.displayName}
        </span>
        {!locked && (
          <select
            aria-label={`Move ${p.displayName} to…`}
            value={teamKey}
            disabled={busy}
            onChange={(e) => move(id, e.target.value)}
            className="bg-t1-bg text-t1-text text-[11px] uppercase tracking-[1px] px-2 py-1.5 border-0 outline-0 max-w-[45%]"
          >
            <option value={teamKey} disabled>
              Move to…
            </option>
            {draft
              .filter((t) => t.key !== teamKey)
              .map((t) => (
                <option key={t.key} value={t.key} disabled={t.members.length >= teamSize}>
                  {t.name}
                  {t.members.length >= teamSize ? " (full)" : ""}
                </option>
              ))}
            {teamKey !== "" && <option value="">Unassigned</option>}
          </select>
        )}
      </div>
    );
  };

  return (
    <div className="flex flex-col gap-px">
      {locked ? (
        <Notice tone="info">Teams lock when round 1 is paired</Notice>
      ) : (
        <>
          <div className="flex gap-px">
            <GhostAction label={busy ? "Saving…" : "Randomize"} onClick={randomize} disabled={busy} />
            <GhostAction label="+ Team" onClick={addTeam} disabled={busy || !canAddTeam} />
          </div>
          <Notice tone="info">
            Teams of {teamSize}
            {teamDraft ? " · a team draft has exactly two teams" : ""}. Teams lock when round 1 is paired.
          </Notice>
        </>
      )}
      {error && <Notice tone="error">{error}</Notice>}

      {draft.map((t) => (
        <div key={t.key} className="flex flex-col gap-px">
          <div className="bg-t1-surface px-4 py-2 flex items-center gap-3">
            {locked ? (
              <span className="flex-1 text-[13px] truncate">{t.name}</span>
            ) : (
              <input
                aria-label="Team name"
                value={t.name}
                maxLength={40}
                disabled={busy}
                onChange={(e) => setDraft((d) => d.map((x) => (x.key === t.key ? { ...x, name: e.target.value } : x)))}
                onBlur={(e) => rename(t.key, e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
                className="flex-1 min-w-0 bg-transparent border-0 outline-0 text-[13px] text-t1-text py-1"
              />
            )}
            <span className="t1-label shrink-0">
              {t.members.length}/{teamSize}
            </span>
            {!locked && t.members.length === 0 && (
              <button className="t1-label shrink-0" disabled={busy} onClick={() => removeTeam(t.key)}>
                Remove
              </button>
            )}
          </div>
          {t.members.length === 0 && <div className="bg-t1-bg px-4 py-2.5 t1-label">No players</div>}
          {t.members.map((id, i) => playerRow(id, i + 1, t.key))}
        </div>
      ))}

      {(unassigned.length > 0 || !locked) && (
        <>
          <div className="bg-t1-surface px-4 py-2 flex justify-between t1-label">
            <span>Unassigned</span>
            <span>{unassigned.length}</span>
          </div>
          {unassigned.length === 0 && <div className="bg-t1-bg px-4 py-2.5 t1-label">Everyone is on a team</div>}
          {unassigned.map((p) => playerRow(p.id, null, ""))}
        </>
      )}
    </div>
  );
}
