import { useEffect, useState } from "react";
import { Over } from "../../components/EventListing";
import { BAR_ICON, Icon } from "../../components/icons";
import { BigAction, Dialog, Field, GhostAction, Menu, Notice, Row, Segmented, type MenuItem } from "../../components/kit";
import { ordinal } from "../../lib/leagues";
import {
  PAYOUT_LABELS, PAYOUT_PRESETS, PRIZE_HOWS, REFUND_PICKS, centsOf, centsText, connectStart, eventFeeSet, eventPaymentMark, eventPrizeMark,
  eventPrizesSet, feeLine, money, payTag, paymentsMessage, payoutPresetOf, payoutTotal, payoutWords, poolOf, prizePaidTag, refund,
  PaymentsError, type EventMoney, type Fee, type KeepKind, type PayMode, type PayoutBracket, type PayoutPreset, type PlayerPayment, type Prize,
} from "../../lib/money";
import { usePaymentsEnabled } from "../../lib/usePayments";

/* The organizer's side of entry fees (contract/entry-fees-2026-11-13.md §§ 2, 4): the fee in Setup → Details, a
   payment tag and its menu on every player, and Results → Prizes. */

const errorText = (e: unknown) =>
  e instanceof PaymentsError ? paymentsMessage(e) : e instanceof Error ? e.message : String((e as { message?: unknown } | null)?.message ?? e);

/* ── the fee ─────────────────────────────────────────────────────────── */

/** Setup → Details → Entry fee: `NONE`, or `$25 · APP OR DOOR`, opening the fee. Hidden until the server has fees and payments are
 *  open to this account (§ 1 "Hidden for now"). */
export function FeeRow({ eventId, money: m, players, leagueName, onSaved }: {
  eventId: string; money: EventMoney | null; players: number; leagueName?: string | null; onSaved: () => void;
}) {
  const [open, setOpen] = useState(false);
  const enabled = usePaymentsEnabled();
  if (!m || !enabled) return null;
  return (
    <>
      <Row title="Entry fee" value={<span className="flex items-center gap-3"><span className="t1-label !text-t1-text">{feeLine(m.fee)}</span><Icon d={BAR_ICON.arrow} /></span>}
           onClick={() => setOpen(true)} />
      {open && <FeeEditor eventId={eventId} money={m} players={players} leagueName={leagueName} onClose={() => setOpen(false)} onSaved={onSaved} />}
    </>
  );
}

const num = (v: string, min: number, max: number) => Math.max(min, Math.min(max, Number(v) || 0));

