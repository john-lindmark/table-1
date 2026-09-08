import { useCallback, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabaseClient";
import { createEvent } from "../lib/api";
import { recommendedRounds } from "../lib/pairings";
import { Bar, BigAction, Field, GhostAction, Notice, Screen } from "../components/kit";

export function Home({ onOpenEvent }: { onOpenEvent: (eventId: string) => void }) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [events, setEvents] = useState<any[] | null>(null);
  const [creating, setCreating] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const loadEvents = useCallback(async () => {
    const { data } = await supabase
      .from("events")
      .select("*, event_members!inner(user_id)")
      .order("created_at", { ascending: false });
    setEvents(data ?? []);
  }, []);

  useEffect(() => {
    if (session) loadEvents();
  }, [session, loadEvents]);

  if (!ready) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }

  if (!session) return <AuthScreen />;

  if (creating) {
    return (
      <NewEvent
        onCancel={() => setCreating(false)}
        onCreated={(id) => {
          setCreating(false);
          onOpenEvent(id);
        }}
      />
    );
  }

  return (
    <Screen>
      <Bar
        title="Table 1 Events"
        subtitle={session.user.email ?? undefined}
        right={
          <button onClick={() => supabase.auth.signOut()} className="t1-label shrink-0">
            Sign out
          </button>
        }
      />
      <JoinByCode />
      <div className="bg-t1-surface px-4 py-2 t1-label">Your events</div>
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {events === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {events?.length === 0 && (
          <div className="bg-t1-surface px-4 py-6 t1-label">
            No events yet — create one to get started.
          </div>
        )}
        {events?.map((e) => (
          <button
            key={e.id}
            onClick={() => onOpenEvent(e.id)}
            className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 text-left flex flex-col gap-1"
          >
            <span className="text-[14px]">{e.name}</span>
            <span className="t1-label">
              {e.short_code} · {e.format} · {e.number_of_rounds} rounds · {String(e.status).replace("_", " ")}
            </span>
          </button>
        ))}
      </div>
      <BigAction label="Create event" tone="accent" onClick={() => setCreating(true)} />
    </Screen>
  );
}

function JoinByCode() {
  const [code, setCode] = useState("");
  return (
    <div className="flex gap-px">
      <input
        value={code}
        onChange={(e) => setCode(e.target.value.toUpperCase())}
        placeholder="EVENT CODE"
        maxLength={6}
        className="flex-1 bg-t1-surface px-4 py-4 outline-0 border-0 text-[16px] tracking-[4px] placeholder:text-t1-muted/60 uppercase"
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

function AuthScreen() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit() {
    setBusy(true);
    setError(null);
    const fn =
      mode === "signin"
        ? supabase.auth.signInWithPassword({ email, password })
        : supabase.auth.signUp({ email, password });
    const { error } = await fn;
    if (error) setError(error.message);
    setBusy(false);
  }

  return (
    <Screen>
      <Bar title="Table 1 Events" subtitle="Organizer sign in" />
      <Notice tone="info">
        Players don't need an account — they join an event with a code or a QR scan.
      </Notice>
      <Field label="Email" value={email} onChange={setEmail} type="email" />
      <Field label="Password" value={password} onChange={setPassword} type="password" />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex gap-px">
        <GhostAction
          label={mode === "signin" ? "Need an account?" : "Have an account?"}
          onClick={() => setMode(mode === "signin" ? "signup" : "signin")}
        />
      </div>
      <div className="flex-1" />
      <BigAction
        label={mode === "signin" ? "Sign in" : "Create account"}
        busy={busy}
        disabled={!email || !password}
        onClick={submit}
      />
    </Screen>
  );
}

function NewEvent({
  onCancel,
  onCreated,
}: {
  onCancel: () => void;
  onCreated: (eventId: string) => void;
}) {
  const [name, setName] = useState("Thursday Draft");
  const [namesText, setNamesText] = useState("");
  const [minutes, setMinutes] = useState("50");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const playerNames = namesText
    .split("\n")
    .map((n) => n.trim())
    .filter(Boolean);
  const rounds = recommendedRounds(Math.max(playerNames.length, 2));

  async function submit() {
    setBusy(true);
    setError(null);
    try {
      const { eventId } = await createEvent({
        name: name.trim() || "Draft",
        format: "draft",
        rounds,
        roundSeconds: Math.max(1, Number(minutes) || 50) * 60,
        playerNames,
      });
      onCreated(eventId);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Screen>
      <Bar
        title="New event"
        subtitle="Conventional booster draft"
        right={
          <button onClick={onCancel} className="t1-label shrink-0">
            Cancel
          </button>
        }
      />
      <Field label="Event name" value={name} onChange={setName} autoFocus />
      <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
        <span className="t1-label">Players — one per line (optional, they can also join by code)</span>
        <textarea
          value={namesText}
          onChange={(e) => setNamesText(e.target.value)}
          rows={8}
          placeholder={"Alex\nBrit\nCasey\n…"}
          className="bg-transparent border-0 outline-0 text-[14px] text-t1-text placeholder:text-t1-muted/60 w-full resize-none"
        />
      </label>
      <Field label="Round length (minutes)" value={minutes} onChange={setMinutes} type="number" />
      <Notice tone="info">
        {playerNames.length} player{playerNames.length === 1 ? "" : "s"} · {rounds} Swiss round
        {rounds === 1 ? "" : "s"} recommended.
      </Notice>
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1" />
      <BigAction label="Create event" tone="accent" busy={busy} disabled={!name.trim()} onClick={submit} />
    </Screen>
  );
}
