import { useState } from "react";
import { getSupabase } from "../lib/supabaseClient";
import { api } from "../lib/api";

const MONO = "var(--font-sf-mono)";
const inputCls =
  "bg-[#282839] text-white text-[13px] px-[14px] py-[12px] outline-none focus:ring-2 focus:ring-[#00ffd9] w-full";

type Mode = "password" | "signup" | "magic";

export function Auth() {
  const [mode, setMode] = useState<Mode>("password");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const supabase = getSupabase();
      if (mode === "signup") {
        await api.signup(email, password, name || email);
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
      } else if (mode === "password") {
        const { error } = await supabase.auth.signInWithPassword({ email, password });
        if (error) throw error;
      } else {
        const { error } = await supabase.auth.signInWithOtp({
          email,
          options: { emailRedirectTo: window.location.origin },
        });
        if (error) throw error;
        setNotice("Magic link sent. Check your email to finish signing in.");
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Authentication failed. Please try again.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="dark min-h-screen w-full bg-[#171725] flex items-center justify-center p-[24px]">
      <form
        onSubmit={submit}
        className="w-full max-w-[380px] flex flex-col gap-[16px]"
        style={{ fontFamily: MONO }}
      >
        <div className="mb-[8px]">
          <p className="text-white text-[22px] tracking-[2px] uppercase">Match Ops</p>
          <p className="text-[#c4c4ca] text-[12px] mt-[4px]">Team event organizer sign-in</p>
        </div>

        <div className="flex gap-px">
          {(["password", "signup", "magic"] as Mode[]).map((m) => (
            <button
              key={m}
              type="button"
              onClick={() => {
                setMode(m);
                setError(null);
                setNotice(null);
              }}
              className={`flex-1 py-[10px] text-[11px] uppercase tracking-[1px] ${
                mode === m ? "bg-[#00ffd9] text-[#171725]" : "bg-[#282839] text-[#c4c4ca]"
              }`}
            >
              {m === "password" ? "Sign in" : m === "signup" ? "Sign up" : "Magic link"}
            </button>
          ))}
        </div>

        {mode === "signup" && (
          <input
            className={inputCls}
            placeholder="Display name"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        )}
        <input
          className={inputCls}
          type="email"
          placeholder="Email"
          value={email}
          required
          onChange={(e) => setEmail(e.target.value)}
        />
        {mode !== "magic" && (
          <input
            className={inputCls}
            type="password"
            placeholder="Password"
            value={password}
            required
            onChange={(e) => setPassword(e.target.value)}
          />
        )}

        {error && <p className="text-[var(--destructive)] text-[12px]">{error}</p>}
        {notice && <p className="text-[#00ffd9] text-[12px]">{notice}</p>}

        <button
          type="submit"
          disabled={busy}
          className="bg-white text-[#171725] py-[12px] text-[12px] uppercase tracking-[2px] disabled:opacity-60"
        >
          {busy
            ? "Please wait…"
            : mode === "signup"
              ? "Create account"
              : mode === "magic"
                ? "Send magic link"
                : "Sign in"}
        </button>
      </form>
    </div>
  );
}
