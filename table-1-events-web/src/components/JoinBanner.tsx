import { useEffect, useState } from "react";
import { fetchJoinHeader } from "../lib/api";
import type { JoinHeader } from "../lib/joinPreview";
import { capture } from "../lib/telemetry";

/**
 * A scanned join QR waiting on sign-in: which event it is, and that any way in (a new account too) takes the seat.
 * `naming`: on the name step, after sign-in.
 */
export function JoinBanner({ code, naming = false }: { code: string; naming?: boolean }) {
  const [header, setHeader] = useState<JoinHeader | null>(null);

  useEffect(() => {
    let live = true;
    fetchJoinHeader(code).then((h) => {
      if (!live) return;
      setHeader(h);
      if (!naming) capture("join_prompt_viewed", { event: h !== null });
    });
    return () => {
      live = false;
    };
  }, [code, naming]);

  return (
    <div className="bg-t1-surface px-4 py-4 flex flex-col gap-1.5">
      <span className="t1-label">Joining</span>
      <p className="text-[17px] font-bold">{header?.title ?? `Event ${code.toUpperCase()}`}</p>
      {header && <p className="text-[12px] text-t1-muted">{header.facts}</p>}
      <p className="text-[12px] text-t1-muted leading-relaxed pt-1">
        {naming
          ? "Add your name and you're in."
          : "New to Table 1? Any option below makes your account. You're seated as soon as you're in."}
      </p>
    </div>
  );
}
