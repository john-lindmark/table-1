import { useEffect, useState } from "react";
import QRCode from "qrcode";

/** Joining has to be a scan and a name — nothing installs, nothing signs up. */
export function SharePanel({ shortCode, eventId }: { shortCode: string; eventId: string }) {
  const joinUrl = `${window.location.origin}/join/${shortCode}`;
  const standingsUrl = `${window.location.origin}/s/${eventId}`;
  const [qr, setQr] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => {
    QRCode.toDataURL(joinUrl, {
      margin: 1,
      width: 480,
      color: { dark: "#171725", light: "#ffffff" },
    })
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
          onClick={() => copy("standings", standingsUrl)}
          className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]"
        >
          {copied === "standings" ? "Copied" : "Copy standings link"}
        </button>
      </div>
    </div>
  );
}
