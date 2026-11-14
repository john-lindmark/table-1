import { canRedraft } from "../lib/redraft";
import { deckPhotoDone, deckPhotoPrompt, deckPhotoWhyLabel, loadDeckPhotos, promptRounds } from "../lib/deckPhotos";
import { capture } from "../lib/telemetry";
import { JOIN_NOTICE } from "../lib/joinPreview";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useEvent } from "../lib/useEvent";
import {
  fetchEventPreview,
  type EventPreview,
  joinEvent,
  reportMatch,
  reportResultAsPlayer,
  respondToResult,
  errorMessage,
  leaveEvent,
} from "../lib/api";
import { useSession } from "../lib/useSession";
import { getLocalParticipant, saveLocalParticipant } from "../lib/session";
import { StandingsTable } from "../components/StandingsTable";
import { useOpenProfile } from "../lib/personLink";
import { TeamStandingsTable } from "../components/TeamStandingsTable";
import { SeatingPanel } from "../components/SeatingPanel";
import { GetTheApp } from "../components/GetTheApp";
import { Bracket, DecklistPanel, decklistOf } from "../components/EventExtras";
import { countsText, roundName, when } from "../lib/scheduledEvents";
import {
  Bar,
  BigAction,
  ClockFace,
  Columns,
  Dialog,
  Field,
  GhostAction,
  Notice,
  Row,
  Screen,
  SwitchRow,
  TimerProgress,
} from "../components/kit";
import { isDraftFormat, isTeamFormat, slotLetter } from "../lib/formats";
import { useTrackerMode } from "../lib/settings";
import { RotoDraftGate, RotoDraftOverlay, RotoSchedule } from "./roto/lazy";
import { participantsKey, toTeams, useEventTeams, useSeating } from "../lib/useEventExtras";
import { EventAboutRows, PublicResultsNotice, useEventAbout } from "../components/EventListing";

const teamTitle = (name: string) => (/^team\b/i.test(name) ? name : `Team ${name}`);

