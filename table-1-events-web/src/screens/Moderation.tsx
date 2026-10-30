import { useEffect, useState } from "react";
import { BigAction, Bar, Dialog, GhostAction, Notice, Row, Screen, Section, Segmented } from "../components/kit";
import { errorMessage } from "../lib/api";
import {
  APPEAL_NOTE_MAX, appeal, categoryWord, moderationNow, loadModerationRows, loadNotices, loadQueue, markNoticesSeen, modDate, noticeStatus, photoUrls,
  resolveAppeal, resolveCheck, restrict, setMode, subjectWord, useModeration, waiting, whatChanged, type ModerationNotice,
} from "../lib/moderation";
import { capture, screen as captureScreen } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/** Signed out: one line instead of the server's refusal. */
function SignedOut({ title, onBack }: { title: string; onBack: () => void }) {
  return <Screen><Bar title={title} onBack={onBack} /><Notice tone="info">Sign in to see this.</Notice></Screen>;
}

/* Moderation screens (contract/moderation-2026-10-18.md): Account → From Table 1 (what changed on your content, why,
   and one appeal per change) and, for moderators, Account → Review (held content, appeals, flagged accounts). Same as
   iOS ModerationViews and Android ModerationScreens.kt. */

const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? "" : "s"}`;

/** Account rows: a restriction notice, From Table 1 when there are notices, Review for moderators. */
export function ModerationAccountRows({ onNotices, onReview }: { onNotices: () => void; onReview: () => void }) {
  const s = useModeration();
  useEffect(() => void loadModerationRows(), []);
  const until = modDate(s.me?.restricted_until);
  const unseen = s.me?.unseen ?? 0;
  return (
    <>
      {until && <Notice tone="error">You can't send friend requests until {until}. Your profile is hidden until then. Events aren't affected.</Notice>}
      {!!s.notices?.length && (
        <Row title="From Table 1" detail={unseen > 0 ? `${unseen} new · changes to your content` : "Changes to your content"}
             value={unseen > 0 ? `${unseen} new` : undefined} accentValue onClick={onNotices} />
      )}
      {s.me?.moderator && (
        <Row title="Review" detail={s.queue ? `${waiting(s.queue)} waiting · ${s.queue.mode === "shadow" ? "shadow mode" : "enforcing"}` : "Moderation queue"}
             onClick={onReview} />
      )}
    </>
  );
}

export function NoticesScreen({ onBack }: { onBack: () => void }) {
  const { session, ready } = useSession();
  if (ready && !session) return <SignedOut title="From Table 1" onBack={onBack} />;
  return <NoticesBody onBack={onBack} />;
}

function NoticesBody({ onBack }: { onBack: () => void }) {
  const s = useModeration();
  const [appealing, setAppealing] = useState<ModerationNotice | null>(null);
  useEffect(() => {
    captureScreen("moderation_notices");
    void loadNotices().then(() => {
      capture("moderation_notice_opened");
      return markNoticesSeen();
    });
  }, []);
  const n = s.notices;
  return (
    <Screen>
      <Bar title="From Table 1" subtitle="Changes to your content" onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {s.error && <Notice tone="error">{s.error}</Notice>}
        <Notice tone="info">
          Content other players see is checked automatically. When something breaks the rules, Table 1 makes the smallest change it can and tells
          you here. You can appeal each change once; a person reviews it.
        </Notice>
        {!n && !s.error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {n?.length === 0 && <Notice tone="info">Nothing here.</Notice>}
        {n?.map((x) => (
          <div key={x.id} className="flex flex-col gap-px">
            <Row title={x.label} detail={[whatChanged(x.action), modDate(x.at)].filter(Boolean).join(" · ")}
                 value={noticeStatus(x) || undefined} accentValue={x.appeal === "reverted"} />
            <Notice tone="info">{x.reason_text}{x.action === "unshare" && x.appeal !== "reverted" ? " Rename it to share it again." : ""}</Notice>
            {x.can_appeal && <div className="flex"><GhostAction label="Appeal" onClick={() => setAppealing(x)} /></div>}
          </div>
        ))}
      </div>
      {appealing && <AppealPanel notice={appealing} onClose={() => setAppealing(null)} />}
    </Screen>
  );
}

/** One appeal: an optional note, sent once. */
function AppealPanel({ notice, onClose }: { notice: ModerationNotice; onClose: () => void }) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const send = async () => {
    setBusy(true);
    try {
      await appeal(notice.id, note);
      onClose();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col" role="dialog" aria-modal="true" aria-label="Appeal">
      <div className="flex-1 min-h-0 flex flex-col w-full max-w-[640px] mx-auto">
        <Bar title="Appeal" subtitle={notice.label}
             right={<button type="button" onClick={onClose} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Cancel</button>} />
        <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
          {error && <Notice tone="error">{error}</Notice>}
          <Notice tone="info">Say why this should come back (optional). A person reads it. You can appeal once.</Notice>
          <textarea value={note} onChange={(e) => setNote(e.target.value.slice(0, APPEAL_NOTE_MAX))} placeholder="E.g. it's a card name" rows={4}
                    className="bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60 resize-none" />
        </div>
        <BigAction label="Send appeal" tone="accent" busy={busy} onClick={() => void send()} />
      </div>
    </div>
  );
}

/** Moderators: held content, appeals and flagged accounts. */
export function ReviewScreen({ onBack }: { onBack: () => void }) {
  const { session, ready } = useSession();
  if (ready && !session) return <SignedOut title="Review" onBack={onBack} />;
  return <ReviewBody onBack={onBack} />;
}

function ReviewBody({ onBack }: { onBack: () => void }) {
  const s = useModeration();
  const [photos, setPhotos] = useState<Record<string, string>>({});
  const [revealed, setRevealed] = useState<Set<string>>(new Set());
  const [ask, setAsk] = useState<{ title: string; message: string; go: () => void } | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    captureScreen("moderation_review");
    void loadQueue().then(async () => {
      const { queue } = moderationNow();
      if (!queue) return;
      const items = [...queue.checks, ...queue.appeals].flatMap((x) => (x.bucket && x.path ? [{ bucket: x.bucket, path: x.path }] : []));
      setPhotos(await photoUrls(items));
    });
  }, []);
  const run = (work: () => Promise<unknown>) => void work().catch((e) => setError(errorMessage(e)));
  const content = (text: string | null, path: string | null, childSafety: boolean) => {
    if (text != null) return <div className="bg-t1-surface px-4 py-3 text-[15px] break-words">{text}</div>;
    if (path == null) return null;
    if (childSafety) {
      return <Notice tone="error">Photo hidden and quarantined (child safety). US law requires a report to the NCMEC CyberTipline (report.cybertip.org). Don't download or share it.</Notice>;
    }
    const url = photos[path];
    if (!url) return <Notice tone="info">Photo: {path}</Notice>;
    const shown = revealed.has(path);
    // Blurred until clicked.
    return (
      <button type="button" onClick={() => setRevealed(new Set([...revealed, path]))}
              className="relative bg-t1-surface flex items-center justify-center max-h-[220px] overflow-hidden">
        <img src={url} alt="" className={`max-h-[220px] object-contain ${shown ? "" : "blur-xl"}`} />
        {!shown && <span className="absolute t1-label !text-t1-text">Click to show</span>}
      </button>
    );
  };
  const q = s.queue;
  return (
    <Screen>
      <Bar title="Review" subtitle={q ? `${waiting(q)} waiting` : undefined} onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {(error ?? s.error) && <Notice tone="error">{error ?? s.error}</Notice>}
        {!q && !(error ?? s.error) && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {q && (<>
          <Segmented options={[{ value: "shadow", label: "Shadow" }, { value: "enforce", label: "Enforce" }]} value={q.mode}
                     onChange={(m) => {
                       if (m === q.mode) return;
                       if (m === "enforce") {
                         setAsk({ title: "Start enforcing?", message: "Blocks will change players' content at once and tell them. Check a week of shadow verdicts first.",
                                  go: () => run(() => setMode("enforce")) });
                       } else run(() => setMode("shadow"));
                     }} />
          <Notice tone="info">
            {q.mode === "shadow"
              ? "Shadow mode: verdicts are recorded and held here; nothing changes for players except child-safety takedowns. Block applies your decision."
              : "Enforcing: blocks change content at once and the owner is told. Allow undoes it."}
          </Notice>
          <Section title="Held content" count={q.checks.length} />
          {!q.checks.length && <Notice tone="info">Nothing held.</Notice>}
          {q.checks.map((c) => (
            <div key={`c${c.id}`} className="flex flex-col gap-px">
              <Row title={`${subjectWord(c.subject_kind)} · ${categoryWord(c.category)}`}
                   detail={[c.owner?.display_name, c.strikes > 0 ? plural(c.strikes, "strike") : null, c.reports > 0 ? plural(c.reports, "report") : null,
                            c.source === "report" ? "reported" : null, c.enforced ? "already applied" : null].filter(Boolean).join(" · ")}
                   value={c.status === "block" ? "Block" : "Review"} />
              {content(c.text, c.path, c.category === "child_safety")}
              {c.reason && <Notice tone="info">Why: {c.reason}</Notice>}
              <div className="flex gap-px">
                <GhostAction label={c.enforced ? "Allow · undo" : "Allow"} onClick={() => run(() => resolveCheck(c, "allow"))} />
                <GhostAction label="Block" onClick={() => run(() => resolveCheck(c, "block"))} />
              </div>
            </div>
          ))}
          <Section title="Appeals" count={q.appeals.length} />
          {!q.appeals.length && <Notice tone="info">No appeals.</Notice>}
          {q.appeals.map((a) => (
            <div key={`a${a.id}`} className="flex flex-col gap-px">
              <Row title={a.label} detail={[a.owner?.display_name, categoryWord(a.category)].filter(Boolean).join(" · ")} />
              {content(a.text, a.path, a.category === "child_safety")}
              {a.note && <Notice tone="info">They say: {a.note}</Notice>}
              <div className="flex gap-px">
                <GhostAction label="Uphold" onClick={() => run(() => resolveAppeal(a, "uphold"))} />
                <GhostAction label="Revert" onClick={() => run(() => resolveAppeal(a, "revert"))} />
              </div>
            </div>
          ))}
          <Section title="Flagged accounts" count={q.flagged.length} />
          {!q.flagged.length && <Notice tone="info">No accounts with 3+ strikes or reporters.</Notice>}
          {q.flagged.map((f) => (
            <div key={`f${f.user_id}`} className="flex flex-col gap-px">
              <Row title={f.display_name}
                   detail={`${f.strikes} strikes in 90 days · ${f.reporters} reporters in 14 days${modDate(f.restricted_until) ? ` · restricted until ${modDate(f.restricted_until)}` : ""}`} />
              <div className="flex">
                {f.restricted_until
                  ? <GhostAction label="Lift restriction" onClick={() => run(() => restrict(f.user_id, 0, ""))} />
                  : <GhostAction label="Restrict 7 days" onClick={() => setAsk({
                      title: `Restrict ${f.display_name} for 7 days?`,
                      message: "They can't send friend requests and their profile is hidden. Events aren't affected. They're told.",
                      go: () => run(() => restrict(f.user_id, 7, "Repeated violations or reports")),
                    })} />}
              </div>
            </div>
          ))}
        </>)}
      </div>
      {ask && (
        <Dialog title={ask.title} message={ask.message} tone="danger" cancelLabel="Cancel" confirmLabel="Confirm"
                onCancel={() => setAsk(null)} onConfirm={() => { const go = ask.go; setAsk(null); go(); }} />
      )}
    </Screen>
  );
}