function FeeEditor({ eventId, money: m, players, leagueName, onClose, onSaved }: {
  eventId: string; money: EventMoney; players: number; leagueName?: string | null; onClose: () => void; onSaved: () => void;
}) {
  const was = m.fee;
  const [amount, setAmount] = useState(was ? centsText(was.amount_cents) : "");
  const [mode, setMode] = useState<PayMode>(was?.pay_mode ?? "door");
  const [refundPick, setRefundPick] = useState(was ? REFUND_PICKS.find((r) => r.hours === was.refund_hours)?.value ?? "ask" : "24");
  const [keepKind, setKeepKind] = useState<KeepKind>(was?.host_keep.kind ?? "none");
  const [keepText, setKeepText] = useState(was && was.host_keep.kind === "flat" ? centsText(was.host_keep.value) : was?.host_keep.kind === "percent" ? String(was.host_keep.value) : "");
  const [added, setAdded] = useState(was && was.added_cents > 0 ? centsText(was.added_cents) : "");
  const [preset, setPreset] = useState<PayoutPreset | "custom">(was ? payoutPresetOf(was.payout) : "top4");
  const [custom, setCustom] = useState<PayoutBracket[]>(was?.payout.length ? was.payout : PAYOUT_PRESETS.top4);
  const [stripeReady, setStripeReady] = useState(!!m.organizer?.stripe.ready);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [removing, setRemoving] = useState(false);

  const amountCents = amount.trim() === "" ? 0 : centsOf(amount);
  const addedCents = added.trim() === "" ? 0 : centsOf(added);
  const keepValue = keepKind === "flat" ? centsOf(keepText) ?? -1 : keepKind === "percent" ? num(keepText, 0, 100) : 0;
  const payout = preset === "custom" ? custom : PAYOUT_PRESETS[preset];
  const total = payoutTotal(payout);
  const rising = payout.every((b, i) => b.through > (i ? payout[i - 1].through : 0));
  const cut = was?.league_cut_cents ?? 0;
  const problem = amountCents == null || (amountCents !== 0 && (amountCents < 50 || amountCents > 100000)) ? "$0.50 to $1,000, or 0 for free"
    : addedCents == null ? "Added prize money is an amount"
    : keepKind === "flat" && keepValue < 0 ? "What you keep is an amount"
    : !rising ? "Each bracket reaches further than the one before"
    : total > 100.0001 ? `The prizes add up to ${Number(total.toFixed(2))}%`
    : mode !== "door" && !stripeReady ? "Connect Stripe first"
    : null;
  // What the pool would be with everyone signed up paid: a preview under the table.
  const preview = amountCents != null && addedCents != null && problem == null
    ? poolOf(players, amountCents, Math.min(cut, amountCents), keepKind, Math.max(0, keepValue), addedCents).pool_cents : null;

  async function save() {
    if (problem || amountCents == null || addedCents == null) return;
    setBusy(true);
    setError(null);
    try {
      await eventFeeSet(eventId, {
        amount_cents: amountCents, pay_mode: mode, refund_hours: REFUND_PICKS.find((r) => r.value === refundPick)?.hours ?? null,
        host_keep: { kind: keepKind, value: keepKind === "none" ? 0 : keepValue }, added_cents: addedCents, payout,
      });
      onSaved();
      onClose();
    } catch (e) {
      setError(errorText(e));
      setBusy(false);
    }
  }
  async function remove() {
    setBusy(true);
    try {
      await eventFeeSet(eventId, null);
      onSaved();
      onClose();
    } catch (e) {
      setError(errorText(e));
      setRemoving(false);
      setBusy(false);
    }
  }
  async function connect() {
    const tab = window.open("", "_blank");
    try {
      const url = await connectStart();
      if (tab) tab.location.href = url;
      else window.location.assign(url);
    } catch (e) {
      tab?.close();
      setError(errorText(e));
    }
  }
  // Back from Stripe's tab: the account may be ready now.
  useEffect(() => {
    if (stripeReady) return;
    const back = () => {
      if (document.visibilityState !== "visible") return;
      void import("../../lib/money").then((x) => x.paymentsAccount()).then((a) => a?.ready && setStripeReady(true));
    };
    document.addEventListener("visibilitychange", back);
    window.addEventListener("focus", back);
    return () => {
      document.removeEventListener("visibilitychange", back);
      window.removeEventListener("focus", back);
    };
  }, [stripeReady]);

  const setBracket = (i: number, patch: Partial<PayoutBracket>) => setCustom((c) => c.map((b, j) => (j === i ? { ...b, ...patch } : b)));
  const cell = "w-[84px] bg-t1-bg px-3 py-2 text-[15px] tabular-nums outline-0 border-0 text-right";
  return (
    <Over title="Entry fee" onBack={onClose}
          bottom={<BigAction label={problem ?? "Save"} tone="accent" busy={busy} disabled={!!problem} onClick={() => void save()} />}>
      <Field label="Amount · USD" value={amount} onChange={(v) => setAmount(v.replace(/[^0-9.]/g, "").slice(0, 8))} placeholder="0" autoFocus={!was} />
      <Segmented label="How players pay" value={mode} onChange={setMode}
                 options={[{ value: "door", label: "At the door" }, { value: "app", label: "In the app" }, { value: "either", label: "Either" }]} />
      {mode !== "door" && !stripeReady && (
        <Row title="Connect Stripe" detail="Entry fees go straight to your Stripe account" value={<Icon d={BAR_ICON.arrow} />} onClick={() => void connect()} />
      )}
      {mode !== "door" && (
        <Segmented label="Refunds" columns={2} value={refundPick} onChange={setRefundPick} options={REFUND_PICKS.map((r) => ({ value: r.value, label: r.label }))} />
      )}
      <Segmented label="You keep" value={keepKind} onChange={(k) => { setKeepKind(k); setKeepText(""); }}
                 options={[{ value: "none", label: "Nothing" }, { value: "flat", label: "An amount" }, { value: "percent", label: "A percent" }]} />
      {keepKind !== "none" && (
        <Field label={keepKind === "flat" ? "You keep · USD" : "You keep · percent"} value={keepText} placeholder="0"
               onChange={(v) => setKeepText(v.replace(/[^0-9.]/g, "").slice(0, 8))} />
      )}
      <Field label="Added prize money · USD" value={added} onChange={(v) => setAdded(v.replace(/[^0-9.]/g, "").slice(0, 8))} placeholder="0" />
      <Segmented label="Prizes" columns={2} value={preset} options={PAYOUT_LABELS}
                 onChange={(p) => { if (p === "custom" && preset !== "custom") setCustom(payout); setPreset(p); }} />
      <div className="bg-t1-surface px-4 py-3 t1-label">
        {payoutWords(payout)}{preview != null && players > 0 ? ` · ${money(preview)} with ${players} paid` : ""}
      </div>
      {preset === "custom" && (
        <>
          <div className="bg-t1-surface pl-4 py-2 flex items-center gap-px t1-label">
            <span className="flex-1">Places</span>
            <span className="w-[84px] px-3 text-right">Through</span>
            <span className="w-[84px] px-3 text-right">% each</span>
            <span className="w-[50px]" />
          </div>
          {custom.map((b, i) => {
            const from = (i ? custom[i - 1].through : 0) + 1;
            return (
              <div key={i} className="bg-t1-surface pl-4 flex items-center gap-px">
                <span className="flex-1 text-[13px]">{b.through === from ? ordinal(b.through) : `${ordinal(from)} to ${ordinal(b.through)}`}</span>
                <input type="number" inputMode="numeric" min={1} max={64} aria-label={`Bracket ${i + 1}: through place`} value={b.through}
                       onChange={(e) => setBracket(i, { through: Math.trunc(num(e.target.value, 1, 64)) })} className={cell} />
                <input type="number" inputMode="decimal" min={0} max={100} step="any" aria-label={`Bracket ${i + 1}: percent each`} value={b.percent}
                       onChange={(e) => setBracket(i, { percent: num(e.target.value, 0, 100) })} className={cell} />
                <button type="button" aria-label={`Remove bracket ${i + 1}`} onClick={() => setCustom((c) => c.filter((_, j) => j !== i))}
                        className="w-[50px] h-[42px] bg-t1-bg hover:bg-t1-surface-hover text-[18px]">−</button>
              </div>
            );
          })}
          {custom.length < 8 && (
            <Row title="Add a bracket" value={<Icon d={BAR_ICON.plus} />}
                 onClick={() => setCustom((c) => [...c, { through: (c[c.length - 1]?.through ?? 0) + 1, percent: 0 }])} />
          )}
          <div className="bg-t1-surface px-4 py-3 flex justify-between t1-label"><span>Total</span><span className={total > 100.0001 ? "text-t1-danger!" : ""}>{Number(total.toFixed(2))}%</span></div>
        </>
      )}
      {cut > 0 && <Notice tone="info">{money(cut)} an entry goes to {leagueName ?? "the league"}.</Notice>}
      {error && !removing && <Notice tone="error">{error}</Notice>}
      {was && <div className="flex"><GhostAction label="Remove fee" disabled={busy} onClick={() => { setError(null); setRemoving(true); }} /></div>}
      {removing && (
        <Dialog title="Remove the entry fee?" message="The event becomes free to enter and its prize pool goes." cancelLabel="Keep" confirmLabel="Remove fee"
                tone="danger" busy={busy} error={error} onCancel={() => setRemoving(false)} onConfirm={() => void remove()} />
      )}
    </Over>
  );
}

