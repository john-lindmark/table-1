import { useState } from "react";
import { Screen, Segmented } from "../components/kit";
import { SeatingPanel } from "../components/SeatingPanel";
import type { Participant, SeatingPod } from "../lib/types";
import { NewEvent } from "./Home";

// Design QA without signing in (dev server only): /dev/events shows the create form and the seating table on
// sample data. Server calls made from here fail (no session).
const NAMES = ["Ann Ito", "Bo Lindqvist", "Cy Park", "Dee Okafor", "Eli Moreau", "Fen Zhou", "Gus Varga", "Hal Brandt"];

function pod(n: number, id = `pod${n}`): SeatingPod {
  return {
    pod_id: id,
    name: "Pod 1",
    seats: Array.from({ length: n }, (_, i) => ({ seat: i + 1, participant_id: `p${i + 1}`, display_name: NAMES[i], team: null })),
  };
}

const people: Participant[] = NAMES.map((n, i) => ({
  id: `p${i + 1}`, eventId: "demo", podId: "pod8", displayName: n, seat: i + 1, status: "active", droppedInRound: null,
}));

export function EventsDemo() {
  const [screen, setScreen] = useState<"create" | "seating">("seating");
  return (
    <Screen>
      <Segmented
        label="Demo"
        value={screen}
        onChange={setScreen}
        options={[
          { value: "create", label: "Create" },
          { value: "seating", label: "Seating" },
        ]}
      />
      {screen === "create" ? (
        <NewEvent onCancel={() => setScreen("seating")} onCreated={() => {}} />
      ) : (
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          <SeatingPanel pods={[pod(8)]} formatName="draft" participants={people} teams={null} highlightParticipantId="p3" />
          <SeatingPanel pods={[pod(7, "pod7")]} formatName="draft" participants={people} teams={null} />
        </div>
      )}
    </Screen>
  );
}
