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
import { BigAction, BigNumber, Columns, Dialog, GhostAction, Notice, PodHeader, Row, Section, useNow } from "../../components/kit";
import { playerSections, podRefs, type PodRef } from "../../lib/draftPods";
import { useDesktop } from "../../lib/desktop";
import { TeamsPanel } from "../../components/TeamsPanel";
import { activeTeams, teamClinch } from "../../lib/teams";
import { extensionText, seatLabel } from "../../lib/leagues";
import { JudgeCalls } from "../../components/RoomTools";
import { extraByMatch } from "../../lib/room";
import { roundName } from "../../lib/scheduledEvents";
import { PaymentMenu, payDetail, paymentsById } from "./Money";
import { unpaidHeader, type PlayerPayment } from "../../lib/money";
import { capture } from "../../lib/telemetry";
import { toTeams } from "../../lib/useEventExtras";
import { matchPodSections, podOfParticipants, RoundsList, StandingsBlock, type PhaseViewProps } from "./shared";
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
  const { eventId, bundle, tab, isTeam, teams, refetch, onOpenMatch, setActionError, mutate, onRepair, money = null, reloadMoney, room = null, reloadRoom } = props;
  const { event, rounds, participants } = bundle;
  const active = activeRoundOf(rounds);
  const currentRound = active?.number ?? lastRoundNumber(rounds);
  // Team events: once one team can't be caught, the organizer may finish without the rest of the matches.
  const clinch = isTeam && teams ? teamClinch(toTeams(teams), participants, rounds, event.numberOfRounds) : null;
  // The cut counts active players, or active teams in a team event (contract/teams-finals-alerts-2026-11-13.md § 1).
  const action = liveAction(event, rounds, clinch, participants.filter((p) => p.status === "active").length,
                            isTeam && teams ? activeTeams(toTeams(teams), participants).length : null);
  const stageName = active ? roundName(active.stage, active.number, event.numberOfRounds) : null;
  const extras = extraByMatch(room);
  const pays = paymentsById(money);
  const [payFor, setPayFor] = useState<PlayerPayment | null>(null);
  const unpaid = money?.fee && money.fee.amount_cents > 0 ? money.organizer?.unpaid ?? 0 : 0;
  const nameOf = nameLookup(participants);
  const pods = podRefs(event.formatName, bundle.pods);
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
    isTeam && p.teamId ? `${props.teamNames.get(p.teamId) ?? "Team"} · ${event.seatFormats ? seatLabel(p.teamSlot, event.seatFormats) : slotLetter(p.teamSlot)}` : undefined;

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
            <JudgeCalls eventId={eventId} calls={room?.calls} onChanged={() => reloadRoom?.()} />
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
                  <RoundClock round={active} caption={stageCaption(roundCaption(event, active), active, stageName)} onClock={clock} />
                ) : (
                  // Round timer off: no clock anywhere for this event (rounds still run 50 minutes).
                  <Notice tone="info">{stageCaption(roundCaption(event, active), active, stageName)}</Notice>
                )}
                <MatchList round={active} nameOf={nameOf} onOpenMatch={onOpenMatch} pods={pods} participants={participants}
                           extras={extras} seatFormats={isTeam ? event.seatFormats : null} />
              </>
            ) : (
              <Notice tone="info">
                {action.kind === "cut" ? `Swiss is in. ${action.label} to pair the playoff.`
                  : action.kind === "playoff" ? `${action.label} when the tables are ready.`
                  : currentRound >= event.numberOfRounds
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
              pods={pods}
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
            {(() => {
              const row = (p: Participant, seat?: number | null) => (
                <Row
                  key={p.id}
                  title={p.displayName}
                  detail={payDetail(pays.get(p.id), setPayFor, [seat != null ? `Seat ${seat}` : null, teamTag(p)].filter(Boolean).join(" · "))}
                  avatar={<Avatar name={p.displayName} userId={p.userId} opens="event_players" />}
                  action={{
                    label: "Drop",
                    onClick: () => {
                      setDropError(null);
                      setDropping(p);
                    },
                  }}
                />
              );
              const sections = playerSections(playing, pods, (p) => p.podId, (p) => p.seat);
              // Drafts with 2+ pods: each pod's players by seat, then anyone not seated yet.
              return sections ? sections.map((s) => (
                <div key={s.pod ?? s.title} className="flex flex-col gap-px">
                  <PodHeader title={s.title} right={playersCount(s.items.length)} />
                  {s.items.map((p) => row(p, s.pod ? p.seat : null))}
                </div>
              )) : (
                <>
                  <Section title="Playing" count={playing.length} right={unpaid > 0 ? <span className="text-t1-warning">{unpaidHeader(unpaid)}</span> : undefined} />
                  {playing.map((p) => row(p))}
                </>
              );
            })()}
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
          // The cut and each playoff stage are paired by the same call: the engine knows which stage is next.
          if (action.kind === "pair" || action.kind === "cut" || action.kind === "playoff") void pairNext();
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

      {payFor && money?.fee && (
        <PaymentMenu eventId={eventId} payment={payFor} amountCents={money.fee.amount_cents} onClose={() => setPayFor(null)} onChanged={() => reloadMoney?.()} />
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

const playersCount = (n: number) => `${n} player${n === 1 ? "" : "s"}`;

/** A playoff round's caption says its stage ("Semifinals · 1 of 2 results in"), not "Round 4 of 3". */
function stageCaption(caption: string, round: RoundWithMatches, stageName: string | null): string {
  if (!stageName || (round.stage ?? "swiss") === "swiss") return caption;
  return caption.replace(/Round \d+ of \d+/, stageName);
}

/** "2 of 4 in · 1 disputed", "All in" for a pod's matches (byes don't count). */
function podProgress(matches: Match[]): string {
  const g = groupMatches(matches);
  const played = g.disputed.length + g.waiting.length + g.results.filter((m) => !m.isBye).length;
  if (played === 0) return "Bye";
  const done = g.results.filter((m) => !m.isBye).length;
  const text = done === played ? "All in" : `${done} of ${played} in`;
  return g.disputed.length ? `${text} · ${g.disputed.length} disputed` : text;
}

/**
 * Disputed · n, Waiting · n, Results in · n. Drafts with 2+ pods: one block per pod (and Across pods) in table
 * order, disputes included. Tapping a non-bye match opens the set-result panel.
 */
function MatchList({
  round,
  nameOf,
  onOpenMatch,
  pods,
  participants,
  extras,
  seatFormats,
}: {
  /** Tables with extra time this round: match id → seconds (`+5:00` on the row). */
  extras?: Map<string, number>;
  /** Team events: the seat each match is played in (`A · MODERN` in Team Trios). */
  seatFormats?: string[] | null;
  round: RoundWithMatches;
  nameOf: (id: string | null | undefined) => string;
  onOpenMatch: (m: Match) => void;
  pods: PodRef[];
  participants: Participant[];
}) {
  const slotOf = new Map(participants.map((p) => [p.id, p.teamId ? p.teamSlot ?? null : null]));
  const row = (m: Match) => {
    const extra = extensionText(extras?.get(m.id) ?? m.extraSeconds ?? 0);
    const slot = slotOf.get(m.sides[0]?.participantId ?? "");
    const detail = [slot ? seatLabel(slot, seatFormats) : null, matchDetail(m, nameOf) || null].filter(Boolean).join(" · ");
    return (
      <Row
        key={m.id}
        title={matchTitle(m, nameOf)}
        detail={detail || undefined}
        value={extra ? <span className="flex items-center gap-3"><span className="text-t1-warning">{extra}</span><span>{matchValue(m)}</span></span> : matchValue(m)}
        onClick={m.isBye ? undefined : () => onOpenMatch(m)}
      />
    );
  };
  const byPod = matchPodSections(round.matches, pods, podOfParticipants(participants), round.stage);
  if (byPod) {
    return (
      <>
        {byPod.map((s) => (
          <div key={s.pod ?? s.title} className="flex flex-col gap-px">
            <PodHeader title={s.title} right={podProgress(s.items)} />
            {s.items.map(row)}
          </div>
        ))}
      </>
    );
  }
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
            {list.map(row)}
          </div>
        ),
      )}
    </>
  );
}