/* ── payments in the Players lists ───────────────────────────────────── */

export const paymentsById = (m: EventMoney | null | undefined) => new Map((m?.organizer?.players ?? []).map((p) => [p.participant_id, p]));

/** A player's payment tag, leading their data line; a tap opens Paid at the door / Comp / Unpaid / Refund. */
export function PayTagButton({ payment, onOpen }: { payment: PlayerPayment | undefined; onOpen: (p: PlayerPayment) => void }) {
  if (!payment) return null;
  const paid = payment.status === "paid";
  return (
    <button type="button" onClick={(e) => { e.stopPropagation(); onOpen(payment); }} aria-label={`${payment.name}: ${payTag(payment)}`}
            className={`uppercase hover:text-t1-accent ${paid ? "text-t1-text" : payment.status === "unpaid" ? "text-t1-warning" : ""}`}>
      {payTag(payment)}
    </button>
  );
}

/** A data line led by the payment tag: `PAID · APP · JOINED · SEAT 3`. */
export function payDetail(payment: PlayerPayment | undefined, onOpen: (p: PlayerPayment) => void, rest: string | null | undefined) {
  if (!payment) return rest || undefined;
  return <><PayTagButton payment={payment} onOpen={onOpen} />{rest ? ` · ${rest}` : ""}</>;
}

