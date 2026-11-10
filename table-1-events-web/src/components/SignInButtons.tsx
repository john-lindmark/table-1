import { useEffect, useRef, useState } from "react";
import { signInWith, sendEmailCode, verifyEmailCode, type OAuthProvider, errorMessage } from "../lib/api";
import { BigAction, GhostAction, Notice } from "./kit";
import { capture } from "../lib/telemetry";
import { clearPending, loadPending, pendingAfterSend, savePending, sendOutcomeOf, type Pending } from "../lib/emailSignIn";

type Step = "providers" | "email" | "code";

/**
 * Apple, Google, Discord or email. OAuth comes straight back to the page that asked; email is two steps
 * (address, then the code), and the email's link signs in here or opens the app.
 */
export function SignInButtons({ returnTo }: { returnTo?: string }) {
  // Back on the page within the code's hour: the code step for the address a code just went to.
  const [restored] = useState(() => loadPending());
  const [busy, setBusy] = useState<OAuthProvider | "email" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [step, setStep] = useState<Step>(restored ? "code" : "providers");
  const [email, setEmail] = useState(restored?.email ?? "");
  const [code, setCode] = useState("");
  // Supabase sends at most one email a minute per address.
  const [resendAt, setResendAt] = useState(restored?.resendAt ?? 0);
  const [now, setNow] = useState(Date.now());
  // Send, Resend and the Enter key all land in send(); one at a time, even before `busy` re-renders.
  const sending = useRef(false);

  useEffect(() => {
    if (step !== "code") return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [step]);

  const address = email.trim().toLowerCase();
  const emailValid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address);
  const wait = Math.max(0, Math.ceil((resendAt - now) / 1000));

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

  function to(next: Step) {
    setError(null);
    setStep(next);
  }

  function codeSent(p: Pending) {
    savePending(p);
    setResendAt(p.resendAt);
    setNow(Date.now());
    setError(null);
    setStep("code");
  }

  async function send() {
    if (!emailValid || sending.current) return;
    sending.current = true;
    setBusy("email");
    setError(null);
    try {
      const back = returnTo ? new URL(returnTo, window.location.origin) : window.location;
      await sendEmailCode(address, back.pathname + back.search);
      codeSent(pendingAfterSend(address, Date.now()));
    } catch (e) {
      const outcome = sendOutcomeOf(e);
      if (outcome.kind === "already_sent") {
        // The minute per address: a code went out moments ago, so that's the step to be on.
        capture("sign_in_failed", { method: "email_send", reason: "already_sent" });
        codeSent(pendingAfterSend(address, Date.now(), outcome.wait));
      } else if (outcome.kind === "too_many") {
        capture("sign_in_failed", { method: "email_send", reason: "too_many" });
        setError("Too many sign-in emails right now. Wait a few minutes, or continue with Apple or Google.");
      } else {
        capture("sign_in_failed", { method: "email_send", reason: "error" });
        setError("Couldn't send the email. Check the address and try again.");
      }
    } finally {
      sending.current = false;
      setBusy(null);
    }
  }

  async function verify() {
    if (sending.current) return;
    setBusy("email");
    setError(null);
    try {
      await verifyEmailCode(address, code);
    } catch {
      setError("That code didn't work. Check it, or send a new one.");
      setBusy(null);
    }
  }

  const input =
    "bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60 w-full";

  if (step === "email") {
    return (
      <form
        className="flex flex-col gap-px"
        onSubmit={(e) => {
          e.preventDefault();
          send();
        }}
      >
        {error && <Notice tone="error">{error}</Notice>}
        <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
          <span className="t1-label">Email</span>
          <input
            type="email"
            autoComplete="email"
            autoFocus
            value={email}
            placeholder="name@example.com"
            onChange={(e) => setEmail(e.target.value)}
            className={input}
          />
        </label>
        <div className="flex gap-px">
          <GhostAction label="Back" onClick={() => to("providers")} />
        </div>
        <BigAction label="Send code" tone="accent" busy={busy === "email"} disabled={!emailValid} onClick={send} />
      </form>
    );
  }

  if (step === "code") {
    return (
      <form
        className="flex flex-col gap-px"
        onSubmit={(e) => {
          e.preventDefault();
          if (code.length >= 6) verify();
        }}
      >
        {error && <Notice tone="error">{error}</Notice>}
        <Notice tone="info">
          We sent a link and a code to {address}. Open the link, or enter the code here. Not there? Check spam.
        </Notice>
        <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
          <span className="t1-label">Code</span>
          <input
            inputMode="numeric"
            autoComplete="one-time-code"
            autoFocus
            value={code}
            placeholder="From the email"
            onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, 10))}
            className={`${input} tracking-[4px]`}
          />
        </label>
        <div className="flex gap-px">
          <GhostAction
            label="Change email"
            onClick={() => {
              setCode("");
              clearPending();
              to("email");
            }}
          />
          <GhostAction label={wait > 0 ? `Resend in ${wait}s` : "Resend"} disabled={wait > 0 || busy !== null} onClick={send} />
        </div>
        <BigAction label="Sign in" tone="accent" busy={busy === "email"} disabled={code.length < 6} onClick={verify} />
      </form>
    );
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
      <button
        type="button"
        onClick={() => go("discord")}
        disabled={busy !== null}
        className="w-full bg-t1-surface hover:bg-t1-surface-hover text-t1-text px-4 py-5 text-[13px] uppercase tracking-[3px] font-bold disabled:bg-t1-disabled disabled:text-t1-ink"
      >
        {busy === "discord" ? "Opening Discord…" : "Continue with Discord"}
      </button>
      <button
        type="button"
        onClick={() => to("email")}
        disabled={busy !== null}
        className="w-full bg-t1-surface hover:bg-t1-surface-hover text-t1-text px-4 py-5 text-[13px] uppercase tracking-[3px] font-bold disabled:bg-t1-disabled disabled:text-t1-ink"
      >
        Continue with email
      </button>
      <p className="bg-t1-surface px-4 py-3 t1-label">
        Continuing agrees to the{" "}
        <a href="/terms" target="_blank" rel="noreferrer" className="text-t1-text underline">Terms</a> and{" "}
        <a href="/privacy" target="_blank" rel="noreferrer" className="text-t1-text underline">Privacy policy</a>
      </p>
      {error && <Notice tone="error">{error}</Notice>}
    </div>
  );
}
