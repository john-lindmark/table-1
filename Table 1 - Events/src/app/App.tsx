import { useCallback, useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { getSupabase } from "./lib/supabaseClient";
import { api } from "./lib/api";
import { Auth } from "./components/Auth";
import { Dashboard } from "./components/Dashboard";
import { NewEventWizard } from "./components/NewEventWizard";
import { SharedResults } from "./components/SharedResults";

const MONO = "var(--font-sf-mono)";

// Check for ?share=<eventId> in the URL — render public results without auth.
// Evaluated once at module level so it's stable across renders.
const SHARE_ID = new URLSearchParams(window.location.search).get("share");

function AuthenticatedApp() {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [dark, setDark] = useState(true);
  const [eventId, setEventId] = useState<string | null>(null);
  const [events, setEvents] = useState<any[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [creating, setCreating] = useState(false);

  // Only auto-navigate once per session so "← Past Events" doesn't bounce back.
  const hasAutoSelected = useRef(false);

  useEffect(() => {
    const supabase = getSupabase();
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const loadEvents = useCallback(async () => {
    try {
      const { events } = await api.listEvents();
      const sorted = [...events].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
      setEvents(sorted);
      // Auto-navigate to the most recent in-progress event, but only once per
      // session so navigating back to the picker doesn't immediately redirect.
      if (!hasAutoSelected.current) {
        hasAutoSelected.current = true;
        const active = sorted.find(
          (e) => e.status !== "archived" && e.status !== "completed",
        );
        if (active) setEventId(active.id);
      }
    } catch {
      setEvents([]);
    }
  }, []); // stable — reads mutable refs, uses stable setters

  useEffect(() => {
    if (session) loadEvents();
  }, [session, loadEvents]);

  const signOut = async () => {
    hasAutoSelected.current = false;
    await getSupabase().auth.signOut();
    setEventId(null);
    setEvents(null);
  };

  const seed = async () => {
    setBusy(true);
    try {
      const { eventId } = await api.seed();
      await loadEvents();
      setEventId(eventId);
    } finally {
      setBusy(false);
    }
  };

  if (!authReady) return <Splash dark={dark} label="Loading…" />;
  if (!session) return <Auth />;

  if (eventId) {
    return (
      <Dashboard
        eventId={eventId}
        dark={dark}
        onToggleDark={() => setDark((d) => !d)}
        onSignOut={signOut}
        onNavigateEvent={(id) => {
          setEventId(id);
          loadEvents();
        }}
        onBack={() => setEventId(null)}
      />
    );
  }

  // No event selected — event picker / empty state.
  return (
    <div className={`${dark ? "dark" : ""} min-h-screen w-full bg-white dark:bg-[#171725]`}>
      <div
        className="min-h-screen w-full bg-white dark:bg-[#171725] flex items-center justify-center p-[24px]"
        style={{ fontFamily: MONO }}
      >
        <div className="w-full max-w-[460px] flex flex-col gap-[16px]">
          <div className="flex items-center justify-between">
            <p className="text-[#171725] dark:text-white text-[18px] tracking-[2px] uppercase">
              {creating ? "New Event" : "Your Events"}
            </p>
            <button onClick={signOut} className="text-[#545461] dark:text-[#c4c4ca] text-[11px] uppercase">
              Sign out
            </button>
          </div>

          {creating ? (
            <>
              <NewEventWizard
                onDirtyChange={() => {}}
                onCreated={(id) => {
                  setCreating(false);
                  setEventId(id);
                  loadEvents();
                }}
              />
              <button
                onClick={() => setCreating(false)}
                className="text-[#545461] dark:text-[#c4c4ca] text-[11px] uppercase tracking-[1px] self-start"
              >
                ← Back to events
              </button>
            </>
          ) : (
            <>
          {events === null && <p className="text-[#545461] dark:text-[#c4c4ca] text-[12px]">Loading…</p>}

          {events?.map((e) => (
            <button
              key={e.id}
              onClick={() => setEventId(e.id)}
              className="text-left bg-[#f5f5f6] dark:bg-[#282839] p-[16px] flex flex-col gap-[4px] hover:opacity-90"
            >
              <span className="text-[#171725] dark:text-white text-[13px]">{e.name}</span>
              <span className="text-[#545461] dark:text-[#c4c4ca] text-[11px]">
                {e.teams?.map((t: any) => t.name).join(" vs ")} · {e.numberOfRounds} rounds ·{" "}
                {e.status.replace("_", " ")}
              </span>
            </button>
          ))}

          {events?.length === 0 && (
            <p className="text-[#545461] dark:text-[#c4c4ca] text-[12px]">
              No events yet. Seed a sample event to explore the dashboard.
            </p>
          )}

          <button
            onClick={() => setCreating(true)}
            className="bg-[#00ffd9] text-[#171725] py-[12px] text-[12px] uppercase tracking-[2px]"
          >
            Create event
          </button>

          <button
            onClick={seed}
            disabled={busy}
            className="bg-[#171725] dark:bg-white text-white dark:text-[#171725] py-[12px] text-[12px] uppercase tracking-[2px] disabled:opacity-60"
          >
            {busy ? "Creating…" : "Seed sample event"}
          </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

export default function App() {
  if (SHARE_ID) return <SharedResults eventId={SHARE_ID} />;
  return <AuthenticatedApp />;
}

function Splash({ dark, label }: { dark: boolean; label: string }) {
  return (
    <div
      className={`${dark ? "dark" : ""} min-h-screen w-full bg-white dark:bg-[#171725] flex items-center justify-center`}
    >
      <p
        className="text-[#545461] dark:text-[#c4c4ca] text-[12px] tracking-[2px] uppercase"
        style={{ fontFamily: "var(--font-sf-mono)" }}
      >
        {label}
      </p>
    </div>
  );
}
