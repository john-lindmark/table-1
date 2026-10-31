import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Bar, Dialog, Notice, Row, Screen, Section } from "../components/kit";
import { errorMessage } from "../lib/api";
import {
  fetchShared, linkFor, linkUrl, loadSharing, makeLink, profilePartUrl, shareConfirm, shareWhat, stopLink, targetReach, targetTitle,
  useFriends, VIS_LABEL, type SharedLinkData, type ShareTarget,
} from "../lib/friends";
import { capture } from "../lib/telemetry";
import { useLibrarySession } from "./Library";
import { ProfileCardsBody, useFriendsReady } from "./Friends";

/* Share (contract/share-links-2026-10-23.md): every part of the Library gets a Share screen with "Anyone with the
   link" (a link that works signed out, for that part only) and who sees it on Table 1. /l/<token> is the page a link
   opens, signed in or out. */

/** Telemetry `from`: where Share was opened. */
type From = "all_cards" | "wants" | "binders" | "binder" | "deck" | "cube";

/** The Share row on a screen; it opens the Share screen over it. */
export function ShareRow({ target, from, onExport, onImage }: {
  target: ShareTarget; from: From; onExport?: () => void; onImage?: () => void;
}) {
  const [open, setOpen] = useState(false);
  const s = useFriends();
  const { ready } = useFriendsReady();
  useEffect(() => { if (ready && !s.sharing) void loadSharing(); }, [ready, s.sharing]);
  const on = !!linkFor(s.sharing, target);
  return (<>
    <Row title={target.part === "for_trade" ? "Share For trade" : "Share"} detail="Link, or who sees it on Table 1" value={on ? "Link on" : undefined}
         accentValue={on} onClick={() => { capture("share_opened", { part: target.part, from }); setOpen(true); }} />
    {open && <ShareScreen target={target} onClose={() => setOpen(false)}
                          onExport={onExport && (() => { setOpen(false); onExport(); })} onImage={onImage && (() => { setOpen(false); onImage(); })} />}
  </>);
}

/** A bar button for screens whose rows are cards (All cards). */
export function ShareButton({ target, from }: { target: ShareTarget; from: From }) {
  const [open, setOpen] = useState(false);
  return (<>
    <button type="button" onClick={() => { capture("share_opened", { part: target.part, from }); setOpen(true); }}
            className="t1-label hover:text-t1-text px-2 py-1 -my-1">Share</button>
    {open && <ShareScreen target={target} onClose={() => setOpen(false)} />}
  </>);
}

async function sendUrl(url: string): Promise<"share" | "copy"> {
  if (navigator.share && matchMedia("(pointer: coarse)").matches) {
    await navigator.share({ url });
    return "share";
  }
  await navigator.clipboard.writeText(url);
  return "copy";
}

