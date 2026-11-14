import { useCallback, useEffect, useRef, useState } from "react";
import { errorMessage, leaveEvent } from "../lib/api";
import {
  PENDING_POLL_MS, PENDING_POLL_TRIES, checkout, eventMoney, feeLine, money, paidWord, paymentsMessage, payoutWords, prizeTable, refund,
  type EventMoney,
} from "../lib/money";
import { ordinal } from "../lib/leagues";
import { BigAction, Dialog, GhostAction, Notice, Row } from "./kit";
import { BAR_ICON, Icon } from "./icons";
import { Over } from "./EventListing";

/* An event's money on its own screens (contract/entry-fees-2026-11-13.md §§ 2, 3): the fee on the data line, the
   Prize pool row and its breakdown, and a signed-up player's Pay / pending / paid / refunded states. Everything here
   reads event_money; while the server has none of it (or the read fails) nothing draws. */

/** event_money, read once and again whenever `version` changes (the screen's own reload) or `reload()` is called. */
export function useEventMoney(eventId: string | null | undefined, token?: string | null, version: unknown = 0) {
  const [state, setState] = useState<EventMoney | null>(null);
  const live = useRef(true);
  // Set again on every mount: StrictMode mounts, unmounts and mounts once more in dev.
  useEffect(() => {
    live.current = true;
    return () => { live.current = false; };
  }, []);
  const reload = useCallback(async () => {
    if (!eventId) return null;
    const m = await eventMoney(eventId, token);
    if (live.current) setState(m);
    return m;
  }, [eventId, token]);
  useEffect(() => {
    void reload();
  }, [reload, version]);
  return { money: state, reload };
}

/** The fee as it joins an event's data line: "$25 · APP OR DOOR", "FREE"; nothing with no fee. */
export const feeFact = (m: EventMoney | null | undefined) => (m?.fee ? feeLine(m.fee) : null);

function Line({ label, value, strong, accent }: { label: string; value: string; strong?: boolean; accent?: boolean }) {
  return (
    <div className="bg-t1-surface px-4 py-3 flex items-baseline justify-between gap-4">
      <span className={strong ? "text-[13px]" : "t1-label"}>{label}</span>
      <span className={`tabular-nums ${strong ? "text-[17px]" : "text-[13px]"} ${accent ? "text-t1-accent" : ""}`}>{value}</span>
    </div>
  );
}

/** The Prize pool row (`$162`) and, one tap deeper, where it comes from and what each place takes as it stands. */
export function PrizePoolRow({ money: m, eventName, leagueName }: { money: EventMoney | null; eventName: string; leagueName?: string | null }) {
  const [open, setOpen] = useState(false);
  if (!m?.fee || !m.pool) return null;
  const { fee, pool } = m;
  // A fee with nothing to hand out (no entries yet, nothing added, no table) still shows its pool: it grows with entries.
  const places = prizeTable(fee.payout, pool.pool_cents);
  return (
    <>
      <Row title="Prize pool" value={<span className="flex items-center gap-3"><span className="text-[15px]">{money(pool.pool_cents)}</span><Icon d={BAR_ICON.arrow} /></span>}
           onClick={() => setOpen(true)} />
      {open && (
        <Over title={eventName} onBack={() => setOpen(false)}>
          <div className="bg-t1-bg px-4 py-6 flex flex-col items-center gap-1">
            <p className="t1-label">Prize pool</p>
            <p className="text-[48px] leading-[56px] tabular-nums tracking-[2px] text-t1-accent">{money(pool.pool_cents)}</p>
            <p className="t1-label">{feeLine(fee)}</p>
          </div>
          <Line label={`${pool.entries} ${pool.entries === 1 ? "entry" : "entries"}`} value={money(pool.gross_cents)} />
          {pool.league_cut_cents > 0 && <Line label={leagueName ? `To ${leagueName}` : "To the league"} value={`−${money(pool.league_cut_cents)}`} />}
          {pool.host_keep_cents > 0 && <Line label="To the host" value={`−${money(pool.host_keep_cents)}`} />}
          {pool.added_cents > 0 && <Line label="Added" value={`+${money(pool.added_cents)}`} />}
          <Line label="Pool" value={money(pool.pool_cents)} strong />
          {places.length > 0 && <div className="bg-t1-surface px-4 py-2 t1-label">{payoutWords(fee.payout)}</div>}
          {places.map((p) => <Line key={p.place} label={ordinal(p.place)} value={money(p.amount_cents)} />)}
          {places.length === 0 && <Notice tone="info">No prizes set.</Notice>}
        </Over>
      )}
    </>
  );
}

