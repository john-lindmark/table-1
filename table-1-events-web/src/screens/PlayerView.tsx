import { useMemo, useState } from "react";
import { useEvent } from "../lib/useEvent";
import { fetchEventIdByCode, joinEvent, reportResultAsPlayer } from "../lib/api";
import { getLocalParticipant, saveLocalParticipant } from "../lib/session";
import { StandingsTable } from "../components/StandingsTable";
import { Bar, BigAction, ClockFace, Field, Notice, Screen, TimerProgress } from "../components/kit";

/** What a player sees: their match, their result buttons, the standings. */
export function PlayerView({ code, eventIdProp }: { code?: string; eventIdProp?: string }) {
  const [eventId, setEventId] = useState<string | null>(eventIdProp ?? null);
  const [resolving, setResolving] = useState(!eventIdProp && !!code);
  const [name, setName] = useState("");
  const [joining, setJoining] = useState(false);
  const [joinError, setJoinError] = useState<string | null>(null);
  const [me, setMe] = useState(() => (eventIdProp ? getLocalParticipant(eventIdProp) : null));

  // Resolve a short code to an event id once.
  useMemo(() => {
    if (eventId || !code) return;
    fetchEventIdByCode(code)
      .then((id) => {
        setEventId(id);
        if (id) setMe(getLocalParticipant(id));
        if (!id) setJoinError("No event found with that code.");
      })
      .catch((e) => setJoinError(e instanceof Error ? e.message : String(e)))
      .finally(() => setResolving(false));
  }, [code, eventId]);

  const { bundle, refetch } = useEvent(eventId);

  const participants = useMemo(
    () => new Map((bundle?.participants ?? []).map((p) => [p.id, p])),
    [bundle],
  );

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
      setJoinError(e instanceof Error ? e.message : String(e));
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

  if (!me) {
    return (
      <Screen>
        <Bar title={bundle?.event.name ?? "Join event"} subtitle={code ? code.toUpperCase() : undefined} />
        <Notice tone="info">Enter the name your opponents will see at the table.</Notice>
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
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }

  const { event, rounds } = bundle;
  const activeRound = rounds.find((r) => r.status === "active") ?? null;
  const myMatch = activeRound?.matches.find((m) =>
    m.sides.some((s) => s.participantId === me.participantId),
  );
  const mySide = myMatch?.sides.find((s) => s.participantId === me.participantId);
  const theirSide = myMatch?.sides.find((s) => s.participantId !== me.participantId);
  const opponentName = theirSide?.participantId
    ? participants.get(theirSide.participantId)?.displayName
    : null;
  const reported = myMatch?.status !== "pending";

  async function report(myWins: number, theirWins: number) {
    if (!myMatch || !mySide) return;
    const side0 = mySide.side === 0 ? myWins : theirWins;
    const side1 = mySide.side === 0 ? theirWins : myWins;
    try {
      await reportResultAsPlayer(myMatch.id, me!.token, side0, side1, 0);
      await refetch();
    } catch (e) {
      setJoinError(e instanceof Error ? e.message : String(e));
    }
  }

  const options: [string, number, number][] = [
    ["Won 2–0", 2, 0],
    ["Won 2–1", 2, 1],
    ["Draw 1–1", 1, 1],
    ["Lost 1–2", 1, 2],
    ["Lost 0–2", 0, 2],
  ];

  return (
    <Screen>
      <Bar
        title={event.name}
        subtitle={`${me.displayName} · Seat ${participants.get(me.participantId)?.seat ?? "–"} · Round ${activeRound?.number ?? event.currentRound} of ${event.numberOfRounds}`}
      />

      {activeRound && (
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
            <div className="bg-t1-surface px-4 py-5 flex flex-col gap-1 items-center">
              <p className="t1-label">Table {myMatch.tableNumber} · playing</p>
              <p className="text-[22px] tracking-[1px]">{opponentName ?? "—"}</p>
            </div>
            {event.allowPlayerReporting ? (
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
            ) : (
              <Notice tone="info">The organizer is recording results for this event.</Notice>
            )}
          </>
        )
      ) : (
        <Notice tone="info">
          {activeRound ? "You are not paired this round." : "Waiting for the next round to be paired."}
        </Notice>
      )}

      {joinError && <Notice tone="error">{joinError}</Notice>}

      <div className="bg-t1-surface px-4 py-2 t1-label">Standings</div>
      <StandingsTable
        participants={bundle.participants}
        rounds={rounds}
        highlightParticipantId={me.participantId}
        compact
      />
    </Screen>
  );
}