/** The payment menu for one player, and the refund confirm. */
export function PaymentMenu({ eventId, payment, amountCents, onClose, onChanged }: {
  eventId: string; payment: PlayerPayment; amountCents: number; onClose: () => void; onChanged: () => void;
}) {
  // The menu closes itself before its item runs: `closing` becomes the parent's close unless the item moved on.
  const [stage, setStage] = useState<"menu" | "closing" | "working" | "refund" | "error">("menu");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (stage === "closing") onClose();
  }, [stage, onClose]);
  const app = payment.status === "paid" && payment.method === "app";
  const mark = (state: "door" | "comp" | "unpaid") => {
    setStage("working");
    eventPaymentMark(eventId, payment.participant_id, state).then(() => { onChanged(); onClose(); },
      (e) => { setError(errorText(e)); setStage("error"); });
  };
  const items: MenuItem[] = app
    ? [{ title: "Refund", detail: `${money(amountCents)} back to their card`, onClick: () => setStage("refund") }]
    : [
        { title: "Paid at the door", checked: payment.status === "paid" && payment.method === "door", onClick: () => mark("door") },
        { title: "Comp", detail: "Plays free", checked: payment.method === "comp", onClick: () => mark("comp") },
        { title: "Unpaid", checked: payment.status === "unpaid", onClick: () => mark("unpaid") },
      ];
  if (stage === "error") {
    return <Dialog title={payment.name} message={error} cancelLabel="Close" confirmLabel="OK" onCancel={onClose} onConfirm={onClose} />;
  }
  if (stage === "refund") {
    return (
      <Dialog title={`Refund ${payment.name}?`} message={`${money(amountCents)} goes back to the card they paid with. They stay in the event, unpaid.`}
              cancelLabel="Keep" confirmLabel="Refund" busyLabel="Refunding…" tone="danger" busy={busy} error={error}
              onCancel={onClose}
              onConfirm={() => {
                setBusy(true);
                refund(eventId, payment.participant_id, "organizer").then(() => { onChanged(); onClose(); },
                  (e) => { setError(errorText(e)); setBusy(false); });
              }} />
    );
  }
  if (stage !== "menu") return null;
  return <Menu title={`${payment.name} · ${payTag(payment)}`} items={items} onClose={() => setStage((s) => (s === "menu" ? "closing" : s))} />;
}

/* ── Results → Prizes ────────────────────────────────────────────────── */

