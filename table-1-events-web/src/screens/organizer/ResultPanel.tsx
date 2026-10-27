import { useMemo, useState } from "react";
import { errorMessage, setResultAsOrganizer } from "../../lib/api";
import { matchGroupOf, matchTitle, nameLookup } from "../../lib/organizer";
import type { Match, Participant } from "../../lib/types";
import { GhostAction, Modal, Notice } from "../../components/kit";
import { MatchRow, matchState } from "../../components/MatchRow";

/**
 * The organizer's set-result panel: tap a side to cycle its game wins (the existing MatchRow editing),
 * then Set result (set_match_result, also after the event ends). Watch opens the match's life tracker.
 */
export function ResultPanel({
  match,
  participants,
  correcting,
  onClose,
  onSaved,
  onOpenLife,
  playoff = false,
}: {
  match: Match;
  /** Quarterfinals, semifinals and the final can't end in a draw. */
  playoff?: boolean;
  participants: Participant[];
  /** Results phase: the change is a correction. */
  correcting: boolean;
  onClose: () => void;
  onSaved: () => void;
  onOpenLife?: (matchId: string) => void;
}) {
  const byId = useMemo(() => new Map(participants.map((p) => [p.id, p])), [participants]);
  const [draft, setDraft] = useState<Match>(match);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const { state } = matchState(draft);
  const wins = (side: 0 | 1) => draft.sides.find((s) => s.side === side)?.gameWins ?? 0;
  const canSave = state === "decisive" || (state === "draw" && !playoff);

  function cycle(side: 0 | 1) {
    setDraft((m) => ({
      ...m,
      sides: m.sides.map((s) => (s.side === side ? { ...s, gameWins: (s.gameWins + 1) % 3 } : s)),
    }));
  }

  async function save() {
    setBusy(true);
    setError(null);
    try {
      const reason = correcting
        ? "Corrected by organizer"
        : matchGroupOf(match) === "disputed"
          ? "Dispute settled by organizer"
          : "Entered by organizer";
      await setResultAsOrganizer(match, wins(0), wins(1), draft.gameDraws ?? 0, reason);
      onSaved();
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal title={matchTitle(match, nameLookup(participants))} onClose={() => !busy && onClose()}>
      <p className="text-[12px] leading-[18px] text-t1-muted">Tap a player to change their game wins.</p>
      <MatchRow match={draft} participants={byId} canEdit onCycle={cycle} />
      {playoff && state === "draw" && <Notice tone="error">Playoff matches need a winner.</Notice>}
      {error && <Notice tone="error">{error}</Notice>}
      {onOpenLife && (
        <GhostAction label="Watch life tracker" onClick={() => onOpenLife(match.id)} />
      )}
      <div className="flex gap-px">
        <GhostAction label="Cancel" onClick={onClose} disabled={busy} />
        <button
          type="button"
          onClick={save}
          disabled={busy || !canSave}
          className="flex-1 bg-t1-text text-t1-bg px-4 py-3 text-[11px] uppercase tracking-[1px] disabled:opacity-40"
        >
          {busy ? "Saving…" : "Set result"}
        </button>
      </div>
    </Modal>
  );
}
