import { useState } from "react";
import { bareAddress, displayPath } from "../lib/display";
import { capture } from "../lib/telemetry";
import { useQr } from "../lib/useQr";
import { GhostAction, Modal } from "./kit";

/**
 * The organizer's Display entry (contract/public-events-leagues-2026-11-13.md § 5): the address of the event's TV
 * display, a QR code of it (to open it on the computer by the TV), Copy link and Open here (a new tab to cast or
 * drag onto the projector).
 */
export function DisplayPanel({ eventId, onClose }: { eventId: string; onClose: () => void }) {
  const url = `${window.location.origin}${displayPath(eventId)}`;
  const qr = useQr(url);
  const [copied, setCopied] = useState(false);

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
      </div>
      <GhostAction label="Done" onClick={onClose} />
    </Modal>
  );
}
