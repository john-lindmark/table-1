import { useCallback, useEffect, useState } from "react";
import { fetchSuggestedPlayers, inviteByEmail, invitePlayers, errorMessage } from "../lib/api";
import type { SuggestedPlayer } from "../lib/types";
import { Bar, BigAction, Notice, Screen } from "../components/kit";
import { Avatar } from "../components/Avatar";

/**
 * Invite people to an event you're organizing. Friends come first, then people you've shared the most events
 * with; search narrows both. Email reaches existing accounts only and never says whether one exists.
 */
export function AddPlayers({ eventId, onDone }: { eventId: string; onDone: () => void }) {
  const [query, setQuery] = useState("");
  const [people, setPeople] = useState<SuggestedPlayer[] | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async (q: string) => {
    try {
      setPeople(await fetchSuggestedPlayers(eventId, q));
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
      setPeople((p) => p ?? []);
    }
  }, [eventId]);

  useEffect(() => {
    const id = window.setTimeout(() => load(query), query ? 300 : 0);
    return () => window.clearTimeout(id);
  }, [query, load]);

  const toggle = (id: string) =>
    setPicked((s) => {
      const next = new Set(s);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const emailValid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim());
  const friends = (people ?? []).filter((p) => p.friend);
  const others = (people ?? []).filter((p) => !p.friend);

  const row = (p: SuggestedPlayer) => {
    const on = picked.has(p.user_id);
    const together = `${p.shared_events} event${p.shared_events === 1 ? "" : "s"} together`;
    return (
      <button
        key={p.user_id}
        disabled={p.invited}
        onClick={() => toggle(p.user_id)}
        className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3.5 flex items-center gap-3 text-left disabled:hover:bg-t1-surface"
      >
        <Avatar name={p.display_name} userId={p.user_id} opens="add_players" />
        <span className="flex-1 min-w-0 flex flex-col">
          <span className="text-[14px] truncate">{p.handle || p.display_name}</span>
          <span className="t1-label">{p.friend ? (p.shared_events ? `Friend · ${together}` : "Friend") : together}</span>
        </span>
        {p.invited ? (
          <span className="t1-label">Invited</span>
        ) : (
          <span aria-hidden className={`w-5 h-5 ${on ? "bg-t1-accent" : "bg-t1-bg"}`} />
        )}
      </button>
    );
  };

  async function invite() {
    setBusy(true);
    setError(null);
    try {
      const friends = (people ?? []).filter((p) => p.friend && picked.has(p.user_id)).length;
      const n = await invitePlayers(eventId, [...picked], friends);
      setPicked(new Set());
      setNotice(n === 1 ? "1 invitation sent." : `${n} invitations sent.`);
      await load(query);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function sendEmail() {
    const address = email.trim();
    setBusy(true);
    setError(null);
    try {
      await inviteByEmail(eventId, address);
      setEmail("");
      setNotice(`If ${address} has a Table 1 account, they'll get your invite.`);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Screen>
      <Bar
        title="Add players"
        subtitle="Invitations — they accept to take a seat"
        right={
          <button onClick={onDone} className="t1-label shrink-0">
            Done
          </button>
        }
      />
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search friends and people you've played with"
        className="bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60"
      />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {error && <Notice tone="error">{error}</Notice>}
        {notice && <Notice tone="info">{notice}</Notice>}
        {people === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {friends.length > 0 && <div className="bg-t1-surface px-4 py-2 t1-label">Friends · {friends.length}</div>}
        {friends.map(row)}
        {people && (
          <div className="bg-t1-surface px-4 py-2 t1-label">
            {query ? (friends.length ? "Played with you" : "Matches") : "Suggested · played with you most"}
          </div>
        )}
        {people && others.length === 0 && (
          <Notice tone="info">
            {query
              ? `No one else you've played with matches "${query}".`
              : friends.length
                ? "People you play with show up here too."
                : "No one yet. Friends and people you play with show up here; until then, invite by email below or share the QR from the event."}
          </Notice>
        )}
        {others.map(row)}
        <div className="bg-t1-surface px-4 py-2 t1-label">Invite by email</div>
        <div className="flex gap-px">
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && emailValid && sendEmail()}
            placeholder="name@example.com"
            className="flex-1 min-w-0 bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60"
          />
          <button
            disabled={!emailValid || busy}
            onClick={sendEmail}
            className="bg-t1-accent text-t1-ink px-6 text-[11px] uppercase tracking-[1px] disabled:bg-t1-surface disabled:text-t1-muted"
          >
            Send
          </button>
        </div>
        <Notice tone="info">
          Works for people who already have a Table 1 account. For anyone else, show them the event's QR code.
        </Notice>
      </div>
      <BigAction
        label={picked.size ? `Invite ${picked.size}` : "Select players"}
        tone="accent"
        disabled={!picked.size}
        busy={busy}
        onClick={invite}
      />
    </Screen>
  );
}
