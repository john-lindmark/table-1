import { useMemo, useState } from "react";
import { useEvent } from "../lib/useEvent";
import { cancelEvent, errorMessage } from "../lib/api";
import { isDraftFormat, isTeamFormat } from "../lib/formats";
import {
  TAB_LABELS,
  activeRoundOf,
  derivePhase,
  liveSubtitle,
  phaseTabs,
  resolveTab,
  resultsSubtitle,
  setupSubtitle,
  type OrganizerTab,
  type Phase,
} from "../lib/organizer";
import { participantsKey, useEventTeams } from "../lib/useEventExtras";
import type { Match } from "../lib/types";
import { Bar, Dialog, GhostAction, Notice, Screen, TabBar, useNow } from "../components/kit";
import { SetupView } from "./organizer/SetupView";
import { LiveView } from "./organizer/LiveView";
import { ResultsView } from "./organizer/ResultsView";
import { ResultPanel } from "./organizer/ResultPanel";
import type { PhaseViewProps } from "./organizer/shared";

/**
 * The organizer's event screen. One of three views, derived from the event's state (never stored):
 * Setup (no rounds yet) → Live → Results (completed / archived / cancelled). Realtime refetches the
 * bundle, so the view switches by itself; a phase change resets the tab to that phase's first tab.
 */
export function Organizer({
  eventId,
  onExit,
  onAddPlayers,
  onOpenLife,
}: {
  eventId: string;
  onExit: () => void;
  onAddPlayers: () => void;
  /** Watch a match's shared life tracker (read-only for organizers). */
  onOpenLife?: (matchId: string) => void;
}) {
  const { bundle, error, sync, mutate, refetch } = useEvent(eventId);
  const [selected, setSelected] = useState<{ phase: Phase; tab: OrganizerTab } | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [cancelling, setCancelling] = useState<string | null>(null);
  const [cancelBusy, setCancelBusy] = useState(false);
  const [cancelError, setCancelError] = useState<string | null>(null);
  const [openMatchId, setOpenMatchId] = useState<string | null>(null);

  const formatName = bundle?.event.formatName ?? "draft";
  const isTeam = !!bundle && isTeamFormat(formatName) && !!bundle.event.teamSize;
  const isDraft = isDraftFormat(formatName);
  const teamsState = useEventTeams(eventId, isTeam, participantsKey(bundle?.participants));
  const teamNames = useMemo(() => new Map((teamsState.teams ?? []).map((t) => [t.id, t.name])), [teamsState.teams]);

  const phase: Phase | null = bundle ? derivePhase(bundle.event.status, bundle.rounds.length) : null;
  const activeRound = bundle ? activeRoundOf(bundle.rounds) : null;
  // The Live subtitle shows the clock, so it ticks every second while the round runs.
  const now = useNow(phase === "live" && activeRound?.timerStatus === "running", 1000);

  if (error && !bundle) {
    return (
      <Screen>
        <Bar title="Could not load event" />
        <Notice tone="error">{error}</Notice>
        <GhostAction label="Retry" onClick={refetch} />
      </Screen>
    );
  }
  if (!bundle || !phase) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading event…</div>
      </Screen>
    );
  }

  const { event, participants, rounds } = bundle;
  const tabs = phaseTabs(phase, { isTeam, isDraft });
  const tab = resolveTab(selected, phase, tabs);
  const activePlayers = participants.filter((p) => p.status === "active").length;
  const subtitle =
    phase === "setup"
      ? setupSubtitle(event, activePlayers)
      : phase === "live"
        ? liveSubtitle(event, rounds, now)
        : resultsSubtitle(event, rounds, participants.length);
  const openMatch: Match | null =
    (openMatchId && rounds.flatMap((r) => r.matches).find((m) => m.id === openMatchId)) || null;

  async function handleCancel() {
    setCancelBusy(true);
    setCancelError(null);
    try {
      await cancelEvent(eventId, cancelling ?? "");
      setCancelling(null);
      await refetch();
    } catch (e) {
      setCancelError(errorMessage(e));
    } finally {
      setCancelBusy(false);
    }
  }

  const viewProps: PhaseViewProps = {
    eventId,
    bundle,
    tab,
    isTeam,
    isDraft,
    teams: teamsState.teams,
    teamNames,
    refetch,
    onOpenMatch: (m) => setOpenMatchId(m.id),
    setActionError,
  };

  return (
    <Screen>
      <Bar
        title={event.name}
        subtitle={subtitle}
        right={
          <div className="flex gap-4 shrink-0">
            {phase !== "results" && (
              <button
                type="button"
                onClick={() => {
                  setCancelError(null);
                  setCancelling("");
                }}
                className="t1-label hover:text-t1-text"
              >
                Cancel event
              </button>
            )}
            <button type="button" onClick={onExit} className="t1-label hover:text-t1-text">
              Events
            </button>
          </div>
        }
      />

      <TabBar
        tabs={tabs}
        value={tab}
        onChange={(t) => {
          setActionError(null);
          setSelected({ phase, tab: t });
        }}
        labels={TAB_LABELS}
      />

      {sync === "error" && <Notice tone="error">{error ?? "Something failed to save."}</Notice>}
      {actionError && <Notice tone="error">{actionError}</Notice>}

      {phase === "setup" && (
        <SetupView
          key="setup"
          {...viewProps}
          onAddPlayers={onAddPlayers}
          onTeamsSaved={(rows) => {
            teamsState.setTeams(rows);
            void refetch();
          }}
        />
      )}
      {phase === "live" && <LiveView key="live" {...viewProps} mutate={mutate} />}
      {phase === "results" && <ResultsView key="results" {...viewProps} />}

      {openMatch && (
        <ResultPanel
          key={openMatch.id}
          match={openMatch}
          participants={participants}
          correcting={phase === "results"}
          onClose={() => setOpenMatchId(null)}
          onSaved={() => void refetch()}
          onOpenLife={onOpenLife}
        />
      )}

      {cancelling !== null && (
        <Dialog
          title="Cancel this event?"
          message="Everyone in it is told it's off and their Live Activity ends. Results already confirmed stay on players' records; unreported matches don't count. This can't be undone."
          cancelLabel="Keep event"
          confirmLabel="Cancel event"
          busyLabel="Cancelling…"
          tone="danger"
          busy={cancelBusy}
          error={cancelError}
          onCancel={() => setCancelling(null)}
          onConfirm={handleCancel}
        >
          <input
            value={cancelling}
            maxLength={200}
            onChange={(e) => setCancelling(e.target.value)}
            placeholder="Reason (optional)"
            className="bg-t1-surface px-3 py-3 outline-0 border-0 text-[14px] placeholder:text-t1-muted/60"
          />
        </Dialog>
      )}
    </Screen>
  );
}
