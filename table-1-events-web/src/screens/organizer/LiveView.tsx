import { useState } from "react";
import { errorMessage, finishEvent, pairNextRound, setParticipantStatus, setRoundClock } from "../../lib/api";
import type { ClockAction, EventBundle } from "../../lib/api";
import { slotLetter } from "../../lib/formats";
import {
  activeRoundOf,
  applyClock,
  clinchText,
  formatMmSs,
  groupMatches,
  lastRoundNumber,
  liveAction,
  matchDetail,
  matchTitle,
  matchValue,
  nameLookup,
  openMatchCount,
  remainingSeconds,
  roundCaption,
} from "../../lib/organizer";
import type { Match, Participant, RoundWithMatches } from "../../lib/types";
import { BigAction, BigNumber, Columns, Dialog, GhostAction, Notice, Row, Section, useNow } from "../../components/kit";
import { useDesktop } from "../../lib/desktop";
import { TeamsPanel } from "../../components/TeamsPanel";
import { teamClinch } from "../../lib/teams";
import { capture } from "../../lib/telemetry";
import { toTeams } from "../../lib/useEventExtras";
import { RoundsList, StandingsBlock, type PhaseViewProps } from "./shared";
import { repairLabel, repairPrompt } from "../../lib/repairRound";
import { RotoSchedule } from "../roto/lazy";
import { useSession } from "../../lib/useSession";
import { Avatar } from "../../components/Avatar";

const ADD_SECONDS = 300;

