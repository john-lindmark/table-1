import { useEffect, useState } from "react";
import { Bar, Notice, Row, Screen } from "../components/kit";
import { errorMessage } from "../lib/api";
import { JOIN_NOTICE } from "../lib/joinPreview";
import { currentFix, joinNearby, nearbyDetail, nearbyEvents, updatePresence, type Fix, type NearbyEvent } from "../lib/nearby";
import { capture, screen as captureScreen } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/** Open events within 150 m, nearest first (same as iOS NearbyView and Android NearbyScreen). The browser asks for
 *  location when this opens; coordinates are sent once per lookup and never stored. */
export function NearbyScreen({ onBack, onOpen }: { onBack: () => void; onOpen: (eventId: string) => void }) {
  const { session, ready } = useSession();
  if (ready && !session) {
    return <Screen><Bar title="Nearby" onBack={onBack} /><Notice tone="info">Sign in to find and join events near you.</Notice></Screen>;
  }
  return ready ? <NearbyBody onBack={onBack} onOpen={onOpen} /> : null;
}

function NearbyBody({ onBack, onOpen }: { onBack: () => void; onOpen: (eventId: string) => void }) {
  const [fix, setFix] = useState<Fix | null>(null);
  const [events, setEvents] = useState<NearbyEvent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [joining, setJoining] = useState<string | null>(null);
  const search = async () => {
    setError(null);
    setEvents(null);
    const f = await currentFix();
    if (!f) {
      setError("Couldn't get your location. Enter the event code or scan the organizer's QR code instead.");
      setEvents([]);
      return;
    }
    setFix(f);
    void updatePresence(f).catch(() => {});
    try {
      setEvents(await nearbyEvents(f));
    } catch (e) {
      setError(errorMessage(e));
      setEvents([]);
    }
  };
  useEffect(() => {
    captureScreen("nearby");
    void search();
  }, []);
  const join = async (e: NearbyEvent) => {
    if (!fix) return;
    setJoining(e.event_id);
    try {
      const r = await joinNearby(e.event_id, fix);
      capture("event_joined", { via: "nearby" });
      onOpen(r.event_id ?? e.event_id);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setJoining(null);
    }
  };
  return (
    <Screen>
      <Bar title="Nearby" subtitle="Events within 150 m" onBack={onBack}
           right={<button type="button" onClick={() => void search()} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Refresh</button>} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {error && <Notice tone="error">{error}</Notice>}
        {events === null && <div className="bg-t1-surface px-4 py-4 t1-label">Finding events near you…</div>}
        {events?.length === 0 && !error && <Notice tone="info">Nothing open nearby right now.</Notice>}
        {!!events?.length && <Notice tone="info">{JOIN_NOTICE}</Notice>}
        {events?.map((e) => e.joined
          ? <Row key={e.event_id} title={e.name} detail={nearbyDetail(e)} value="Joined" onClick={() => onOpen(e.event_id)} />
          : <Row key={e.event_id} title={e.name} detail={nearbyDetail(e)}
                 action={{ label: joining === e.event_id ? "Joining…" : "Join", onClick: () => void join(e), disabled: !!joining }} />)}
      </div>
    </Screen>
  );
}
