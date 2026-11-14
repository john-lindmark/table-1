import { useCallback, useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Over } from "../components/EventListing";
import { BAR_ICON, Icon } from "../components/icons";
import { BigAction, Notice, Row, Screen, T1Logo } from "../components/kit";
import { demoPath, leaguesDemoOn } from "../lib/leagues";
import {
  PAY_DONE_TITLE, PENDING_POLL_MS, PENDING_POLL_TRIES, connectDashboard, connectStart, connectStatus, eventMoney, money, payDoneState,
  paymentsAccount, paymentsMessage, stripeLine, PaymentsError, type EventMoney, type StripeAccount,
} from "../lib/money";
import { capture } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/* A host's Stripe account and Stripe's return pages (contract/entry-fees-2026-11-13.md §§ 1, 3). The host is the
   seller on their own Stripe account; onboarding and checkout are Stripe's own pages, never a frame. The /pay pages
   are plain web pages the apps never claim: Stripe sends people back to them from an in-app browser tab too. */

/** Opens a link from an async call in a new tab: the tab opens at once (inside the tap), then goes to the link. */
async function openInNewTab(link: () => Promise<string>): Promise<void> {
  const tab = window.open("", "_blank");
  try {
    const url = await link();
    if (tab) tab.location.href = url;
    else window.location.assign(url);   // pop-ups blocked: this tab
  } catch (e) {
    tab?.close();
    throw e;
  }
}

/** Account → Payments: `NOT CONNECTED` / `FINISH SETTING UP` / `READY`. Hidden while the server has no payments. */
export function PaymentsAccountRow() {
  const [account, setAccount] = useState<StripeAccount | null>(null);
  const [open, setOpen] = useState(() => new URLSearchParams(window.location.search).has("payments"));
  useEffect(() => {
    let live = true;
    void paymentsAccount().then((a) => live && setAccount(a));
    return () => { live = false; };
  }, []);
  if (!account) return null;
  return (
    <>
      <Row title="Payments" value={<span className={`t1-label ${account.ready ? "text-t1-accent!" : ""}`}>{stripeLine(account)}</span>} onClick={() => setOpen(true)} />
      {open && <PaymentsPanel account={account} onChange={setAccount} onClose={() => setOpen(false)} />}
    </>
  );
}

