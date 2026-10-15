import { useState } from "react";
import { addGuest, addSelfToEvent, errorMessage, pairNextRound, removeParticipant, seatPlayers } from "../../lib/api";
import { useSession } from "../../lib/useSession";
import { AddByName, tidyName } from "../../components/EventFormFields";
import { slotLetter } from "../../lib/formats";
import { startBlocker, startDialog } from "../../lib/organizer";
import { teamProblems } from "../../lib/teams";
import { toTeams, useSeating } from "../../lib/useEventExtras";
import type { EventTeam } from "../../lib/types";
import { BigAction, Dialog, GhostAction, Modal, Notice, Row, Section } from "../../components/kit";
import { SeatingPanel } from "../../components/SeatingPanel";
import { SharePanel } from "../../components/SharePanel";
import { TeamsPanel } from "../../components/TeamsPanel";
import { DetailsForm } from "./DetailsForm";
import type { PhaseViewProps } from "./shared";

/** Setup: Players | Seating (drafts) | Teams (team events) | Details, and "Start event · pair round 1". */
export function SetupView({
  eventId,
  bundle,
  tab,
  isTeam,
  isDraft,
  teams,
  teamNames,
  refetch,
  setActionError,
  onAddPlayers,
  onTeamsSaved,
}: PhaseViewProps & { onAddPlayers: () => void; onTeamsSaved: (rows: EventTeam[]) => void }) {
  const { event, participants } = bundle;
  const [showQr, setShowQr] = useState(false);
  const [seatingBusy, setSeatingBusy] = useState(false);
  const [confirmStart, setConfirmStart] = useState(false);
  const [starting, setStarting] = useState(false);
  const [startError, setStartError] = useState<string | null>(null);
  const { seating: pods, setSeating } = useSeating(eventId, isDraft, participants, teams);
  const { userId } = useSession();
  const me = userId ? participants.find((p) => p.userId === userId) ?? null : null;
  const [guestName, setGuestName] = useState("");
  const [playersBusy, setPlayersBusy] = useState(false);
  const [removing, setRemoving] = useState<(typeof participants)[number] | null>(null);
  const [removeError, setRemoveError] = useState<string | null>(null);
  const guest = tidyName(guestName);
  const guestDup = !!guest && participants.some((p) => p.displayName.toLowerCase() === guest.toLowerCase());

  async function playersCall(call: () => Promise<void>) {
    setPlayersBusy(true);
    setActionError(null);
    try {
      await call();
      await refetch();
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setPlayersBusy(false);
    }
  }

  async function confirmRemove() {
    if (!removing) return;
    setPlayersBusy(true);
    setRemoveError(null);
    try {
      await removeParticipant(removing.id);
      setRemoving(null);
      await refetch();
    } catch (e) {
      setRemoveError(errorMessage(e));
    } finally {
      setPlayersBusy(false);
    }
  }

  const active = participants.filter((p) => p.status === "active");
  const anySeated = active.some((p) => p.seat != null);
  const teamIssue =
    isTeam && teams ? teamProblems(toTeams(teams), participants, event.teamSize ?? 3, event.formatName) : null;
  const blocker = startBlocker(active.length, teamIssue);
  const dialog = startDialog(event);

  async function seat() {
    setSeatingBusy(true);
    setActionError(null);
    try {
      // Show the new seats right away; the rest of the screen catches up in the background.
      setSeating(await seatPlayers(eventId));
      setSeatingBusy(false);
      void refetch();
    } catch (e) {
      setActionError(errorMessage(e));
      setSeatingBusy(false);
    }
  }

  async function start() {
    setStarting(true);
    setStartError(null);
    try {
      await pairNextRound(eventId);
      setConfirmStart(false);
      await refetch();
    } catch (e) {
      setStartError(errorMessage(e));
    } finally {
      setStarting(false);
    }
  }

  const playerDetail = (p: (typeof participants)[number]) => {
    const who = p.status === "dropped" ? "Dropped" : p.userId ? "Joined" : "Guest";
    const team = isTeam ? (p.teamId ? `${teamNames.get(p.teamId) ?? "Team"} · ${slotLetter(p.teamSlot)}` : "No team") : null;
    return [who, team].filter(Boolean).join(" · ");
  };

  return (
    <>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {tab === "players" && (
          <>
            <div className="flex gap-px shrink-0">
              <button
                type="button"
                onClick={onAddPlayers}
                className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px]"
              >
                Add players
              </button>
              <GhostAction label="Show join QR" onClick={() => setShowQr(true)} />
            </div>
            <Row title="Join code" value={<span className="tracking-[4px]">{event.shortCode}</span>} />
            <Section title="Players" count={participants.length} />
            {userId && !me && (
              <Row
                title="You're not playing"
                detail="Organizing only"
                action={{ label: "Join as a player", onClick: () => void playersCall(() => addSelfToEvent(eventId)), disabled: playersBusy }}
              />
            )}
            {participants.length === 0 && (
              <Notice tone="info">Nobody yet. Add players, or show the join QR so they can scan in.</Notice>
            )}
            {participants.map((p) => (
              <Row
                key={p.id}
                title={p.id === me?.id ? `You · ${p.displayName}` : p.displayName}
                detail={[playerDetail(p), isDraft && p.seat != null ? `Seat ${p.seat}` : null].filter(Boolean).join(" · ")}
                action={{ label: "Remove", onClick: () => { setRemoveError(null); setRemoving(p); }, disabled: playersBusy }}
                dim={p.status === "dropped"}
              />
            ))}
            <AddByName
              value={guestName}
              onChange={setGuestName}
              disabled={!guest || guestDup || playersBusy}
              onAdd={() => {
                const name = guest;
                setGuestName("");
                void playersCall(() => addGuest(eventId, name));
              }}
            />
            {guestDup && <Notice tone="error">{guest} is already in this event.</Notice>}
          </>
        )}

        {tab === "seating" && isDraft && (
          <>
            <button
              type="button"
              onClick={seat}
              disabled={seatingBusy || active.length === 0}
              className="shrink-0 bg-t1-surface hover:bg-t1-surface-hover py-3.5 text-[11px] uppercase tracking-[1px] disabled:opacity-50"
            >
              {seatingBusy ? "Seating…" : anySeated ? "Re-seat" : "Seat players"}
            </button>
            {anySeated && pods ? (
              <SeatingPanel pods={pods} formatName={event.formatName} participants={participants} teams={teams} />
            ) : (
              <Notice tone="info">
                {active.length} player{active.length === 1 ? "" : "s"}. Seat players now, or pairing round 1 seats
                everyone at random.
              </Notice>
            )}
          </>
        )}

        {tab === "teams" && isTeam && (
          <TeamsPanel
            eventId={eventId}
            formatName={event.formatName}
            teamSize={event.teamSize ?? 3}
            participants={participants}
            teams={teams}
            locked={false}
            onSaved={onTeamsSaved}
          />
        )}

        {tab === "details" && <DetailsForm event={event} onSaved={() => void refetch()} />}
      </div>

      <BigAction
        label={blocker ?? "Start event · pair round 1"}
        disabled={!!blocker}
        busy={starting}
        onClick={() => {
          setStartError(null);
          setConfirmStart(true);
        }}
      />

      {showQr && (
        <Modal title={`Join ${event.name}`} onClose={() => setShowQr(false)}>
          <SharePanel shortCode={event.shortCode} eventId={event.id} />
          <GhostAction label="Done" onClick={() => setShowQr(false)} />
        </Modal>
      )}

      {removing && (
        <Dialog
          title={`Remove ${removing.displayName}?`}
          message={
            removing.seat != null && event.status === "seated"
              ? "They'll leave the event. Seats after theirs move up one."
              : "They'll leave the event."
          }
          cancelLabel="Keep"
          confirmLabel="Remove"
          busyLabel="Removing…"
          tone="danger"
          busy={playersBusy}
          error={removeError}
          onCancel={() => setRemoving(null)}
          onConfirm={confirmRemove}
        />
      )}

      {confirmStart && (
        <Dialog
          title={dialog.title}
          message={dialog.message}
          cancelLabel="Not yet"
          confirmLabel="Start"
          busyLabel="Pairing…"
          busy={starting}
          error={startError}
          onCancel={() => setConfirmStart(false)}
          onConfirm={start}
        />
      )}
    </>
  );
}
