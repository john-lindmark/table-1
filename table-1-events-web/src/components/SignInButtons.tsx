import { useState } from "react";
import { signInWith, type OAuthProvider, errorMessage } from "../lib/api";
import { Notice } from "./kit";

/** Apple and Google only. Both come straight back to the page that asked. */
export function SignInButtons({ returnTo }: { returnTo?: string }) {
  const [busy, setBusy] = useState<OAuthProvider | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function go(provider: OAuthProvider) {
    setBusy(provider);
    setError(null);
    try {
      await signInWith(provider, returnTo ?? window.location.href);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(null);
    }
  }

  return (
    <div className="flex flex-col gap-px">
      <button
        type="button"
        onClick={() => go("apple")}
        disabled={busy !== null}
        className="w-full bg-t1-text text-t1-bg px-4 py-5 text-[13px] uppercase tracking-[3px] font-bold disabled:bg-t1-disabled disabled:text-t1-ink"
      >
        {busy === "apple" ? "Opening Apple…" : "Continue with Apple"}
      </button>
      <button
        type="button"
        onClick={() => go("google")}
        disabled={busy !== null}
        className="w-full bg-t1-accent text-t1-ink px-4 py-5 text-[13px] uppercase tracking-[3px] font-bold disabled:bg-t1-disabled disabled:text-t1-ink"
      >
        {busy === "google" ? "Opening Google…" : "Continue with Google"}
      </button>
      {error && <Notice tone="error">{error}</Notice>}
    </div>
  );
}