/** What a player sees: their match, their result buttons, the standings. */
export function PlayerView({
  code,
  eventIdProp,
  onOpenLife,
  onOpenPhotos,
  onOpenRedraft,
  onBack,
}: {
  code?: string;
  eventIdProp?: string;
  /** Opens the shared life tracker for a match. */
  onOpenLife?: (matchId: string) => void;
  /** Deck photos for the event (signed-in players); `add` opens it with the camera / library choice up. */
  onOpenPhotos?: (eventId: string, add?: boolean) => void;
  onOpenRedraft?: (eventId: string, setCode: string | null) => void;
  /** Back to where the player came from (Events home when they arrived by link). */
  onBack?: () => void;
}) {
  const [eventId, setEventId] = useState<string | null>(eventIdProp ?? null);
  const [resolving, setResolving] = useState(!eventIdProp && !!code);
  const [name, setName] = useState("");
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState<string | null>(null);
  const [me, setMe] = useState(() => (eventIdProp ? getLocalParticipant(eventIdProp) : null));
  const [listOpen, setListOpen] = useState(false);
  const [confirmLeave, setConfirmLeave] = useState(false);
  const [leaveError, setLeaveError] = useState<string | null>(null);
  /** What a visitor sees before joining (no player list): event_preview by the code, or by id for a link. */
  const [preview, setPreview] = useState<EventPreview | null>(null);

  // Resolve a short code to an event once.
  useMemo(() => {
    if (eventId || !code) return;
    fetchEventPreview({ code })
      .then((p) => {
        setPreview(p);
        setEventId(p?.eventId ?? null);
        if (p) setMe(getLocalParticipant(p.eventId));
        if (!p) setJoinError("No open event has that code.");
      })
      .catch((e) => setJoinError(errorMessage(e)))
      .finally(() => setResolving(false));
  }, [code, eventId]);

  const { bundle, error: bundleError, stale, refetch } = useEvent(eventId);
  // Description, address and league (contract/public-events-leagues-2026-11-13.md § 1); nothing until the server has them.
  const about = useEventAbout(eventId, me?.token);

  // A link (no code) to an event you're not in yet: the preview for the join form.
  useEffect(() => {
    if (!eventIdProp || preview || me) return;
    fetchEventPreview({ eventId: eventIdProp }).then(setPreview).catch(() => {});
  }, [eventIdProp, preview, me]);
  const { userId } = useSession();
  const [notice, setNotice] = useState<string | null>(null);
  /** Roto after round 1: the read-only Draft or the round-robin Schedule over this screen. */
  const [rotoPanel, setRotoPanel] = useState<"draft" | "schedule" | null>(null);
  /** Photos of your own deck in this event, read once you're done playing (null until read). */
  const [myPhotos, setMyPhotos] = useState<number | null>(null);

  // A signed-in player is found by their account; a walk-in guest by the token on this device.
  const accountSeat = useMemo(
    () => (userId ? bundle?.participants.find((p) => p.userId === userId) ?? null : null),
    [bundle, userId],
  );
  const viewer = useMemo(() => {
    if (accountSeat) {
      return {
        participantId: accountSeat.id,
        displayName: accountSeat.displayName,
        token: null as string | null,
      };
    }
    return me ? { participantId: me.participantId, displayName: me.displayName, token: me.token } : null;
  }, [accountSeat, me]);

  const participants = useMemo(
    () => new Map((bundle?.participants ?? []).map((p) => [p.id, p])),
    [bundle],
  );
  // Once your last match is in (contract/event-night-2026-10-16.md § 7): Add a deck photo leads the screen.
  const signedInSeat = !!userId && !!accountSeat;
  const doneWhy = useMemo(() => {
    if (!bundle || !accountSeat) return null;
    return deckPhotoDone({ status: bundle.event.status, rounds: bundle.event.numberOfRounds, topCut: bundle.event.topCut ?? 0 },
      { status: accountSeat.status, droppedInRound: accountSeat.droppedInRound }, promptRounds(bundle.rounds, accountSeat.id));
  }, [bundle, accountSeat]);
  useEffect(() => {
    if (!doneWhy || !eventId || !accountSeat || !signedInSeat || !onOpenPhotos) return;
    let live = true;
    loadDeckPhotos(eventId)
      .then((p) => p.photos.filter((x) => x.participantId === accountSeat.id).length, () => 0)
      .then((n) => {
        if (!live) return;
        if (n === 0) capture("deck_photo_prompt_shown", { why: doneWhy });
        setMyPhotos(n);
      });
    return () => { live = false; };
  }, [doneWhy, eventId, accountSeat, signedInSeat, onOpenPhotos]);
  const openProfile = useOpenProfile("opponent");
  const formatName = bundle?.event.formatName ?? "draft";
  const isTeam = !!bundle?.event.teamSize && isTeamFormat(formatName);
  const isDraft = !!bundle && isDraftFormat(formatName);
  const teamsState = useEventTeams(eventId, isTeam, participantsKey(bundle?.participants));
  const beforeRoundOne = !!bundle && bundle.rounds.length === 0;
  const { seating: pods } = useSeating(eventId, isDraft && beforeRoundOne, bundle?.participants, teamsState.teams);
  const teamNames = useMemo(
    () => new Map((teamsState.teams ?? []).map((t) => [t.id, t.name])),
    [teamsState.teams],
  );
  const { mode, setMode } = useTrackerMode();

  async function handleJoin() {
    if (!code && !bundle) return;
    setJoining(true);
    setJoinError(null);
    try {
      const joinCode = code ?? bundle!.event.shortCode;
      const result = await joinEvent(joinCode, name);
      const local = {
        eventId: result.event_id,
        shortCode: result.short_code,
        participantId: result.participant_id,
        token: result.token,
        displayName: name.trim(),
      };
      saveLocalParticipant(local);
      setMe(local);
      setEventId(result.event_id);
      await refetch();
    } catch (e) {
      setJoinError(errorMessage(e));
    } finally {
      setJoining(false);
    }
  }

  if (resolving) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Finding event…</div>
      </Screen>
    );
  }

  // Not seated here: the join form. A signed-in visitor waits for the bundle only while it can still find their seat;
  // when event_bundle turns them away, they aren't in the event yet.
  if (!viewer && !(userId && !bundle && !bundleError)) {
    const facts = preview
      ? [preview.formatLabel, preview.venueName, preview.organizerName && `Run by ${preview.organizerName}`,
         `${preview.players}${preview.capacity ? `/${preview.capacity}` : ""} players`].filter(Boolean).join(" · ")
      : null;
    return (
      <Screen>
        <Bar title={preview?.name ?? bundle?.event.name ?? "Join event"} subtitle={code ? code.toUpperCase() : undefined} onBack={onBack} />
        {facts && <Notice tone="info">{facts}</Notice>}
        <Notice tone="info">Enter the name your opponents will see at the table.</Notice>
        <Notice tone="info">{JOIN_NOTICE}</Notice>
        <PublicResultsNotice about={about} shown />
        <Field label="Your name" value={name} onChange={setName} autoFocus placeholder="e.g. John L" />
        {joinError && <Notice tone="error">{joinError}</Notice>}
        <div className="flex-1" />
        <BigAction
          label="Join event"
          tone="accent"
          busy={joining}
          disabled={name.trim().length === 0}
          onClick={handleJoin}
        />
      </Screen>
    );
  }

  if (!bundle) {
    return (
      <Screen>
        {bundleError && <Bar title="Could not load event" onBack={onBack} />}
        {bundleError && <Notice tone="error">{bundleError}</Notice>}
        {bundleError && <GhostAction label="Try again" onClick={() => void refetch()} />}
        {!bundleError && <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>}
      </Screen>
    );
  }

  const { event, rounds } = bundle;
  const activeRound = rounds.find((r) => r.status === "active") ?? null;
  if (!viewer) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }
  const myMatch = activeRound?.matches.find((m) =>
    m.sides.some((s) => s.participantId === viewer.participantId),
  );
  const mySide = myMatch?.sides.find((s) => s.participantId === viewer.participantId);
  const theirSide = myMatch?.sides.find((s) => s.participantId !== viewer.participantId);
  const opponentReported =
    !!myMatch &&
    myMatch.status === "reported" &&
    !!userId &&
    !!myMatch.reportedByUser &&
    myMatch.reportedByUser !== userId;
  const opponentName = theirSide?.participantId
    ? participants.get(theirSide.participantId)?.displayName
    : null;
  const reported = myMatch?.status !== "pending";

  async function report(myWins: number, theirWins: number) {
    if (!myMatch || !mySide) return;
    const side0 = mySide.side === 0 ? myWins : theirWins;
    const side1 = mySide.side === 0 ? theirWins : myWins;
    setNotice(null);
    try {
      if (viewer!.token) {
        await reportResultAsPlayer(myMatch.id, viewer!.token, side0, side1, 0);
      } else {
        const outcome = await reportMatch(myMatch, side0, side1, 0);
        if (outcome.conflict) {
          setNotice(
            "Your opponent reported a different score. The first result stands until the organizer decides.",
          );
        }
      }
      await refetch();
    } catch (e) {
      setJoinError(errorMessage(e));
    }
  }

  async function respond(accept: boolean) {
    if (!myMatch) return;
    try {
      await respondToResult(myMatch.id, accept);
      if (!accept) setNotice("Disputed. The organizer has been notified.");
      await refetch();
    } catch (e) {
      setJoinError(errorMessage(e));
    }
  }

  const me_ = participants.get(viewer.participantId);
  const myTeam = me_?.teamId ? teamNames.get(me_.teamId) : null;
  const where = myTeam
    ? `${teamTitle(myTeam)} · seat ${slotLetter(me_?.teamSlot)}`
    : `Seat ${me_?.seat ?? "–"}`;
  // The shared tracker needs an account on both ends; guests keep score elsewhere.
  const signedInPlayer = !!userId && !viewer.token;
  const canTrack =
    signedInPlayer && !!onOpenLife && !!myMatch && !myMatch.isBye && !!theirSide?.participantId && event.status === "in_progress";
  const trackerFirst = canTrack && mode === "tracker" && myMatch?.status !== "confirmed";

  // Quarterfinals, semifinals and the final can't end in a draw.
  const playoff = (activeRound?.stage ?? "swiss") !== "swiss";
  const options: [string, number, number][] = ([
    ["Won 2–0", 2, 0],
    ["Won 2–1", 2, 1],
    ["Draw 1–1", 1, 1],
    ["Lost 1–2", 1, 2],
    ["Lost 0–2", 0, 2],
  ] as [string, number, number][]).filter(([, a, b]) => !(playoff && a === b));
  const beforeRound1 = (event.status === "setup" || event.status === "seated") && rounds.length === 0;
  const myList = decklistOf(bundle, viewer.participantId);

  const isRoto = formatName === "roto";
  const finished = event.status === "completed" || event.status === "archived";
  // Seating and standings: below your match on a phone, the right column on a desktop.
  const tables = (
    <>
      {isDraft && beforeRoundOne && pods && pods.length > 0 && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Draft seating</div>
          <SeatingPanel
            pods={pods}
            formatName={formatName}
            participants={bundle.participants}
            teams={teamsState.teams}
            highlightParticipantId={viewer.participantId}
            seatEnds={bundle.event.seatEnds}
          />
        </>
      )}

      {isTeam && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Team standings</div>
          <TeamStandingsTable
            teams={toTeams(teamsState.teams ?? [])}
            participants={bundle.participants}
            rounds={rounds}
            highlightParticipantId={viewer.participantId}
          />
        </>
      )}
      {!isTeam && <Bracket participants={bundle.participants} rounds={rounds} />}
      {!rounds.some((r) => (r.stage ?? "swiss") !== "swiss") && <div className="bg-t1-surface px-4 py-2 t1-label">Standings</div>}
      <StandingsTable
        participants={bundle.participants}
        rounds={rounds}
        highlightParticipantId={viewer.participantId}
        compact
        teamNames={isTeam ? teamNames : undefined}
        pods={bundle.event.formatName === "draft" ? bundle.pods : undefined}
      />
    </>
  );
  const screen = (
    <Screen width="wide">
      <Bar
        title={event.name}
        subtitle={`${viewer.displayName} · ${where} · ${event.formatLabel} · ${
          activeRound ? roundName(activeRound.stage, activeRound.number, event.numberOfRounds)
            : beforeRound1 ? when(event.startsAt) ?? "Before round 1" : `Round ${event.currentRound} of ${event.numberOfRounds}`}`}
        onBack={onBack}
      />
      <EventAboutRows about={about} eventName={event.name} />
      {/* Desktop: your match on the left, seating and standings on the right; a phone stacks them. */}
      <Columns at="xl" asideWidth={480} aside={tables}>
        {doneWhy && myPhotos != null && onOpenPhotos && (deckPhotoPrompt(doneWhy, myPhotos) === "add" ? (
          <div className="flex flex-col gap-px">
            <div className="bg-t1-surface px-4 py-2.5 t1-label text-center text-t1-accent">{deckPhotoWhyLabel(doneWhy)}</div>
            <BigAction label="Add a deck photo" tone="accent" onClick={() => {
              capture("deck_photo_prompt_tapped", { why: doneWhy });
              onOpenPhotos(event.id, true);
            }} />
          </div>
        ) : (
          <Row title="Deck photo" detail={myPhotos === 1 ? "Added" : `Added · ${myPhotos} photos`} value="View"
               onClick={() => onOpenPhotos(event.id)} />
        ))}
        {event.status === "cancelled" && (
          <Notice tone="error">
            Cancelled by the organizer{event.cancelReason ? `: ${event.cancelReason}` : ""}. Confirmed results still count.
          </Notice>
        )}

        {activeRound && event.showClock && (
          <>
            <div className="bg-t1-bg py-4">
              <ClockFace round={activeRound} />
            </div>
            <TimerProgress round={activeRound} />
          </>
        )}

        {myMatch ? (
          myMatch.isBye ? (
            <div className="bg-t1-accent text-t1-ink px-4 py-6 text-center text-[15px] tracking-[1px] uppercase">
              You have the bye this round
            </div>
          ) : (
            <>
              <PersonBlock open={openProfile(theirSide?.participantId ? participants.get(theirSide.participantId)?.userId : null)}>
                <p className="t1-label">Table {myMatch.tableNumber} · playing</p>
                <p className="text-[22px] tracking-[1px]">{opponentName ?? "—"}</p>
              </PersonBlock>
              {trackerFirst && <BigAction label="Open life tracker" tone="accent" onClick={() => onOpenLife!(myMatch.id)} />}
              {opponentReported && (
                <div className="flex flex-col gap-px">
                  <Notice tone="info">
                    {opponentName ?? "Your opponent"} reported {mySide?.gameWins}–{theirSide?.gameWins} for you.
                    {myMatch.disputed ? " Disputed — waiting on the organizer." : ""}
                  </Notice>
                  {!myMatch.disputed && (
                    <div className="flex gap-px">
                      <button
                        onClick={() => respond(false)}
                        className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 text-[12px] uppercase tracking-[1px]"
                      >
                        Dispute
                      </button>
                      <button
                        onClick={() => respond(true)}
                        className="flex-1 bg-t1-accent text-t1-ink px-4 py-4 text-[12px] uppercase tracking-[1px]"
                      >
                        Confirm
                      </button>
                    </div>
                  )}
                </div>
              )}
              {myMatch.status === "confirmed" && (
                <Notice tone="info">Result confirmed. The organizer can still correct it.</Notice>
              )}
              {event.allowPlayerReporting && myMatch.status !== "confirmed" && !opponentReported ? (
                <div className="flex flex-col gap-px">
                  {options.map(([label, mine, theirs]) => {
                    const selected =
                      reported &&
                      mySide?.gameWins === mine &&
                      theirSide?.gameWins === theirs;
                    return (
                      <button
                        key={label}
                        onClick={() => report(mine, theirs)}
                        className={`px-4 py-4 text-[14px] tracking-[1px] uppercase ${
                          selected
                            ? "bg-t1-accent text-t1-ink"
                            : "bg-t1-surface hover:bg-t1-surface-hover"
                        }`}
                      >
                        {label}
                      </button>
                    );
                  })}
                  {reported && (
                    <Notice tone="info">
                      Reported. Tap a different result to correct it before the round is recorded.
                    </Notice>
                  )}
                </div>
              ) : !event.allowPlayerReporting ? (
                <Notice tone="info">The organizer is recording results for this event.</Notice>
              ) : null}
              {canTrack && !trackerFirst && (
                <div className="flex gap-px">
                  <GhostAction label="Open life tracker" onClick={() => onOpenLife!(myMatch.id)} />
                </div>
              )}
            </>
          )
        ) : (
          <Notice tone="info">
            {activeRound ? "You are not paired this round." : "Waiting for the next round to be paired."}
          </Notice>
        )}

        {notice && <Notice tone="info">{notice}</Notice>}
        {joinError && <Notice tone="error">{joinError}</Notice>}

        {signedInPlayer && event.decklists !== "off" && (
          <Row
            title="Decklist"
            detail={myList ? countsText(myList.mainCount, myList.sideCount) + (myList.listName ? ` · from ${myList.listName}` : "")
              : event.decklists === "required" ? "Required · add it before round 1" : "Add your decklist"}
            value={myList ? "Change" : "Add"}
            accentValue
            onClick={() => setListOpen(true)}
          />
        )}
        {beforeRound1 && when(event.startsAt) && (
          <Row title="Starts" detail={[when(event.startsAt), event.venueName].filter(Boolean).join(" · ")} />
        )}
        {signedInPlayer && beforeRound1 && (
          <div className="flex gap-px">
            <GhostAction label="Leave event" onClick={() => { setLeaveError(null); setConfirmLeave(true); }} />
          </div>
        )}

        {signedInPlayer && ["setup", "seated", "in_progress"].includes(event.status) && <GetTheApp eventId={event.id} />}

        {isRoto && rounds.length > 0 && (
          <div className="flex gap-px">
            <GhostAction label="Draft picks" onClick={() => setRotoPanel("draft")} />
            {event.pairing === "round_robin" && <GhostAction label="Schedule" onClick={() => setRotoPanel("schedule")} />}
          </div>
        )}

        {/* Deck photos need an account (the photo is tied to your seat); during the event your own, after it everyone's. */}
        {signedInPlayer && onOpenPhotos && event.status !== "cancelled" && (
          <div className="flex gap-px">
            {(finished || !doneWhy) && <GhostAction label={finished ? "Deck photos" : "Deck photo"} onClick={() => onOpenPhotos(event.id)} />}
            {onOpenRedraft && canRedraft(event) && <GhostAction label="Redraft" onClick={() => onOpenRedraft(event.id, event.setCode)} />}
          </div>
        )}

        {signedInPlayer && (
          <SwitchRow
            label="Use life tracker"
            detail={mode === "tracker" ? "Your matches open in the life tracker" : "Keep score elsewhere; report results here"}
            on={mode === "tracker"}
            onChange={(on) => setMode(on ? "tracker" : "elsewhere")}
          />
        )}
      </Columns>
      {listOpen && (
        <DecklistPanel event={event} participantId={viewer.participantId} playerName={viewer.displayName} byOrganizer={false}
                       onClose={(changed) => { setListOpen(false); if (changed) void refetch(); }} />
      )}
      {confirmLeave && (
        <Dialog
          title={`Leave ${event.name}?`}
          message="Your seat goes to the next person on the waitlist, if there is one."
          cancelLabel="Stay"
          confirmLabel="Leave"
          tone="danger"
          error={leaveError}
          onCancel={() => setConfirmLeave(false)}
          onConfirm={() => void leaveEvent(event.id, false).then(() => { setConfirmLeave(false); onBack?.(); }, (e) => setLeaveError(errorMessage(e)))}
        />
      )}
      {rotoPanel === "draft" && (
        <RotoDraftOverlay eventId={event.id} title={event.name} isOrganizer={false} pairing={event.pairing} onClose={() => setRotoPanel(null)} />
      )}
      {rotoPanel === "schedule" && (
        <div className="fixed inset-0 z-40 bg-t1-bg overflow-y-auto flex flex-col gap-px">
          <Bar title="Schedule" subtitle={event.name} onBack={() => setRotoPanel(null)} />
          <RotoSchedule bundle={bundle} meId={viewer.participantId} />
        </div>
      )}
      {stale && <Notice tone="info">{stale}</Notice>}
    </Screen>
  );
  // Roto: the Draft phase sits between joining and round 1.
  if (isRoto && rounds.length === 0 && event.status !== "cancelled" && event.status !== "completed") {
    return <RotoDraftGate eventId={event.id} title={event.name} isOrganizer={false}>{screen}</RotoDraftGate>;
  }
  return screen;
}

/** The opponent at the top: their profile on a tap when they have an account. */
function PersonBlock({ open, children }: { open?: () => void; children: ReactNode }) {
  const cls = "bg-t1-surface px-4 py-5 flex flex-col gap-1 items-center";
  if (!open) return <div className={cls}>{children}</div>;
  return <button type="button" onClick={open} className={`${cls} hover:bg-t1-surface-hover w-full`}>{children}</button>;
}
