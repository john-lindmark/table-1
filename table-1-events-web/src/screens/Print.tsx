import { useMemo, useRef } from "react";
import { Bar, BigAction, GhostAction, Notice, Screen } from "../components/kit";
import { playoffStandings } from "../lib/playoffs";
import { isPrintWhat, printHtml, printLabel, printRound, type PrintModel, type PrintWhat } from "../lib/printViews";
import { extraByMatch, useEventRoom } from "../lib/room";
import { printDate } from "../lib/sideboardGuide";
import { formatPct, recordLabel } from "../lib/standings";
import { computeTeamStandings } from "../lib/teams";
import { capture } from "../lib/telemetry";
import { useEvent } from "../lib/useEvent";
import { toTeams, useEventTeams, participantsKey } from "../lib/useEventExtras";
import { isTeamFormat } from "../lib/formats";
import type { EventBundle } from "../lib/api";
import type { EventTeam } from "../lib/types";

/* Print (contract/room-tools-2026-11-13.md § 5): /e/<event>/print/<pairings|pairings-az|standings|slips>, opened from
   the organizer's bar. The page is previewed as it prints (light paper, the sideboard guide's look); Print hands it to
   the browser. Browser only. */

/** The newest round's matches and the standings, as the print views read them. */
export function printModel(bundle: EventBundle, teams: EventTeam[] | null, extras: Map<string, number>, date: string): PrintModel {
  const { event, participants, rounds } = bundle;
  const round = [...rounds].sort((a, b) => b.number - a.number)[0] ?? null;
  const player = new Map(participants.map((p) => [p.id, p]));
  const team = isTeamFormat(event.formatName) && !!event.teamSize;
  return {
    event: event.name,
    facts: [event.formatLabel, event.venueName].filter(Boolean).join(" · "),
    round: round ? printRound(round.stage, round.number, event.numberOfRounds) : "",
    date,
    seatFormats: event.seatFormats,
    playoff: (round?.stage ?? "swiss") !== "swiss",
    matches: (round?.matches ?? []).map((m) => ({
      tableNumber: m.tableNumber, isBye: m.isBye, status: m.status, gameDraws: m.gameDraws,
      sides: m.sides.map((s) => ({ side: s.side, displayName: player.get(s.participantId ?? "")?.displayName ?? "—", gameWins: s.gameWins })),
      slot: team ? player.get(m.sides[0]?.participantId ?? "")?.teamSlot ?? null : null,
      extraSeconds: extras.get(m.id) ?? m.extraSeconds ?? 0,
    })),
    standings: playoffStandings(participants, rounds).map((s) => ({
      rank: s.rank, name: s.displayName, points: s.matchPoints, record: recordLabel(s), omw: formatPct(s.opponentMatchWinPct), gw: formatPct(s.gameWinPct),
      dropped: s.status === "dropped",
    })),
    teams: team && teams ? computeTeamStandings(toTeams(teams), participants, rounds).map((t) => ({
      rank: t.rank, name: t.name, points: t.points, record: t.draws > 0 ? `${t.wins}-${t.losses}-${t.draws}` : `${t.wins}-${t.losses}`,
    })) : undefined,
  };
}

export function PrintScreen({ eventId, what, onBack }: { eventId: string; what: string | undefined; onBack: () => void }) {
  const { bundle, error, refetch } = useEvent(eventId);
  const { room } = useEventRoom(eventId, null, bundle);
  const team = !!bundle && isTeamFormat(bundle.event.formatName) && !!bundle.event.teamSize;
  const { teams } = useEventTeams(eventId, team, participantsKey(bundle?.participants));
  const frame = useRef<HTMLIFrameElement>(null);
  const view: PrintWhat | null = isPrintWhat(what) ? what : null;
  const html = useMemo(
    () => (bundle && view ? printHtml(view, printModel(bundle, teams, extraByMatch(room), printDate())) : null),
    [bundle, view, teams, room],
  );
  if (!view) {
    return <Screen><Bar title="Print" onBack={onBack} /><Notice tone="info">There's no such print view.</Notice></Screen>;
  }
  if (!bundle || !html) {
    return (
      <Screen width="wide">
        <Bar title={printLabel(view)} onBack={onBack} />
        {error ? <><Notice tone="error">{error}</Notice><div className="flex"><GhostAction label="Try again" onClick={() => void refetch()} /></div></>
          : <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
      </Screen>
    );
  }
  const print = () => {
    capture("printed", { what: view });
    frame.current?.contentWindow?.print();
  };
  return (
    <Screen width="wide">
      <Bar title={`${bundle.event.name} · ${printLabel(view)}`} onBack={onBack} />
      <div className="flex-1 bg-white p-4">
        <iframe ref={frame} title={`${bundle.event.name} · ${printLabel(view)}`} srcDoc={html} className="w-full h-[calc(100dvh-190px)] border-0 bg-white" />
      </div>
      <BigAction label="Print" onClick={print} />
    </Screen>
  );
}