/** The pool, then each place with its amount and `PAID · CASH` or Mark paid; Split edits the amounts against the pool. */
export function PrizesTab({ eventId, money: m, onChanged }: { eventId: string; money: EventMoney; onChanged: () => void }) {
  const prizes = m.prizes ?? [];
  const pool = m.pool?.pool_cents ?? 0;
  const [splitting, setSplitting] = useState(false);
  const [amounts, setAmounts] = useState<Record<string, string>>({});
  const [menu, setMenu] = useState<Prize | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const custom = prizes.some((p) => p.custom);

  const startSplit = () => {
    setAmounts(Object.fromEntries(prizes.map((p) => [p.participant_id, centsText(p.amount_cents)])));
    setError(null);
    setSplitting(true);
  };
  const cents = prizes.map((p) => (amounts[p.participant_id]?.trim() ? centsOf(amounts[p.participant_id]) : 0));
  const total = cents.reduce<number>((n, c) => n + (c ?? 0), 0);
  const bad = cents.some((c) => c == null);
  const over = total > pool;

  const run = async (call: () => Promise<void>, done?: () => void) => {
    setBusy(true);
    setError(null);
    try {
      await call();
      done?.();
      onChanged();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="bg-t1-bg px-4 py-6 flex flex-col items-center gap-1">
        <p className="t1-label">Prize pool</p>
        <p className="text-[48px] leading-[56px] tabular-nums tracking-[2px] text-t1-accent">{money(pool)}</p>
        {m.fee && <p className="t1-label text-center">{custom ? "Split by agreement" : payoutWords(m.fee.payout)}</p>}
      </div>
      {prizes.length === 0 && <Notice tone="info">No prizes at this pool.</Notice>}
      {prizes.map((p, i) => (
        <div key={p.participant_id} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
          <span className="w-9 shrink-0 text-[12px] uppercase tabular-nums text-t1-muted">{ordinal(p.place)}</span>
          <span className="flex-1 min-w-0 text-[13px] truncate">{p.name}</span>
          {splitting ? (
            <input inputMode="decimal" aria-label={`${p.name}: prize`} value={amounts[p.participant_id] ?? ""}
                   onChange={(e) => setAmounts((a) => ({ ...a, [p.participant_id]: e.target.value.replace(/[^0-9.]/g, "").slice(0, 9) }))}
                   className={`w-[96px] bg-t1-bg px-3 py-2 text-[15px] tabular-nums outline-0 border-0 text-right ${cents[i] == null ? "text-t1-danger" : ""}`} />
          ) : (
            <>
              <span className="shrink-0 text-[15px] tabular-nums">{money(p.amount_cents)}</span>
              <button type="button" disabled={busy} onClick={() => setMenu(p)}
                      className={`shrink-0 w-[132px] text-right t1-label hover:text-t1-text ${p.paid ? "!text-t1-accent" : ""}`}>
                {p.paid ? prizePaidTag(p.paid_how) : "Mark paid"}
              </button>
            </>
          )}
        </div>
      ))}
      {splitting && (
        <div className="bg-t1-surface px-4 py-3 flex justify-between text-[13px] tabular-nums">
          <span className="t1-label">Total</span>
          <span className={over ? "text-t1-danger" : ""}>{money(total)} of {money(pool)}</span>
        </div>
      )}
      {error && <Notice tone="error">{error}</Notice>}
      {prizes.length > 0 && (
        <div className="flex gap-px">
          {splitting ? (
            <>
              <GhostAction label="Cancel" disabled={busy} onClick={() => setSplitting(false)} />
              <button type="button" disabled={busy || bad || over}
                      onClick={() => void run(() => eventPrizesSet(eventId, prizes.map((p, i) => ({ participant_id: p.participant_id, amount_cents: cents[i] ?? 0 }))), () => setSplitting(false))}
                      className="flex-1 bg-t1-text text-t1-bg disabled:bg-t1-disabled disabled:text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px]">
                {over ? "Over the pool" : bad ? "Check the amounts" : "Save split"}
              </button>
            </>
          ) : (
            <>
              <GhostAction label="Split" disabled={busy} onClick={startSplit} />
              {custom && <GhostAction label="Back to the table" disabled={busy} onClick={() => void run(() => eventPrizesSet(eventId, null))} />}
            </>
          )}
        </div>
      )}
      {menu && (
        <Menu title={`${menu.name} · ${money(menu.amount_cents)}`} onClose={() => setMenu(null)}
              items={[
                ...PRIZE_HOWS.map((h) => ({ title: h.label, checked: menu.paid && (menu.paid_how ?? "other") === h.value,
                                            onClick: () => void run(() => eventPrizeMark(eventId, menu.participant_id, true, h.value)) })),
                ...(menu.paid ? [{ title: "Not paid", onClick: () => void run(() => eventPrizeMark(eventId, menu.participant_id, false)) }] : []),
              ]} />
      )}
    </>
  );
}

export type { Fee };
