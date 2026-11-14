import { useEffect, useState } from "react";
import { bareAddress, displayPath, type DisplayShow } from "../lib/display";
import { MESSAGE_MAX, SHOW_LABELS, eventDisplaySet, messageCount, type EventRoom } from "../lib/room";
import { capture } from "../lib/telemetry";
import { useQr } from "../lib/useQr";
import { GhostAction, Modal, Notice, Segmented } from "./kit";

/**
 * The organizer's Display entry (contract/public-events-leagues-2026-11-13.md § 5): the address of the event's TV
 * display, a QR code of it (to open it on the computer by the TV), Copy link and Open here (a new tab to cast or
 * drag onto the projector). With the room tools live (contract/room-tools-2026-11-13.md § 1) it is also the display's
 * remote: Showing (Auto | Clock | Pairings | Standings) and an Announcement along the bottom of every view.
 */
export function DisplayPanel({ eventId, onClose, room = null, onChanged }: {
  eventId: string; onClose: () => void;
  /** The room as last read; null while the server has no room tools (the remote then doesn't draw). */
  room?: EventRoom | null; onChanged?: () => void;
}) {
  const url = `${window.location.origin}${displayPath(eventId)}`;
  const qr = useQr(url);
  const [copied, setCopied] = useState(false);
  const [show, setShow] = useState<DisplayShow>(room?.display.show ?? "auto");
  const [text, setText] = useState(room?.display.message ?? "");
  const [shown, setShown] = useState(room?.display.message ?? null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const live = !!room;
  // The room arriving after the panel opened fills the remote in once.
  useEffect(() => {
    if (!room) return;
    setShow(room.display.show);
    setShown(room.display.message);
    setText((t) => t || room.display.message || "");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [live]);

  async function send(patch: { show?: DisplayShow; message?: string | null }) {
    setBusy(true);
    setError(null);
    try {
      const r = await eventDisplaySet(eventId.replace(/\?.*$/, ""), patch);
      setShow(r.show);
      setShown(r.message);
      if ("message" in patch && !r.message) setText("");
      onChanged?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : String((e as { message?: unknown } | null)?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(url);
      capture("display_link", { how: "copy" });
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch {
      setCopied(false);
    }
  }

  return (
    <Modal title="Display" onClose={onClose}>
      <div className="flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-4">
          <div className="size-[180px] bg-white p-2">{qr && <img src={qr} alt="The display's address" className="size-full" />}</div>
          <p className="text-[12px] leading-[18px] break-all text-center select-all">{bareAddress(url)}</p>
        </div>
        <div className="flex gap-px">
          <button type="button" onClick={() => void copy()}
                  className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]">
            {copied ? "Copied" : "Copy link"}
          </button>
          <a href={url} target="_blank" rel="noopener" onClick={() => capture("display_link", { how: "open" })}
             className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px] text-center">
            Open here
          </a>
        </div>
        {live && (
          <>
            <Segmented label="Showing" value={show} options={SHOW_LABELS} onChange={(v) => { setShow(v); void send({ show: v }); }} />
            <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
              <span className="flex items-center justify-between t1-label">
                <span>Announcement{shown ? " · showing" : ""}</span>
                <span className="tabular-nums">{messageCount(text)}</span>
              </span>
              <input value={text} maxLength={MESSAGE_MAX} placeholder="A line along the bottom of the display" aria-label="Announcement"
                     onChange={(e) => setText(e.target.value)}
                     onKeyDown={(e) => { if (e.key === "Enter" && text.trim()) void send({ message: text.trim() }); }}
                     className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full" />
            </label>
            <div className="flex gap-px">
              <GhostAction label="Clear" disabled={busy || !shown} onClick={() => void send({ message: null })} />
              <button type="button" disabled={busy || !text.trim() || text.trim() === shown} onClick={() => void send({ message: text.trim() })}
                      className="flex-1 bg-t1-text text-t1-bg disabled:bg-t1-disabled disabled:text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px]">
                Show
              </button>
            </div>
            {error && <Notice tone="error">{error}</Notice>}
          </>
        )}
      </div>
      <GhostAction label="Done" onClick={onClose} />
    </Modal>
  );
}
