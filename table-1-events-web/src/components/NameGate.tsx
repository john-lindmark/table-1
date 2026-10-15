import { useState, type ReactNode } from "react";
import { needsName, saveName } from "../lib/api";
import { supabase } from "../lib/supabaseClient";
import { useSession } from "../lib/useSession";
import { BigAction, GhostAction, Notice, Screen, T1Logo } from "./kit";

/** New email accounts add their first and last name (both required) before anything else opens. */
export function NameGate({ children }: { children: ReactNode }) {
  const { session } = useSession();
  const [done, setDone] = useState(false);
  if (!done && needsName(session?.user)) return <NameScreen userId={session!.user.id} onDone={() => setDone(true)} />;
  return <>{children}</>;
}

function NameScreen({ userId, onDone }: { userId: string; onDone: () => void }) {
  const [first, setFirst] = useState("");
  const [last, setLast] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const valid = first.trim().length > 0 && last.trim().length > 0;

  async function save() {
    if (!valid) return;
    setBusy(true);
    setError(null);
    try {
      await saveName(userId, first, last);
      onDone();
    } catch {
      setError("Couldn't save your name. Try again.");
      setBusy(false);
    }
  }

  const field = (label: string, value: string, set: (v: string) => void, autoComplete: string, autoFocus = false) => (
    <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
      <span className="t1-label">{label}</span>
      <input
        value={value}
        autoComplete={autoComplete}
        autoCapitalize="words"
        autoFocus={autoFocus}
        placeholder={label}
        maxLength={40}
        onChange={(e) => set(e.target.value)}
        className="bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full"
      />
    </label>
  );

  return (
    <Screen>
      <div className="flex-1 bg-t1-surface flex items-center justify-center pt-10 overflow-hidden">
        <T1Logo className="w-full max-w-[720px] h-auto" />
      </div>
      <form
        className="flex flex-col gap-px"
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
      >
        {error && <Notice tone="error">{error}</Notice>}
        <Notice tone="info">Add your name. Opponents and organizers see it on pairings and standings.</Notice>
        {field("First name", first, setFirst, "given-name", true)}
        {field("Last name", last, setLast, "family-name")}
        <div className="flex gap-px">
          <GhostAction label="Sign out" onClick={() => supabase.auth.signOut()} />
        </div>
        <BigAction label="Continue" tone="accent" busy={busy} disabled={!valid} onClick={save} />
        <button type="submit" hidden />
      </form>
    </Screen>
  );
}
