// Alert text for `event.signed_up` / `event.dropped` (contract/scheduled-events-2026-10-27.md § Organizer pushes):
// the organizers hear when someone signs up, joins the waitlist, drops or leaves it. `data` comes from
// t1_private.organizer_sign_up_push (event_name, name, waitlist); `count` is read when the push is sent, so a drop
// that moved someone up from the waitlist shows the full table.

export interface SignUpCount { players: number; capacity: number | null; waiting: number }

export function signUpCopy(kind: string, d: Record<string, unknown>, count: SignUpCount | null): { title: string; body: string } {
  const who = String(d.name ?? "A player");
  const what = kind === "event.signed_up"
    ? (d.waitlist ? `${who} joined the waitlist` : `${who} signed up`)
    : (d.waitlist ? `${who} left the waitlist` : `${who} dropped`);
  if (!count) return { title: String(d.event_name ?? "Your event"), body: `${what}.` };
  const players = count.capacity != null
    ? `${count.players}/${count.capacity} players`
    : `${count.players} player${count.players === 1 ? "" : "s"}`;
  const waiting = count.waiting > 0 ? ` · ${count.waiting} waiting` : "";
  return { title: String(d.event_name ?? "Your event"), body: `${what} · ${players}${waiting}` };
}