export function ShareScreen({ target, onClose, onExport, onImage }: {
  target: ShareTarget; onClose: () => void; onExport?: () => void; onImage?: () => void;
}) {
  const s = useFriends();
  const navigate = useNavigate();
  const { userId } = useLibrarySession();
  const [ask, setAsk] = useState<"make" | "new" | "stop" | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const { ready } = useFriendsReady();
  useEffect(() => { if (ready && !s.sharing) void loadSharing(); }, [ready, s.sharing]);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && !ask && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose, ask]);
  const link = linkFor(s.sharing, target);
  const title = targetTitle(target);
  const reachNow = s.sharing ? targetReach(s.sharing, target) : null;

  const run = async (work: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await work();
      setError(null);
      setNote(null);
      setAsk(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  const send = async (url: string, event: string) => {
    try {
      const how = await sendUrl(url);
      if (how === "copy") setNote("Copied");
      capture(event, event === "share_link_sent" ? { part: target.part, how } : { part: target.part });
    } catch (e) {
      if ((e as Error).name !== "AbortError") setError("Couldn't share here. Copy the address instead.");
    }
  };
  const copy = async (url: string) => {
    try {
      await navigator.clipboard.writeText(url);
      setNote("Copied");
      capture("share_link_sent", { part: target.part, how: "copy" });
    } catch {
      setError("Couldn't copy here. Select the address and copy it.");
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px overflow-y-auto" role="dialog" aria-modal="true" aria-label={`Share ${title}`}>
      <div className="w-full max-w-[960px] mx-auto flex flex-col gap-px">
        <Bar title="Share" subtitle={title} onBack={onClose} />
        {error && <Notice tone="error">{error}</Notice>}
        <Section title="Anyone with the link" />
        {link ? (<>
          <Notice tone="info">Anyone with this link sees {shareWhat(target.part)}, even without a Table 1 account. Nothing else on your profile shows.</Notice>
          <Row title={<span className="select-all break-all">{linkUrl(link.token).replace("https://", "")}</span>} detail={note ?? "Link on"} />
          <Row title="Share link" onClick={() => void send(linkUrl(link.token), "share_link_sent")} />
          <Row title="Copy link" onClick={() => void copy(linkUrl(link.token))} />
          <Row title="New link" onClick={busy ? undefined : () => setAsk("new")} />
          <Row title="Stop sharing link" value={<span className="text-t1-danger">Off</span>} onClick={busy ? undefined : () => setAsk("stop")} />
        </>) : (
          <Row title={busy ? "Making a link…" : "Make a link"} detail="Works without an account"
               onClick={busy || !s.sharing ? undefined : () => setAsk("make")} />
        )}
        <Section title="On Table 1" />
        {s.sharing && reachNow ? (<>
          <Row title="Who sees this" detail="Change it in Sharing" value={VIS_LABEL[reachNow] === "Public" ? "Anyone" : VIS_LABEL[reachNow]}
               accentValue={reachNow !== "private"} onClick={() => { onClose(); navigate("/sharing"); }} />
          {reachNow === "private" ? <Notice tone="info">Only you see it on Table 1. A link works without changing that.</Notice>
            : userId && <Row title="Send profile link" detail={`Only ${reachNow === "friends" ? "friends" : "anyone on Table 1"} can open it`}
                             onClick={() => void send(profilePartUrl(userId, target), "share_profile_link_sent")} />}
        </>) : <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {(onExport || onImage) && <Section title="As a copy" />}
        {onExport && <Row title="Export" detail={target.part === "deck" ? "Text, Arena, MTGO, download or copy" : "Text, Cube Cobra, download or copy"} onClick={onExport} />}
        {onImage && <Row title="Deck image" detail="The cards as a picture, to save or share" onClick={onImage} />}
      </div>
      {ask === "make" && (
        <Dialog title={`Make a link to ${title}?`} message={shareConfirm(target.part)} cancelLabel="Cancel" confirmLabel="Make link" busyLabel="Making…"
                busy={busy} error={error} onCancel={() => setAsk(null)} onConfirm={() => void run(() => makeLink(target))} />
      )}
      {ask === "new" && (
        <Dialog title="Make a new link?" message="The old link stops working for anyone who has it." cancelLabel="Cancel" confirmLabel="New link"
                busy={busy} error={error} onCancel={() => setAsk(null)} onConfirm={() => void run(() => makeLink(target, true))} />
      )}
      {ask === "stop" && (
        <Dialog title="Stop sharing the link?" message="It stops working for anyone who has it. Who sees this on Table 1 doesn't change." tone="danger"
                cancelLabel="Cancel" confirmLabel="Stop sharing" busy={busy} error={error} onCancel={() => setAsk(null)}
                onConfirm={() => void run(() => stopLink(target))} />
      )}
    </div>
  );
}

/** /l/<token>: what a link shows, signed in or out. */
export function SharedLinkScreen({ token, onBack, onCard, onList, onSignIn, onFollowChanges, onRankings }: {
  token: string; onBack: () => void; onCard: (oracleId: string) => void; onList: (listId: string) => void; onSignIn: () => void;
  onFollowChanges?: (kind: "binder" | "deck" | "cube", id: string) => void; onRankings?: (listId: string) => void;
}) {
  const { session, ready } = useLibrarySession();
  // The dev demo's friends (and Mara's linked deck) are built once the demo Library is in.
  const friends = useFriendsReady();
  const [data, setData] = useState<SharedLinkData | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!ready || !friends.ready) return;
    let live = true;
    fetchShared(token).then((d) => {
      if (!live) return;
      capture("shared_link_opened", { part: d.part, signed_in: !!session, mine: d.mine });
      setData(d);
    }, (e) => live && setError(errorMessage(e)));
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token, ready, friends.ready]);
  if (!data) {
    return (
      <Screen>
        <Bar title="Shared" onBack={onBack} />
        {error ? (<>
          <Notice tone="error">{/isn.t available|42501|private/i.test(error) ? "This isn't available." : error}</Notice>
          <Notice tone="info">The link may have been turned off.</Notice>
        </>) : <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
      </Screen>
    );
  }
  // Signed out, a card's page would only ask to sign in.
  return <ProfileCardsBody userId="" section={data.part} item={data.id ?? null} onBack={onBack} onCard={session ? onCard : () => {}} onList={onList}
                           onFollowChanges={onFollowChanges} onRankings={session ? onRankings : undefined}
                           link={{ token, data, signedIn: !!session, onSignIn }} />;
}
