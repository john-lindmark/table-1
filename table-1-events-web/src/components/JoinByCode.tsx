import { useState } from "react";

/** An event code from the organizer opens the join screen (guests need no account). */
export function JoinByCode() {
  const [code, setCode] = useState("");
  return (
    <div className="flex gap-px">
      <input
        value={code}
        onChange={(e) => setCode(e.target.value.toUpperCase())}
        placeholder="EVENT CODE"
        maxLength={6}
        className="flex-1 min-w-0 bg-t1-surface px-4 py-4 outline-0 border-0 text-[16px] tracking-[4px] placeholder:text-t1-muted/60 uppercase"
      />
      <button
        disabled={code.trim().length < 4}
        onClick={() => (window.location.href = `/join/${code.trim()}`)}
        className="bg-t1-text text-t1-bg px-6 text-[11px] uppercase tracking-[1px] disabled:bg-t1-disabled disabled:text-t1-ink"
      >
        Join
      </button>
    </div>
  );
}
