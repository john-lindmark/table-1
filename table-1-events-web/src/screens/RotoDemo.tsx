// Dev server only: /dev/roto[?tab=grid|cube|picks|list|schedule] opens a roto draft without signing in, like iOS
// Debug `-T1RotoDemo`. The draft runs locally (lib/rotoDemo.ts); Schedule shows a round robin of 8 after the draft.
import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import type { EventBundle } from "../lib/api";
import { putRotoStore, RotoStore, useRotoStore } from "../lib/roto";
import { DEMO_EVENT, DEMO_NAMES, RotoDemoBackend, demoCube } from "../lib/rotoDemo";
import { roundRobinPairs } from "../lib/roundrobin";
import type { Match, Participant, RoundWithMatches, Table1Event } from "../lib/types";
import { Bar, Notice, Segmented } from "../components/kit";
import { RotoDraftScreen, type RotoTab } from "./roto/RotoDraft";
import { RotoSchedule } from "./roto/RotoSetup";

let demoStore: Promise<RotoStore> | null = null;
function loadDemoStore(): Promise<RotoStore> {
  demoStore ??= demoCube().then((cube) => {
    const s = new RotoStore(DEMO_EVENT, new RotoDemoBackend(cube));
    putRotoStore(s);
    return s;
  });
  return demoStore;
}

export function RotoDemo() {
  const [q] = useSearchParams();
  const pick = q.get("tab") ?? "grid";
  const [screen, setScreen] = useState<"draft" | "schedule">(pick === "schedule" ? "schedule" : "draft");
  const [store, setStore] = useState<RotoStore | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    loadDemoStore()
      .then(async (s) => {
        await s.load();
        if (live) setStore(s);
      })
      .catch((e) => live && setError(String(e)));
    return () => {
      live = false;
    };
  }, []);
  const tab = (["grid", "cube", "picks", "list"].includes(pick) ? pick : "grid") as RotoTab;
  return (
    <div className="h-[100dvh] flex flex-col gap-px bg-t1-bg text-t1-text">
      <div className="shrink-0">
        <Segmented value={screen} onChange={setScreen} options={[{ value: "draft", label: "Draft" }, { value: "schedule", label: "Schedule" }]} />
      </div>
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 flex flex-col">
        {screen === "schedule" ? (
          <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
            <Bar title="Roto · Vintage Cube" subtitle="Round robin · round 3 of 7" />
            <RotoSchedule bundle={scheduleBundle} meId="demo-p3" />
          </div>
        ) : store ? (
          <DemoDraft store={store} tab={tab} />
        ) : (
          <div className="flex-1 flex items-center justify-center t1-label">Loading the demo draft…</div>
        )}
      </div>
    </div>
  );
}

function DemoDraft({ store, tab }: { store: RotoStore; tab: RotoTab }) {
  useRotoStore(store);
  useEffect(() => store.listen(), [store]);
  return (
    <div className="flex-1 min-h-0 [&>div]:h-full!">
      <RotoDraftScreen store={store} title="Roto · Vintage Cube · Fri 17 Oct" isOrganizer initialTab={tab} />
    </div>
  );
}

/** A round robin of 8 after the draft: rounds 1–2 played, round 3 running with two results in. */
const scheduleBundle: EventBundle = (() => {
  const names = DEMO_NAMES.map((n) => (n === "You" ? "Cy Park" : n));
  const ids = names.map((_, i) => `demo-p${i + 1}`);
  const event: Table1Event = {
    id: DEMO_EVENT, shortCode: "R0T0", name: "Roto · Vintage Cube · Fri 17 Oct", format: "cube", status: "in_progress",
    numberOfRounds: 7, currentRound: 3, roundLengthSeconds: 3000, allowPlayerReporting: true, createdBy: null, cancelReason: null,
    formatName: "roto", formatLabel: "Roto · Vintage Cube", eventType: "limited", teamSize: null, setName: null,
    cubeName: "Vintage Cube", cubeUrl: null, setCode: null, formatOther: null, cancelledAt: null, updatedAt: null, showClock: true,
    autoName: true, pairing: "round_robin", topCut: 0, autoRounds: false, capacity: null, startsAt: null, venueName: null,
    decklists: "off",
  };
  const participants: Participant[] = ids.map((id, i) => ({
    id, eventId: DEMO_EVENT, podId: "pod", displayName: names[i], seat: i + 1, status: "active", droppedInRound: null,
    userId: i === 2 ? null : `u${i + 1}`,
  }));
  const rounds: RoundWithMatches[] = [1, 2, 3].map((r) => {
    const matches: Match[] = roundRobinPairs(ids, r).map(([a, b], k) => {
      const table = k + 1;
      const done = r < 3 || table <= 2;
      const [wa, wb] = done ? ((r + table) % 3 === 0 ? [1, 2] : [2, table % 2]) : [0, 0];
      return {
        id: `m${r}-${table}`, eventId: DEMO_EVENT, roundId: `r${r}`, tableNumber: table, isBye: false, gameDraws: 0,
        intentionalDraw: false, status: done ? "confirmed" : "pending", version: 1, disputed: false, reportedByUser: null,
        reportedByParticipant: null,
        sides: [
          { id: `s${r}-${table}-0`, matchId: `m${r}-${table}`, participantId: a!, side: 0, gameWins: wa },
          { id: `s${r}-${table}-1`, matchId: `m${r}-${table}`, participantId: b!, side: 1, gameWins: wb },
        ],
      };
    });
    return {
      id: `r${r}`, eventId: DEMO_EVENT, number: r, status: r < 3 ? "recorded" : "active", timerDurationSeconds: 3000,
      timerRemainingAtChange: 3000, timerStatus: "running", timerLastStartedAt: null, timerEndsAt: null, matches,
    };
  });
  return { event, participants, rounds, waitlist: [], decklists: [] };
})();