/** The Payments screen: the state large, Connect Stripe / Finish setting up (a new tab), and the dashboard once ready. */
export function PaymentsPanel({ account, onChange, onClose }: { account: StripeAccount; onChange: (a: StripeAccount) => void; onClose: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [off, setOff] = useState(false);
  /** Set once onboarding was opened: coming back to this page asks Stripe how it went. */
  const [started, setStarted] = useState(false);

  const check = useCallback(async () => {
    try {
      onChange(await connectStatus());
      setError(null);
    } catch (e) {
      if (e instanceof PaymentsError && e.off) setOff(true);
      else setError(paymentsMessage(e));
    }
  }, [onChange]);

  // Connected but not ready: ask Stripe once on opening (the last known state may be stale).
  useEffect(() => {
    if (account.connected && !account.ready) void check();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => {
    if (!started) return;
    const back = () => { if (document.visibilityState === "visible") void check(); };
    document.addEventListener("visibilitychange", back);
    window.addEventListener("focus", back);
    return () => {
      document.removeEventListener("visibilitychange", back);
      window.removeEventListener("focus", back);
    };
  }, [started, check]);

  async function run(link: () => Promise<string>, onboarding: boolean) {
    setBusy(true);
    setError(null);
    try {
      await openInNewTab(link);
      if (onboarding) setStarted(true);
    } catch (e) {
      if (e instanceof PaymentsError && e.off) setOff(true);
      else setError(paymentsMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Over title="Payments" onBack={onClose}
          bottom={!account.ready && !off ? (
            <BigAction label={account.connected ? "Finish setting up" : "Connect Stripe"} tone="accent" busy={busy} onClick={() => void run(connectStart, true)} />
          ) : undefined}>
      <div className="bg-t1-bg px-4 py-10 flex flex-col items-center gap-2">
        <p className="t1-label">Stripe</p>
        <p className={`text-[22px] leading-[28px] tracking-[3px] uppercase text-center ${account.ready ? "text-t1-accent" : ""}`}>{stripeLine(account)}</p>
      </div>
      {off && <Notice tone="info">{paymentsMessage(new PaymentsError("", 503))}</Notice>}
      {error && <Notice tone="error">{error}</Notice>}
      {account.ready && (
        <>
          <Row title="Open Stripe dashboard" value={<Icon d={BAR_ICON.arrow} />} onClick={() => void run(connectDashboard, false)} />
          <Notice tone="info">Entry fees go straight to your Stripe account.</Notice>
        </>
      )}
      {started && !account.ready && <div className="flex"><button type="button" onClick={() => void check()} className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]">Check again</button></div>}
    </Over>
  );
}

/** The frame of a /pay page: the mark, one large line, one line under it, and the way back. */
function PayPage({ label, title, accent, detail, children }: {
  label: string; title: string; accent?: boolean; detail?: string | null; children?: React.ReactNode;
}) {
  return (
    <Screen>
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        <div className="bg-t1-bg px-4 py-16 flex flex-col items-center gap-3">
          <T1Logo className="h-6 w-auto text-t1-text" />
          <p className="t1-label mt-8 text-center">{label}</p>
          <p className={`text-[28px] leading-[34px] tracking-[3px] uppercase text-center ${accent ? "text-t1-accent" : ""}`}>{title}</p>
          {detail && <p className="t1-label text-center">{detail}</p>}
        </div>
        {children}
      </div>
    </Screen>
  );
}

const backLink = "bg-t1-text text-t1-bg px-4 py-7 text-[17px] leading-6 text-center tracking-[5px] uppercase font-bold";

/**
 * /pay/done?e=<event>&s=<session> (or &cancelled=1): where Stripe's checkout returns. The return proves nothing, so
 * this reads the payment (every 2 s for up to 20 s while it's on its way) and says Paid / Not paid yet / Cancelled.
 * Back to the event is a link to the player's event, which opens the app on a phone that has it.
 */
export function PayDone() {
  const params = new URLSearchParams(window.location.search);
  const eventId = params.get("e");
  const cancelled = params.get("cancelled") === "1";
  const { session, ready } = useSession();
  const signedIn = !!session || leaguesDemoOn();
  const [m, setM] = useState<EventMoney | null>(null);
  const [read, setRead] = useState(false);
  const [tries, setTries] = useState(0);

  useEffect(() => {
    if (!ready || !eventId) return;
    let live = true;
    void eventMoney(eventId).then((r) => {
      if (!live) return;
      setM(r);
      setRead(true);
    });
    return () => { live = false; };
  }, [ready, eventId, tries]);

  const state = payDoneState(cancelled, m);
  // Still on its way: look again, up to ten times.
  useEffect(() => {
    if (!read || cancelled || state === "paid" || !m?.me || tries >= PENDING_POLL_TRIES) return;
    const id = window.setTimeout(() => setTries((n) => n + 1), PENDING_POLL_MS);
    return () => window.clearTimeout(id);
  }, [read, cancelled, state, m, tries]);

  const counted = useState({ done: false })[0];
  useEffect(() => {
    if (!read || counted.done || (state === "pending" && tries < PENDING_POLL_TRIES && !!m?.me)) return;
    counted.done = true;
    capture("pay_returned", { status: state });
  }, [read, state, tries, m, counted]);

  const waiting = !read || (state === "pending" && tries < PENDING_POLL_TRIES);
  // Signed out here (the app opened Stripe in its own browser tab): this page can't see the payment; the app can.
  const blind = read && !m?.me && !cancelled;
  const title = !read ? "…" : blind ? "Back to the event" : waiting ? "Finishing your payment…" : PAY_DONE_TITLE[state];
  const detail = blind ? (signedIn ? "This account isn't signed up to that event." : "Your payment shows on the event once Stripe confirms it.")
    : state === "paid" && m?.fee ? `${money(m.me?.amount_cents || m.fee.amount_cents)} · thank you`
    : state === "cancelled" ? "Nothing was charged."
    : !waiting && state !== "paid" ? "If you paid, it shows on the event within a minute." : null;
  return (
    <PayPage label="Entry fee" title={title} accent={state === "paid"} detail={detail}>
      <div className="flex-1" />
      <Link to={eventId ? demoPath(`/p/${eventId}`) : "/"} className={backLink}>Back to the event</Link>
    </PayPage>
  );
}

/**
 * /pay/connected and /pay/connect: where Stripe's onboarding returns (and where it sends an expired link). Reaching
 * it proves nothing either: signed in on the web, this asks Stripe how the account stands and offers Connect again.
 */
export function PayConnected({ expired = false }: { expired?: boolean }) {
  const { session, ready } = useSession();
  const signedIn = !!session || leaguesDemoOn();
  const [account, setAccount] = useState<StripeAccount | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!ready || !signedIn) return;
    let live = true;
    connectStatus().then((a) => live && setAccount(a), (e) => live && setError(paymentsMessage(e)));
    return () => { live = false; };
  }, [ready, signedIn]);

  async function again() {
    setBusy(true);
    setError(null);
    try {
      window.location.assign(await connectStart());
    } catch (e) {
      setError(paymentsMessage(e));
      setBusy(false);
    }
  }

  const title = account ? stripeLine(account) : expired ? "That link ran out" : signedIn && !error ? "…" : "Back to Table 1";
  return (
    <PayPage label="Stripe" title={title} accent={!!account?.ready}
             detail={account?.ready ? "Entry fees go straight to your Stripe account." : !signedIn ? "Open Table 1 to see where your account stands." : null}>
      {error && <Notice tone={error === paymentsMessage(new PaymentsError("", 503)) ? "info" : "error"}>{error}</Notice>}
      <div className="flex-1" />
      {signedIn && account && !account.ready && (
        <BigAction label="Connect again" tone="accent" busy={busy} onClick={() => void again()} />
      )}
      {signedIn && !account && expired && !error && <BigAction label="Connect again" tone="accent" busy={busy} onClick={() => void again()} />}
      <Link to={demoPath("/me?payments")} className={backLink}>Back to Table 1</Link>
    </PayPage>
  );
}
