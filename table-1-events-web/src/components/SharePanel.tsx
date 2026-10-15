import { useEffect, useState } from "react";
import { getJoinQr } from "../lib/api";

/**
 * The organizer's join QR. It encodes /j/<code>?s=<secret>: phones with the app open it
 * straight into a join (universal / app link), everyone else lands on the web join page.
 * "New code" rotates the secret so screenshots of the old QR stop working.
 */
export function SharePanel({ shortCode, eventId }: { shortCode: string; eventId: string }) {
  const [joinUrl, setJoinUrl] = useState(`${window.location.origin}/join/${shortCode}`);
  const [rotating, setRotating] = useState(false);

  useEffect(() => {
    getJoinQr(eventId)
      .then((q) => setJoinUrl(q.url))
      .catch(() => setJoinUrl(`${window.location.origin}/join/${shortCode}`));
  }, [eventId, shortCode]);

  async function rotate() {
    setRotating(true);
    try {
      setJoinUrl((await getJoinQr(eventId, true)).url);
    } finally {
      setRotating(false);
    }
  }
  const standingsUrl = `${window.location.origin}/s/${eventId}`;
  const [qr, setQr] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => {
    // The QR encoder loads only when an organizer opens sharing.
    import("qrcode").then(({ default: QRCode }) => QRCode.toDataURL(joinUrl, {
      margin: 1,
      width: 480,
      color: { dark: "#171725", light: "#ffffff" },
    }))
      .then(setQr)
      .catch(() => setQr(null));
  }, [joinUrl]);

  async function copy(label: string, url: string) {
    try {
      await navigator.clipboard.writeText(url);
      setCopied(label);
      window.setTimeout(() => setCopied(null), 1500);
    } catch {
      setCopied(null);
    }
  }

  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-4">
        {qr && <img src={qr} alt="Join code" className="size-[180px] bg-white p-2" />}
        <p className="text-[36px] tracking-[10px] tabular-nums">{shortCode}</p>
        <p className="t1-label text-center">Scan, or go to the site and enter this code</p>
      </div>
      <div className="flex gap-px">
        <button
          onClick={() => copy("join", joinUrl)}
          className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]"
        >
          {copied === "join" ? "Copied" : "Copy join link"}
        </button>
        <button
          onClick={rotate}
          disabled={rotating}
          className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]"
        >
          {rotating ? "Rotating…" : "New code"}
        </button>
        <button
          onClick={() => copy("standings", standingsUrl)}
          className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]"
        >
          {copied === "standings" ? "Copied" : "Copy standings link"}
        </button>
      </div>
    </div>
  );
}
