import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { errorMessage, finishGoogle } from "../lib/api";
import { Bar, Notice, Screen } from "../components/kit";
import { SignInButtons } from "../components/SignInButtons";

/**
 * Where Google sends the browser back: /auth/google#id_token=…&state=…. Not claimed by the apps, so it always opens
 * in the browser that asked.
 */
export function GoogleReturn() {
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);
  const started = useRef(false);

  useEffect(() => {
    // StrictMode runs effects twice in dev; the request is read once.
    if (started.current) return;
    started.current = true;
    const hash = window.location.hash;
    // The token stays out of history and the address bar.
    window.history.replaceState(null, "", window.location.pathname);
    finishGoogle(hash).then(
      ({ next }) => navigate(next, { replace: true }),
      (e) => setError(errorMessage(e)),
    );
  }, [navigate]);

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