/**
 * A signed-up player's payment: Pay $25 (checkout opens in this tab and comes back to /pay/done), "Finishing your
 * payment…" while Stripe's word is on its way, PAID with Refund and leave, REFUNDED. Draws nothing for someone who
 * isn't in the event or an event with no fee.
 */
export function PayBlock({ eventId, eventName, money: m, reload, onLeft }: {
  eventId: string; eventName: string; money: EventMoney | null; reload: () => Promise<EventMoney | null>; onLeft?: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [refunding, setRefunding] = useState(false);
  const me = m?.me ?? null;
  const status = me?.status;

  // Stripe's word arrives by webhook: while the payment is pending, look again every 2 s for up to 20 s, and
  // whenever the tab comes back to the front.
  useEffect(() => {
    if (status !== "pending") return;
    let tries = 0;
    const id = window.setInterval(() => {
      if (++tries > PENDING_POLL_TRIES) window.clearInterval(id);
      else void reload();
    }, PENDING_POLL_MS);
    return () => window.clearInterval(id);
  }, [status, reload]);
  useEffect(() => {
    if (!me) return;
    const back = () => { if (document.visibilityState === "visible") void reload(); };
    document.addEventListener("visibilitychange", back);
    return () => document.removeEventListener("visibilitychange", back);
  }, [me, reload]);

  if (!m?.fee || !me) return null;
  const fee = m.fee;
  const amount = money(fee.amount_cents);

  async function pay() {
    setBusy(true);
    setError(null);
    try {
      // Stripe's hosted page, in this tab; it returns to /pay/done, which reads the payment again.
      window.location.assign(await checkout(eventId));
    } catch (e) {
      setError(paymentsMessage(e));
      setBusy(false);
    }
  }

  async function refundAndLeave() {
    setBusy(true);
    setError(null);
    try {
      await refund(eventId, null, "player");
      await leaveEvent(eventId, false);
      setRefunding(false);
      onLeft?.();
      await reload();
    } catch (e) {
      setError(e instanceof Error && !("status" in e) ? errorMessage(e) : paymentsMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const tag = (text: string, accent = false) => (
    <div className={`bg-t1-surface px-4 py-3 text-center text-[13px] uppercase tracking-[3px] ${accent ? "text-t1-accent" : ""}`}>{text}</div>
  );
  return (
    <div className="flex flex-col gap-px">
      {status === "paid" && tag(paidWord(me), true)}
      {status === "refunded" && tag("Refunded")}
      {status === "pending" && tag("Finishing your payment…")}
      {status === "unpaid" && fee.amount_cents > 0 && !me.can_pay && tag(`${amount} at the door`)}
      {status !== "paid" && me.can_pay && (
        status === "unpaid"
          ? <BigAction label={`Pay ${amount}`} tone="accent" busy={busy} onClick={() => void pay()} />
          : <div className="flex"><GhostAction label="Pay again" disabled={busy} onClick={() => void pay()} /></div>
      )}
      {status === "unpaid" && me.can_pay && fee.pay_mode === "either" && <div className="bg-t1-surface px-4 py-2 t1-label text-center">or pay at the door</div>}
      {status === "paid" && me.can_refund && (
        <div className="flex"><GhostAction label="Refund and leave" disabled={busy} onClick={() => { setError(null); setRefunding(true); }} /></div>
      )}
      {error && !refunding && <Notice tone="error">{error}</Notice>}
      {refunding && (
        <Dialog title={`Leave ${eventName}?`} message={`Your ${amount} goes back to the card you paid with, and you leave the event.`}
                cancelLabel="Stay" confirmLabel="Refund and leave" busyLabel="Refunding…" tone="danger" busy={busy} error={error}
                onCancel={() => setRefunding(false)} onConfirm={() => void refundAndLeave()} />
      )}
    </div>
  );
}
