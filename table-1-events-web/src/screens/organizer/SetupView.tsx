import { useState } from "react";
import { addGuest, addSelfToEvent, errorMessage, pairNextRound, removeParticipant, seatMove, seatPlayers, seatSwap, setEventPods, setSeatEnds } from "../../lib/api";
import { capture } from "../../lib/telemetry";
import { useSession } from "../../lib/useSession";
import { AddByName, tidyName } from "../../components/EventFormFields";
import { slotLetter } from "../../lib/formats";
import { startBlocker, startDialog } from "../../lib/organizer";
import { teamProblems } from "../../lib/teams";
import { toTeams, useSeating } from "../../lib/useEventExtras";
import type { EventTeam, Participant, SeatingPod } from "../../lib/types";
import { BigAction, Dialog, GhostAction, Menu, Modal, Notice, PodHeader, Row, Section, SwitchRow, type MenuItem } from "../../components/kit";
import { SeatingPanel } from "../../components/SeatingPanel";
import { SharePanel } from "../../components/SharePanel";
import { TeamsPanel } from "../../components/TeamsPanel";
import { DetailsForm } from "./DetailsForm";
import { DecklistPanel, DraftPodFields, WaitlistRows, copyEventLink, decklistDetail, decklistOf, decklistsMissing } from "../../components/EventExtras";
import { playerSections, podRefs, type PodPairing } from "../../lib/draftPods";
import { decklistsLine, when } from "../../lib/scheduledEvents";
import { RotoPickOrder, RotoStartAction } from "../roto/lazy";
import type { PhaseViewProps } from "./shared";
import { Avatar } from "../../components/Avatar";

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
  const { event } = bundle;
  const isRoto = event.formatName === "roto";
  // Players removed here are hidden at once while the server call and reload catch up.
  const [removed, setRemoved] = useState<ReadonlySet<string>>(new Set());
  const participants = bundle.participants.filter((p) => !removed.has(p.id));
  const [showQr, setShowQr] = useState(false);
  const [seatingBusy, setSeatingBusy] = useState(false);
  const [confirmStart, setConfirmStart] = useState(false);
  const [starting, setStarting] = useState(false);
  const [startError, setStartError] = useState<string | null>(null);
  const { seating: pods, setSeating } = useSeating(eventId, isDraft && !isRoto, participants, teams);
  const { userId } = useSession();
  const me = userId ? participants.find((p) => p.userId === userId) ?? null : null;
  const [guestName, setGuestName] = useState("");
  const [playersBusy, setPlayersBusy] = useState(false);
  const [removing, setRemoving] = useState<(typeof participants)[number] | null>(null);
  const [listFor, setListFor] = useState<(typeof participants)[number] | null>(null);
  const [copied, setCopied] = useState(false);
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
    // The row goes at once; the reload follows. If the server refuses, the player comes back.
    const id = removing.id;
    setRemoving(null);
    setActionError(null);
    setRemoved((s) => new Set(s).add(id));
    try {
      await removeParticipant(id);
      await refetch();
    } catch (e) {
      setRemoved((s) => {
        const next = new Set(s);
        next.delete(id);
        return next;
      });
      setActionError(errorMessage(e));
    }
  }

  const active = participants.filter((p) => p.status === "active");
  const anySeated = active.some((p) => p.seat != null);
  const teamIssue =
    isTeam && teams ? teamProblems(toTeams(teams), participants, event.teamSize ?? 3, event.formatName) : null;
  const missing = decklistsMissing(bundle);
  const blocker = startBlocker(active.length, teamIssue)
    ?? (event.decklists === "required" && missing > 0 ? `Waiting on ${missing} decklist${missing === 1 ? "" : "s"}` : null);
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

  /** Players at both ends of the table too (drawing only); the switch moves at once, the reload follows. */
  const [endsOn, setEndsOn] = useState<boolean | null>(null);
  const seatEnds = endsOn ?? event.seatEnds;
  async function changeSeatEnds(on: boolean) {
    setEndsOn(on);
    setActionError(null);
    try {
      await setSeatEnds(eventId, on);
      capture("seat_ends_changed", { on, players: (pods ?? []).reduce((n, p) => n + p.seats.length, 0) });
      await refetch();
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setEndsOn(null);
    }
  }

  // Pods (drafts): the pick, moves and swaps (contract/draft-pods-2026-11-09.md).
  const hasPods = event.formatName === "draft";
  const [seatMenu, setSeatMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [swapFrom, setSwapFrom] = useState<{ id: string; name: string } | null>(null);
  const seatedIds = new Set((pods ?? []).flatMap((p) => p.seats.map((s) => s.participant_id)));
  const unseated = event.status === "seated" ? active.filter((p) => !seatedIds.has(p.id)) : [];

  async function changePods(n: number | null, pairing: PodPairing) {
    setSeatingBusy(true);
    setActionError(null);
    try {
      await setEventPods(eventId, n, pairing);
      await refetch();
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setSeatingBusy(false);
    }
  }

  async function reseat(call: () => Promise<SeatingPod[]>) {
    setSeatingBusy(true);
    setActionError(null);
    try {
      setSeating(await call());
      setSeatingBusy(false);
      void refetch();
    } catch (e) {
      setActionError(errorMessage(e));
      setSeatingBusy(false);
    }
  }

  function tapSeat(seat: SeatingPod["seats"][number], pod: SeatingPod) {
    if (swapFrom) {
      const from = swapFrom.id;
      setSwapFrom(null);
      if (from !== seat.participant_id) void reseat(() => seatSwap(from, seat.participant_id));
      return;
    }
    const id = seat.participant_id;
    const items: MenuItem[] = (pods ?? []).filter((p) => p.pod_id !== pod.pod_id).map((other) => ({
      title: `Move to ${other.name}`, detail: `${other.seats.length} players`,
      onClick: () => void reseat(() => seatMove(id, other.pod_id)),
    }));
    if (pod.seats.length > 1) items.push({ title: "Move to a new pod", onClick: () => void reseat(() => seatMove(id, null)) });
    items.push({ title: "Swap with…", onClick: () => setSwapFrom({ id, name: seat.display_name }) });
    setSeatMenu({ title: `${pod.name} · seat ${seat.seat} · ${seat.display_name}`, items });
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
    return [who, team, decklistDetail(bundle, p)].filter(Boolean).join(" · ");
  };
  const takesLists = event.decklists !== "off";

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
              <GhostAction
                label={copied ? "Link copied" : "Copy sign-up link"}
                onClick={() => void copyEventLink(event).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 2000); })}
              />
            </div>
            <Row title="Join code" detail={[when(event.startsAt), event.venueName].filter(Boolean).join(" · ") || undefined}
                 value={<span className="tracking-[4px]">{event.shortCode}</span>} />
            <Section title={event.capacity ? `Players · ${active.length}/${event.capacity}` : "Players"}
                     count={event.capacity ? undefined : participants.length} />
            {takesLists && (
              <Notice tone="info">
                {decklistsLine(active.length - missing, active.length)}
                {event.decklists === "required" ? " · required before round 1" : ""}
              </Notice>
            )}
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
            {(() => {
              const row = (p: Participant) => takesLists ? (
              <div key={p.id} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
                <Avatar name={p.displayName} userId={p.userId} opens="event_players" />
                <span className="flex-1 min-w-0 flex flex-col gap-0.5">
                  <span className="text-[13px] truncate">{p.id === me?.id ? `You · ${p.displayName}` : p.displayName}</span>
                  <span className="t1-label truncate">{playerDetail(p)}</span>
                </span>
                <button type="button" className="t1-label text-t1-accent" onClick={() => setListFor(p)}>
                  {decklistOf(bundle, p.id) ? "List" : "Enter list"}
                </button>
                <button type="button" className="t1-label text-t1-danger disabled:opacity-40" disabled={playersBusy} onClick={() => setRemoving(p)}>
                  Remove
                </button>
              </div>
            ) : (
              <Row
                key={p.id}
                title={p.id === me?.id ? `You · ${p.displayName}` : p.displayName}
                avatar={<Avatar name={p.displayName} userId={p.userId} opens="event_players" />}
                detail={[playerDetail(p), (isDraft || isRoto) && p.seat != null ? `${isRoto ? "Pick" : "Seat"} ${p.seat}` : null].filter(Boolean).join(" · ")}
                action={{ label: "Remove", onClick: () => setRemoving(p), disabled: playersBusy }}
                dim={p.status === "dropped"}
              />
            );
              const sections = playerSections(participants, podRefs(event.formatName, bundle.pods), (p) => p.podId, (p) => p.seat);
              // A seated draft with 2+ pods: each pod's players by seat, then anyone who joined after the draw.
              return sections ? sections.map((s) => (
                <div key={s.pod ?? s.title} className="flex flex-col gap-px">
                  <PodHeader title={s.title} right={`${s.items.length} player${s.items.length === 1 ? "" : "s"}`} />
                  {s.items.map(row)}
                </div>
              )) : participants.map(row);
            })()}
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
            <WaitlistRows bundle={bundle} onChanged={() => void refetch()} onError={setActionError} />
          </>
        )}

        {tab === "seating" && isRoto && (
          <RotoPickOrder participants={participants} meId={me?.id ?? null} busy={seatingBusy} onSeat={() => void seat()} />
        )}

        {tab === "seating" && isDraft && !isRoto && (
          <>
            {hasPods && (
              <DraftPodFields pods={event.pods} pairing={event.podPairing} players={active.length} seated={anySeated && !!pods?.length && event.status === "seated"}
                              onChange={(n, p) => void changePods(n, p)} />
            )}
            <button
              type="button"
              onClick={seat}
              disabled={seatingBusy || active.length === 0}
              className="shrink-0 bg-t1-surface hover:bg-t1-surface-hover py-3.5 text-[11px] uppercase tracking-[1px] disabled:opacity-50"
            >
              {seatingBusy ? "Seating…" : anySeated ? "Randomize" : "Seat players"}
            </button>
            {swapFrom && (
              <Row title={`Swap ${swapFrom.name} with…`} detail="Tap the other player"
                   action={{ label: "Cancel", onClick: () => setSwapFrom(null) }} />
            )}
            {anySeated && pods ? (<>
              <SwitchRow label="Seat the ends" detail="Players at both ends of the table, not just the sides" on={seatEnds} onChange={(on) => void changeSeatEnds(on)} />
              <SeatingPanel pods={pods} formatName={event.formatName} participants={participants} teams={teams} seatEnds={seatEnds}
                            highlightParticipantId={swapFrom?.id ?? me?.id ?? null}
                            onSeatTap={hasPods && event.status === "seated" && !seatingBusy ? tapSeat : undefined} />
              {unseated.length > 0 && (<>
                <Section title="Not seated" count={unseated.length} />
                {unseated.map((p) => (
                  <Row key={p.id} title={p.displayName} detail="Seated at round 1, in the smallest pod"
                       avatar={<Avatar name={p.displayName} userId={p.userId} />} />
                ))}
              </>)}
            </>
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

        {tab === "details" && <DetailsForm event={event} players={active.length} onSaved={() => void refetch()} />}
      </div>

      {isRoto ? (
        <RotoStartAction event={event} activePlayers={active.length} onStarted={() => void refetch()} />
      ) : (
      <BigAction
        label={blocker ?? "Start event · pair round 1"}
        disabled={!!blocker}
        busy={starting}
        onClick={() => {
          setStartError(null);
          setConfirmStart(true);
        }}
      />
      )}

      {showQr && (
        <Modal title={`Join ${event.name}`} onClose={() => setShowQr(false)}>
          <SharePanel shortCode={event.shortCode} eventId={event.id} />
          <GhostAction label="Done" onClick={() => setShowQr(false)} />
        </Modal>
      )}

      {listFor && (
        <DecklistPanel event={event} participantId={listFor.id} playerName={listFor.displayName} byOrganizer
                       onClose={(changed) => { setListFor(null); if (changed) void refetch(); }} />
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
          tone="danger"
          onCancel={() => setRemoving(null)}
          onConfirm={confirmRemove}
        />
      )}

      {seatMenu && <Menu title={seatMenu.title} items={seatMenu.items} onClose={() => setSeatMenu(null)} />}
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
