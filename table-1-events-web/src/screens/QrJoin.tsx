import { JOIN_NOTICE } from "../lib/joinPreview";
import { useEffect, useRef, useState } from "react";
import { joinEventByQr, joinEvent, errorMessage } from "../lib/api";
import { saveLocalParticipant } from "../lib/session";
import { useSession } from "../lib/useSession";
import { SignInButtons } from "../components/SignInButtons";
import { JoinBanner } from "../components/JoinBanner";
import { Bar, BigAction, Field, Notice, Screen } from "../components/kit";

/**
 * The owner's QR code lands here: /j/<code>?s=<secret>.
 * Signed in → seated immediately, record and head-to-head follow the account.
 * Not signed in → the event named over sign-in with Apple/Google/email, which also makes new accounts (comes back
 * here), or join as a walk-in guest.
 */
export function QrJoin({
  code,
  secret,
  onJoined,
}: {
  code: string;
  secret: string | null;
  onJoined: (eventId: string) => void;
}) {
  const { session, ready } = useSession();
  const [error, setError] = useState<string | null>(null);
  const [joining, setJoining] = useState(false);
  const [guestName, setGuestName] = useState("");
  const started = useRef(false);

  useEffect(() => {
    if (!ready || !session || started.current) return;
    started.current = true;
    if (!secret) {
      setError("This link is missing its code. Ask the organizer to show the QR again.");
      return;
    }
    setJoining(true);
    joinEventByQr(code, secret)
      .then((r) => onJoined(r.event_id))
      .catch((e) => setError(errorMessage(e)))
      .finally(() => setJoining(false));
  }, [ready, session, code, secret, onJoined]);

  async function joinAsGuest() {
    setJoining(true);
    setError(null);
    try {
      const r = await joinEvent(code, guestName);
      saveLocalParticipant({
        eventId: r.event_id,
        shortCode: r.short_code,
        participantId: r.participant_id,
        token: r.token,
        displayName: guestName.trim(),
      });
      onJoined(r.event_id);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setJoining(false);
    }
  }

  if (!ready || (session && joining)) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Joining {code.toUpperCase()}…</div>
      </Screen>
    );
  }

  if (session) {
    return (
      <Screen>
        <Bar title="Join event" subtitle={code.toUpperCase()} />
        {error && <Notice tone="error">{error}</Notice>}
      </Screen>
    );
  }

  return (
    <Screen>
      <Bar title="Join event" subtitle={code.toUpperCase()} />
      <JoinBanner code={code} />
      <SignInButtons />
      <div className="bg-t1-surface px-4 py-2 t1-label">Or join as a guest</div>
      <Field label="Your name" value={guestName} onChange={setGuestName} placeholder="e.g. John L" />
      <Notice tone="info">{JOIN_NOTICE}</Notice>
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1" />
      <BigAction
        label="Join as guest"
        busy={joining}
        disabled={guestName.trim().length === 0}
        onClick={joinAsGuest}
      />
    </Screen>
  );
}
