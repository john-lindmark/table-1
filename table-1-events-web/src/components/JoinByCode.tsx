import { useState } from "react";
import { parseJoinCode, type JoinCode } from "../lib/limitedCards";
import { capture } from "../lib/telemetry";

const target = (j: JoinCode) => (j.kind === "qr" ? `/j/${j.code}?s=${encodeURIComponent(j.secret)}` : `/join/${j.code}`);

/** An event code from the organizer opens the join screen (guests need no account). Paste reads a code, a join link or
 *  the QR's link out of what was copied (contract/qr-sign-up-2026-10-23.md § Enter or paste a code), as does pasting a
 *  message into the field. */
export function JoinByCode() {
  const [code, setCode] = useState("");
  const [qr, setQr] = useState<JoinCode | null>(null);
  const [error, setError] = useState<string | null>(null);
  const canRead = typeof navigator !== "undefined" && !!navigator.clipboard?.readText;
  const go = (j: JoinCode) => { window.location.href = target(j); };
  const take = (text: string, via: string): JoinCode | null => {
    const found = parseJoinCode(text);
    capture("join_code_pasted", { via, found: !!found });
    if (!found) { setError("That has no event code in it."); return null; }
    setError(null);
    setCode(found.code);
    setQr(found.kind === "qr" ? found : null);
    return found;
  };
  const paste = async () => {
    try {
      const found = take(await navigator.clipboard.readText(), "paste");
      if (found) go(found);
    } catch {
      setError("This browser didn't let Table 1 read what you copied. Paste it into the box instead.");
    }
  };
  return (
    <div className="flex flex-col gap-px">
      <div className="flex gap-px">
        <input
          value={code}
          onChange={(e) => { setError(null); setQr(null); setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 4)); }}
          onPaste={(e) => {
            const text = e.clipboardData.getData("text");
            if (text.trim().length <= 4) return;   // a bare code goes in as typed
            e.preventDefault();
            take(text, "field");
          }}
          onKeyDown={(e) => { if (e.key === "Enter" && code.length === 4) go(qr ?? { kind: "code", code }); }}
          placeholder="EVENT CODE"
          aria-label="Event code"
          className="flex-1 min-w-0 bg-t1-surface px-4 py-4 outline-0 border-0 text-[16px] tracking-[4px] placeholder:text-t1-muted/60 uppercase"
        />
        {canRead && !code && (
          <button type="button" onClick={() => void paste()} className="bg-t1-surface hover:bg-t1-surface-hover px-5 text-[11px] uppercase tracking-[1px]">
            Paste
          </button>
        )}
        <button
          type="button"
          disabled={code.length !== 4}
          onClick={() => go(qr ?? { kind: "code", code })}
          className="bg-t1-text text-t1-bg px-6 text-[11px] uppercase tracking-[1px] disabled:bg-t1-disabled disabled:text-t1-ink"
        >
          Join
        </button>
      </div>
      {error && <div className="bg-t1-surface px-4 py-3 text-[12px] text-t1-danger">{error}</div>}
    </div>
  );
}
