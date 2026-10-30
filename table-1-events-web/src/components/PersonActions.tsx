import { useEffect, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { BigAction, Bar, Dialog, Menu, Notice, Row, Section, SwitchRow, type MenuItem } from "./kit";
import { errorMessage } from "../lib/api";
import {
  BLOCK_MESSAGE, PART_LABEL, REPORT_NOTE_MAX, REPORT_REASONS, REPORT_THANKS, VIS_LABEL, VISIBILITIES, blockUser, capped, effective,
  effectiveItem, groupOf, loadSharing, reach, removeFriend, reportBlocksByDefault, reportUser, respondFriend, setAll, setItem, shareItemOf,
  answerOffer, offerDue, setOfferDue, subscribeOfferDue, useFriends, widening, wideningEmpty, wideningMessage, wideningTitle, withItem, type ReportContext, type ReportFrom,
  type ReportReason, type ShareItem, type SharePart, type SharingOffer, type Visibility, type Widening,
} from "../lib/friends";
import { capture, screen as captureScreen } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/* Wherever a person appears (contract/friends-sharing-2026-10-18.md § UX rules 6): profile (More), friend, request and
   sent rows, Add a friend results, trade-match rows and the trade-match screen. A long press or right-click on a row,
   or More, opens the same menu: Unfriend / Cancel request / Ignore, Block (or Unblock), Report. Same as iOS
   PersonActions and Android PersonActions.kt. Also the widening confirm (§ 4), Who sees this (§ 2) and the once-only
   offers (§ 8). */

/** Who the menu is for. `relation`: friend / requested / incoming / blocked / none / self. */
export interface PersonRef { userId: string; displayName: string; relation: string }

/** Long press (touch) or right-click (mouse) on a row. Spread the handlers on the row's wrapper. */
export function useLongPress(onLong: () => void) {
  const timer = useRef<number | null>(null);
  const fired = useRef(false);
  const clear = () => { if (timer.current != null) window.clearTimeout(timer.current); timer.current = null; };
  return {
    onContextMenu: (e: React.MouseEvent) => { e.preventDefault(); clear(); onLong(); },
    onPointerDown: (e: React.PointerEvent) => {
      if (e.pointerType === "mouse") return;
      fired.current = false;
      clear();
      timer.current = window.setTimeout(() => { fired.current = true; onLong(); }, 500);
    },
    onPointerUp: clear,
    onPointerLeave: clear,
    onPointerCancel: clear,
    /** A click that ends a long press isn't a tap. */
    onClickCapture: (e: React.MouseEvent) => { if (fired.current) { e.stopPropagation(); e.preventDefault(); fired.current = false; } },
  };
}

/** A row that opens the person menu on a long press or right-click. */
export function PersonRow({ person, onMenu, children }: { person: PersonRef; onMenu: (p: PersonRef) => void; children: ReactNode }) {
  const press = useLongPress(() => onMenu(person));
  return <div {...press} className="flex flex-col">{children}</div>;
}

/**
 * The person menu, its confirms and the Report panel. Shown while `person` isn't null; `from` is the report context;
 * `changed` runs after anything that changes the relation.
 */
export function PersonMenu({ person, from, item, onClose, changed }: {
  person: PersonRef | null; from: ReportFrom; item?: { kind: "binder" | "deck" | "cube"; id: string; name: string };
  onClose: () => void; changed?: () => void;
}) {
  const [confirm, setConfirm] = useState<"unfriend" | "block" | null>(null);
  const [reporting, setReporting] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [menuOpen, setMenuOpen] = useState(true);
  useEffect(() => { setConfirm(null); setReporting(false); setError(null); setMenuOpen(true); }, [person?.userId]);
  // The Menu closes itself before running a pick; close the whole thing only when the pick led nowhere further.
  useEffect(() => {
    if (person && !menuOpen && !confirm && !reporting && !busy && !error) onClose();
  }, [person, menuOpen, confirm, reporting, busy, error, onClose]);
  if (!person) return null;
  const p = person;
  const done = () => { setConfirm(null); setReporting(false); onClose(); };
  const run = (work: () => Promise<unknown>) => {
    setBusy(true);
    work().then(() => { changed?.(); done(); }, (e) => setError(errorMessage(e))).finally(() => setBusy(false));
  };
  const items: MenuItem[] = [
    ...(p.relation === "friend" ? [{ title: "Unfriend", onClick: () => setConfirm("unfriend") }] : []),
    ...(p.relation === "requested" ? [{ title: "Cancel request", onClick: () => run(() => removeFriend(p.userId)) }] : []),
    ...(p.relation === "incoming" ? [{ title: "Ignore request", onClick: () => run(() => respondFriend(p.userId, false)) }] : []),
    ...(p.relation === "blocked" ? [{ title: "Unblock", onClick: () => run(() => blockUser(p.userId, false)) }]
      : p.relation !== "self" ? [{ title: "Block", detail: "They can't find you or ask you", onClick: () => setConfirm("block") }] : []),
    ...(p.relation !== "self" ? [{ title: "Report", detail: "They won't know", onClick: () => setReporting(true) }] : []),
  ];
  if (reporting) return <ReportPanel person={p} context={{ from, ...(item ? { kind: item.kind, id: item.id } : {}) }} itemName={item?.name} onClose={done} changed={changed} />;
  if (confirm) {
    return (
      <Dialog title={confirm === "block" ? `Block ${p.displayName}?` : `Unfriend ${p.displayName}?`} tone="danger" cancelLabel="Cancel"
              confirmLabel={confirm === "block" ? "Block" : "Unfriend"} busy={busy} error={error}
              message={confirm === "block" ? BLOCK_MESSAGE : "You'll stop seeing what each of you shares with friends. They aren't told."}
              onCancel={done} onConfirm={() => run(() => (confirm === "block" ? blockUser(p.userId, true) : removeFriend(p.userId)))} />
    );
  }
  if (error) return <Dialog title="Couldn't do that" message={error} cancelLabel="Close" confirmLabel="OK" onCancel={done} onConfirm={done} />;
  return menuOpen ? <Menu title={p.displayName} items={items} onClose={() => setMenuOpen(false)} /> : null;
}

/** Report an account: a reason, an optional note, and Also block them (on for Harassment). */
export function ReportPanel({ person, context, itemName, onClose, changed }: {
  person: PersonRef; context: ReportContext; itemName?: string; onClose: () => void; changed?: () => void;
}) {
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [note, setNote] = useState("");
  const [block, setBlock] = useState(false);
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => captureScreen("report"), []);
  const send = async () => {
    if (!reason) return;
    setBusy(true);
    try {
      await reportUser(person.userId, reason, note, context, block);
      setSent(true);
      setError(null);
      changed?.();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col" role="dialog" aria-modal="true" aria-label={`Report ${person.displayName}`}>
      <div className="flex-1 min-h-0 flex flex-col w-full max-w-[640px] mx-auto">
        <Bar title={`Report ${person.displayName}`} subtitle={itemName ?? "They won't know you reported them"}
             right={<button type="button" onClick={onClose} className="t1-label hover:text-t1-text px-2 py-1 -my-1">{sent ? "Done" : "Cancel"}</button>} />
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          {error && <Notice tone="error">{error}</Notice>}
          {sent ? (<>
            <Notice tone="info">{REPORT_THANKS}</Notice>
            {block && <Notice tone="info">You blocked {person.displayName}. Unblock them any time in Friends.</Notice>}
          </>) : (<>
            <Section title="What's wrong" />
            {REPORT_REASONS.map((r) => (
              <Row key={r.value} title={r.label} value={reason === r.value ? "Picked" : undefined} accentValue
                   onClick={() => { setReason(r.value); setBlock(reportBlocksByDefault(r.value)); }} />
            ))}
            <Section title="Anything else · optional" />
            <textarea value={note} onChange={(e) => setNote(e.target.value.slice(0, REPORT_NOTE_MAX))} placeholder="What happened" rows={4}
                      className="bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60 resize-none" />
            <SwitchRow label="Also block them" detail="They can't find you or ask you" on={block} onChange={setBlock} />
          </>)}
        </div>
        {!sent && <BigAction label="Send report" tone="accent" busy={busy} disabled={!reason} onClick={() => void send()} />}
      </div>
    </div>
  );
}

/**
 * Asks before a sharing change that reaches more people (contract § UX rules 4); a change that only narrows applies at
 * once. `ask(w, apply)`; render `dialog`.
 */
export function useWideningConfirm(): { ask: (w: Widening, apply: () => void) => void; dialog: ReactNode } {
  const [pending, setPending] = useState<{ w: Widening; apply: () => void } | null>(null);
  const ask = (w: Widening, apply: () => void) => (wideningEmpty(w) ? apply() : setPending({ w, apply }));
  const done = (accepted: boolean) => {
    if (!pending) return;
    const { w, apply } = pending;
    setPending(null);
    capture("sharing_confirmed", { to: w.anyone.length ? "public" : "friends", parts: w.friends.length + w.anyone.length, accepted });
    if (accepted) apply();
  };
  const dialog = pending && (
    <Dialog title={wideningTitle(pending.w)} cancelLabel="Cancel" confirmLabel="Show" onCancel={() => done(false)} onConfirm={() => done(true)}
            message={<span className="whitespace-pre-line">{wideningMessage(pending.w)}</span>} />
  );
  return { ask, dialog };
}

/** The once-only "share with friends?" offers (contract § UX rules 8): the question is the confirm. */
export function SharingOfferDialog({ offer, userId, title, message, parts, onDone }: {
  offer: SharingOffer; userId: string | null; title: string; message: string; parts: SharePart[]; onDone: () => void;
}) {
  const answer = (yes: boolean) => {
    answerOffer(offer, userId, yes);
    onDone();
    if (yes) void setAll(parts, "friends");
  };
  return <Dialog title={title} message={message} cancelLabel="Not now" confirmLabel="Share with friends" onCancel={() => answer(false)} onConfirm={() => answer(true)} />;
}

/**
 * "Who sees this" at the top of a deck, cube or binder (contract § UX rules 2): the effective value, and a menu to
 * change it (Same as <group>, Private, Friends, Anyone), with the profile's cap when it applies.
 */
export function WhoSeesRow({ kind, id, name, forTrade }: { kind: ShareItem["kind"]; id: string; name: string; forTrade?: boolean }) {
  const st = useFriends();
  const [menu, setMenu] = useState(false);
  const { ask, dialog } = useWideningConfirm();
  useEffect(() => { if (!st.sharing) void loadSharing(); }, [st.sharing]);
  const s = st.sharing;
  if (!s) return null;
  const item = shareItemOf(s, kind, id, name, forTrade);
  const group = groupOf(kind);
  const eff = effectiveItem(s, item);
  const r = reach(s, eff);
  const effect = kind === "binder" ? "every card in this binder, with condition and language" : `every card in this ${kind}`;
  const detail = capped(s, eff) ? `Set to ${VIS_LABEL[eff]}, but only ${r === "friends" ? "friends see" : "you see"} it: your profile is ${VIS_LABEL[s.profile]}.`
    : item.visibility == null ? `Same as ${PART_LABEL[group]} · ${VIS_LABEL[eff]}`
    : r === "private" ? "Only you" : r === "friends" ? `Friends see ${effect}` : `Anyone on Table 1 sees ${effect}`;
  const pick = (v: Visibility | null) => ask(widening(s, withItem({ ...s, items: s.items.some((i) => i.id === id) ? s.items : [...s.items, item] }, item, v)),
                                               () => void setItem(item, v));
  return (
    <>
      <Row title="Who sees this" detail={detail} value={VIS_LABEL[r].toUpperCase()} accentValue={r !== "private"} onClick={() => setMenu(true)} />
      {menu && (
        <Menu title="Who sees this" onClose={() => setMenu(false)} items={[
          { title: `Same as ${PART_LABEL[group]} (${VIS_LABEL[effective(s, group)]})`, checked: item.visibility == null, onClick: () => pick(null) },
          ...VISIBILITIES.map((v) => ({ title: VIS_LABEL[v], checked: item.visibility === v, onClick: () => pick(v) })),
        ]} />
      )}
      {dialog}
    </>
  );
}

/** The offer an action elsewhere made due (marking a binder For trade); mounted once, over every screen. */
export function DueOffer() {
  const offer = useSyncExternalStore(subscribeOfferDue, offerDue);
  const { userId } = useSession();
  if (offer !== "for_trade") return null;
  return <SharingOfferDialog offer="for_trade" userId={userId} title="Share For trade with friends?" parts={["for_trade"]}
                             message="Friends can see these copies, and trade matches can find you." onDone={() => setOfferDue(null)} />;
}