/** Live: Round | Standings | Players (+ Teams, read-only). Big action: waiting → pair next → finish. */
export function LiveView(
  props: PhaseViewProps & {
    mutate: (optimistic: (prev: EventBundle) => EventBundle, call: () => Promise<unknown>) => Promise<void>;
    /** Opens the re-pair confirm for the current round (contract/repair-round-2026-11-09.md). */
    onRepair: () => void;
  },
) {
  const { eventId, bundle, tab, isTeam, teams, refetch, onOpenMatch, setActionError, mutate, onRepair } = props;
  const { event, rounds, participants } = bundle;
  const active = activeRoundOf(rounds);
  const currentRound = active?.number ?? lastRoundNumber(rounds);
  // Team events: once one team can't be caught, the organizer may finish without the rest of the matches.
  const clinch = isTeam && teams ? teamClinch(toTeams(teams), participants, rounds, event.numberOfRounds) : null;
  const action = liveAction(event, rounds, clinch);
  const nameOf = nameLookup(participants);
  const { userId } = useSession();
  const desktop = useDesktop();
  const meId = (userId && participants.find((p) => p.userId === userId)?.id) || null;
  // An earlier result was corrected after this round was paired: offer to pair it again.
  const prompt = repairPrompt(rounds);

  const [busy, setBusy] = useState(false);
  const [confirmFinish, setConfirmFinish] = useState(false);
  const [finishError, setFinishError] = useState<string | null>(null);
  const [dropping, setDropping] = useState<Participant | null>(null);
  const [dropError, setDropError] = useState<string | null>(null);
  const [dropBusy, setDropBusy] = useState(false);

  function clock(kind: ClockAction) {
    if (!active) return;
    setActionError(null);
    void mutate(
      (prev) => ({
        ...prev,
        rounds: prev.rounds.map((r) => (r.id === active.id ? applyClock(r, kind, ADD_SECONDS, Date.now()) : r)),
      }),
      () => setRoundClock(active.id, kind, ADD_SECONDS),
    );
  }

  async function pairNext() {
    setBusy(true);
    setActionError(null);
    try {
      await pairNextRound(eventId, event.pairing);
      await refetch();
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function finish() {
    setBusy(true);
    setFinishError(null);
    try {
      await finishEvent(eventId, active?.id ?? null);
      if (action.kind === "finish" && action.clinch) capture("event_finished_clinched", { remaining: action.clinch.remaining });
      setConfirmFinish(false);
      await refetch();
    } catch (e) {
      setFinishError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function setStatus(p: Participant, status: "active" | "dropped") {
    setDropBusy(true);
    setDropError(null);
    try {
      await setParticipantStatus(p.id, status, status === "dropped" ? currentRound || null : null);
      setDropping(null);
      await refetch();
    } catch (e) {
      if (status === "dropped") setDropError(errorMessage(e));
      else setActionError(errorMessage(e));
    } finally {
      setDropBusy(false);
    }
  }

  const playing = participants.filter((p) => p.status === "active");
  const dropped = participants.filter((p) => p.status === "dropped");
  const open = openMatchCount(active);
  const teamTag = (p: Participant) =>
    isTeam && p.teamId ? `${props.teamNames.get(p.teamId) ?? "Team"} · ${slotLetter(p.teamSlot)}` : undefined;

  return (
    <>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {tab === "round" && (
          // Desktop: live standings beside the round, so the organizer needn't switch tabs.
          <Columns at="xl" asideWidth={440} aside={desktop ? (
            <>
              <Section title="Standings" right={open > 0 ? `${open} open` : undefined} />
              <StandingsBlock bundle={bundle} isTeam={isTeam} teams={teams} teamNames={props.teamNames} />
            </>
          ) : undefined}>
            {prompt && active && (
              <div className="flex flex-col gap-px">
                <Notice tone="info">{prompt.text}</Notice>
                <GhostAction label={`Re-pair ${repairLabel(active.stage, active.number)}`} onClick={onRepair} />
              </div>
            )}
            {action.kind === "finish" && action.clinch && (
              <Notice tone="info">{clinchText(action.clinch)} You can finish now; open matches won't count.</Notice>
            )}
            {active ? (
              <>
                {event.showClock ? (
                  <RoundClock round={active} caption={roundCaption(event, active)} onClock={clock} />
                ) : (
                  // Round timer off: no clock anywhere for this event (rounds still run 50 minutes).
                  <Notice tone="info">{roundCaption(event, active)}</Notice>
                )}
                <MatchList round={active} nameOf={nameOf} onOpenMatch={onOpenMatch} />
              </>
            ) : (
              <Notice tone="info">
                {currentRound >= event.numberOfRounds
                  ? `All ${event.numberOfRounds} rounds are in. Finish the event to send final standings.`
                  : `Round ${currentRound} recorded. Pair round ${currentRound + 1} when the table is ready.`}
              </Notice>
            )}
          </Columns>
        )}

        {tab === "rounds" && (
          <>
            <RoundsList
              rounds={rounds.filter((r) => r.id !== active?.id)}
              participants={participants}
              numberOfRounds={event.numberOfRounds}
              onOpenMatch={onOpenMatch}
            />
            <Notice tone="info">
              {active
                ? `Tap a match to correct its result. If that changes who should have played whom, re-pair ${repairLabel(active.stage, active.number)}.`
                : "Tap a match to correct its result. Standings and records update."}
            </Notice>
          </>
        )}

        {tab === "schedule" && <RotoSchedule bundle={bundle} meId={meId} />}

        {tab === "standings" && (
          <>
            {open > 0 && (
              <Notice tone="info">
                Live: updates as results come in. {open} match{open === 1 ? "" : "es"} still open.
              </Notice>
            )}
            <StandingsBlock bundle={bundle} isTeam={isTeam} teams={teams} teamNames={props.teamNames} />
          </>
        )}

        {tab === "players" && (
          <>
            <Section title="Playing" count={playing.length} />
            {playing.map((p) => (
              <Row
                key={p.id}
                title={p.displayName}
                detail={teamTag(p)}
                avatar={<Avatar name={p.displayName} userId={p.userId} opens="event_players" />}
                action={{
                  label: "Drop",
                  onClick: () => {
                    setDropError(null);
                    setDropping(p);
                  },
                }}
              />
            ))}
            <Section title="Dropped" count={dropped.length} />
            {dropped.map((p) => (
              <Row
                key={p.id}
                title={p.displayName}
                avatar={<Avatar name={p.displayName} userId={p.userId} opens="event_players" />}
                detail={`Dropped after round ${p.droppedInRound ?? currentRound} · still counts in tiebreakers`}
                action={{ label: "Reinstate", onClick: () => void setStatus(p, "active"), disabled: dropBusy }}
                dim
              />
            ))}
          </>
        )}

        {tab === "teams" && isTeam && (
          <TeamsPanel
            eventId={eventId}
            formatName={event.formatName}
            teamSize={event.teamSize ?? 3}
            participants={participants}
            teams={teams}
            locked
            onSaved={() => void refetch()}
          />
        )}
      </div>

      {action.kind === "finish" && action.pairRound && (
        <div className="flex gap-px">
          <GhostAction label={`Play on · pair round ${action.pairRound}`} disabled={busy} onClick={() => void pairNext()} />
        </div>
      )}
      <BigAction
        label={action.label}
        busy={busy}
        disabled={action.kind === "waiting"}
        onClick={() => {
          if (action.kind === "pair") void pairNext();
          else if (action.kind === "finish") {
            setFinishError(null);
            setConfirmFinish(true);
          }
        }}
      />

      {confirmFinish && (
        <Dialog
          title={`Finish ${event.name}?`}
          message={action.kind === "finish" && action.clinch
            ? `${clinchText(action.clinch)} Open matches won't count. Final standings go to every player and the event moves to Past.`
            : "Final standings go to every player and the event moves to Past. You can still correct a result afterwards."}
          cancelLabel="Not yet"
          confirmLabel="Finish"
          busyLabel="Finishing…"
          busy={busy}
          error={finishError}
          onCancel={() => setConfirmFinish(false)}
          onConfirm={finish}
        />
      )}

      {dropping && (
        <Dialog
          title={`Drop ${dropping.displayName}?`}
          message="They won't be paired again. Their results so far still count."
          cancelLabel="Keep"
          confirmLabel="Drop"
          busyLabel="Dropping…"
          tone="danger"
          busy={dropBusy}
          error={dropError}
          onCancel={() => setDropping(null)}
          onConfirm={() => void setStatus(dropping, "dropped")}
        />
      )}
    </>
  );
}

/** Big clock that ticks every second (paused: what's left), caption, Pause/Resume and +5 min. */
function RoundClock({
  round,
  caption,
  onClock,
}: {
  round: RoundWithMatches;
  caption: string;
  onClock: (action: ClockAction) => void;
}) {
  const running = round.timerStatus === "running";
  const now = useNow(running, 1000);
  const left = remainingSeconds(round, now);
  const tone = !running ? "muted" : left <= 0 ? "danger" : left <= 300 ? "warning" : "normal";
  return (
    <div className="shrink-0 flex flex-col gap-px">
      <div className="bg-t1-bg py-6 flex flex-col items-center gap-3">
        <BigNumber tone={tone}>{formatMmSs(left)}</BigNumber>
        <p className="t1-label text-center px-4">{caption}</p>
      </div>
      <div className="flex gap-px">
        <GhostAction label={running ? "Pause clock" : "Resume clock"} onClick={() => onClock(running ? "pause" : "resume")} />
        <GhostAction label="+5 min" onClick={() => onClock("add")} />
      </div>
    </div>
  );
}

/** Disputed · n, Waiting · n, Results in · n. Tapping a non-bye match opens the set-result panel. */
function MatchList({
  round,
  nameOf,
  onOpenMatch,
}: {
  round: RoundWithMatches;
  nameOf: (id: string | null | undefined) => string;
  onOpenMatch: (m: Match) => void;
}) {
  const groups = groupMatches(round.matches);
  const sections: [string, Match[]][] = [
    ["Disputed", groups.disputed],
    ["Waiting", groups.waiting],
    ["Results in", groups.results],
  ];
  return (
    <>
      {sections.map(([title, list]) =>
        list.length === 0 ? null : (
          <div key={title} className="flex flex-col gap-px">
            <Section title={title} count={list.length} />
            {list.map((m) => (
              <Row
                key={m.id}
                title={matchTitle(m, nameOf)}
                detail={matchDetail(m, nameOf) || undefined}
                value={matchValue(m)}
                onClick={m.isBye ? undefined : () => onOpenMatch(m)}
              />
            ))}
          </div>
        ),
      )}
    </>
  );
}
