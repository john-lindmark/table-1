import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { errorMessage, verifyEmailLink } from "../lib/api";
import { Bar, Notice, Screen } from "../components/kit";
import { SignInButtons } from "../components/SignInButtons";

/**
 * The sign-in email's link when the app isn't installed (or on a computer):
 * /auth/confirm?token_hash=…&type=email. With the app installed, iOS and Android open it there instead.
 */
export function AuthConfirm() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);
  const started = useRef(false);
  const tokenHash = params.get("token_hash");

  useEffect(() => {
    // StrictMode runs effects twice in dev; the hash works once.
    if (started.current) return;
    started.current = true;
    if (!tokenHash) {
      setError("This sign-in link is incomplete. Send a new one.");
      return;
    }
    verifyEmailLink(tokenHash).then(
      (next) => navigate(next, { replace: true }),
      (e) => {
        console.warn(errorMessage(e));
        setError("That sign-in link has expired or was already used. Send a new one.");
      },
    );
  }, [tokenHash, navigate]);

  return (
    <Screen>
      <Bar title="Sign in" />
      {error ? (
        <>
          <Notice tone="error">{error}</Notice>
          <div className="flex-1" />
          <SignInButtons returnTo="/" />
        </>
      ) : (
        <Notice tone="info">Signing in…</Notice>
      )}
    </Screen>
  );
}
