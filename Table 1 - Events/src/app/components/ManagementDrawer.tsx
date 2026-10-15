import { useEffect, useRef, useState, type ReactNode } from "react";
import { X } from "lucide-react";
import type { EventState } from "../lib/types";
import { api } from "../lib/api";
import { NewEventWizard } from "./NewEventWizard";

const MONO = "var(--font-sf-mono)";

type Tab = "current" | "new" | "past" | "organizers";

interface ManagementDrawerProps {
  event: EventState;
  dark: boolean;
  offline: boolean;
  onToggleDark: () => void;
  onToggleOffline: () => void;
  onRename: (name: string) => void;
  onSetTimerMinutes: (minutes: number) => void;
  onCorrect: (
    roundNumber: number,
    pairingId: string,
    aWins: number,
    bWins: number,
    reason: string,
  ) => void;
  onCreated: (eventId: string) => void;
  onNavigateEvent?: (eventId: string) => void;
  onClose: () => void;
}

function Field({ children, label }: { label: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-[6px]">
      <span className="text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca]">
        {label}
      </span>
      {children}
    </label>
  );
}

const inputCls =
  "bg-[#f5f5f6] dark:bg-[#282839] text-[#171725] dark:text-white text-[13px] px-[12px] py-[8px] outline-none focus:ring-2 focus:ring-[#00ffd9]";

export function ManagementDrawer(props: ManagementDrawerProps) {
  const { event } = props;
  const [tab, setTab] = useState<Tab>("current");
  const [name, setName] = useState(event.name);
  const [minutes, setMinutes] = useState(Math.round(event.timer.durationSeconds / 60));
  const [members, setMembers] = useState([
    { email: "you@example.com", role: "owner" as const },
  ]);
  const [newMember, setNewMember] = useState("");

  // Guard against leaving the New Event tab with unsaved configuration.
  const newDirty = useRef(false);
  const [leaveConfirm, setLeaveConfirm] = useState<null | (() => void)>(null);

  const guardedLeave = (action: () => void) => {
    if (tab === "new" && newDirty.current) {
      setLeaveConfirm(() => action);
    } else {
      action();
    }
  };

  const tabs: { id: Tab; label: string }[] = [
    { id: "current", label: "Current" },
    { id: "new", label: "New Event" },
    { id: "past", label: "Past" },
    { id: "organizers", label: "Organizers" },
  ];

  return (
    <div className="fixed inset-0 z-50 flex justify-end" style={{ fontFamily: MONO }}>
      <div
        className="absolute inset-0 bg-black/50"
        onClick={() => guardedLeave(props.onClose)}
        aria-hidden
      />
      <div className="relative w-full max-w-[440px] h-full bg-white dark:bg-[#171725] shadow-2xl flex flex-col overflow-hidden">
        <div className="flex items-center justify-between px-[20px] py-[16px] border-b border-[var(--border)]">
          <p className="text-[14px] text-[#171725] dark:text-white tracking-[1px] uppercase">
            Event Management
          </p>
          <button
            onClick={() => guardedLeave(props.onClose)}
            aria-label="Close"
            className="text-[#171725] dark:text-white"
          >
            <X size={18} />
          </button>
        </div>

        <div className="flex gap-px bg-[var(--border)]">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => guardedLeave(() => setTab(t.id))}
              className={`flex-1 py-[10px] text-[11px] uppercase tracking-[1px] ${
                tab === t.id
                  ? "bg-[#171725] text-white dark:bg-white dark:text-[#171725]"
                  : "bg-white dark:bg-[#171725] text-[#545461] dark:text-[#c4c4ca]"
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        <div className="flex-1 overflow-y-auto p-[20px] flex flex-col gap-[20px]">
          {/* Preferences shared across tabs */}
          <div className="flex items-center justify-between gap-[12px] text-[12px] text-[#171725] dark:text-white">
            <span>Dark mode</span>
            <button
              onClick={props.onToggleDark}
              className={`w-[44px] h-[24px] rounded-full relative transition-colors ${
                props.dark ? "bg-[#00ffd9]" : "bg-[#cbced4]"
              }`}
              aria-pressed={props.dark}
            >
              <span
                className={`absolute top-[2px] size-[20px] rounded-full bg-white transition-all ${
                  props.dark ? "left-[22px]" : "left-[2px]"
                }`}
              />
            </button>
          </div>
          <div className="flex items-center justify-between gap-[12px] text-[12px] text-[#171725] dark:text-white">
            <span>Simulate offline</span>
            <button
              onClick={props.onToggleOffline}
              className={`w-[44px] h-[24px] rounded-full relative transition-colors ${
                props.offline ? "bg-[var(--destructive)]" : "bg-[#cbced4]"
              }`}
              aria-pressed={props.offline}
            >
              <span
                className={`absolute top-[2px] size-[20px] rounded-full bg-white transition-all ${
                  props.offline ? "left-[22px]" : "left-[2px]"
                }`}
              />
            </button>
          </div>

          {tab === "current" && (
            <>
              <Field label="Event name">
                <div className="flex gap-[8px]">
                  <input className={`${inputCls} flex-1`} value={name} onChange={(e) => setName(e.target.value)} />
                  <button
                    onClick={() => props.onRename(name)}
                    className="bg-[#171725] text-white dark:bg-white dark:text-[#171725] px-[12px] text-[12px]"
                  >
                    Save
                  </button>
                </div>
              </Field>
              <Field label="Timer duration (minutes)">
                <div className="flex gap-[8px]">
                  <input
                    type="number"
                    className={`${inputCls} flex-1`}
                    value={minutes}
                    onChange={(e) => setMinutes(Number(e.target.value))}
                  />
                  <button
                    onClick={() => props.onSetTimerMinutes(minutes)}
                    className="bg-[#171725] text-white dark:bg-white dark:text-[#171725] px-[12px] text-[12px]"
                  >
                    Set
                  </button>
                </div>
              </Field>

              <div className="flex flex-col gap-[10px]">
                <span className="text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca]">
                  Recorded rounds — corrections
                </span>
                {event.recordedRounds.length === 0 && (
                  <p className="text-[12px] text-[#545461] dark:text-[#c4c4ca]">No recorded rounds yet.</p>
                )}
                {event.recordedRounds.map((round) => (
                  <CorrectionRound key={round.roundNumber} round={round} event={event} onCorrect={props.onCorrect} />
                ))}
              </div>
            </>
          )}

          {tab === "new" && (
            <NewEventWizard
              onDirtyChange={(d) => (newDirty.current = d)}
              onCreated={(id) => {
                newDirty.current = false;
                props.onCreated(id);
              }}
            />
          )}

          {tab === "past" && (
            <PastEventsTab
              currentEventId={event.id}
              onNavigate={(id) => {
                props.onNavigateEvent?.(id);
                props.onClose();
              }}
            />
          )}

          {tab === "organizers" && (
            <div className="flex flex-col gap-[10px]">
              {members.map((m) => (
                <div
                  key={m.email}
                  className="flex items-center justify-between bg-[#f5f5f6] dark:bg-[#282839] px-[12px] py-[8px] text-[12px] text-[#171725] dark:text-white"
                >
                  <span>{m.email}</span>
                  <span className="text-[11px] text-[#545461] dark:text-[#c4c4ca] uppercase">{m.role}</span>
                </div>
              ))}
              <div className="flex gap-[8px]">
                <input
                  className={`${inputCls} flex-1`}
                  placeholder="organizer@email.com"
                  value={newMember}
                  onChange={(e) => setNewMember(e.target.value)}
                />
                <button
                  onClick={() => {
                    if (!newMember.includes("@")) return;
                    setMembers((prev) => [...prev, { email: newMember, role: "organizer" as const }]);
                    setNewMember("");
                  }}
                  className="bg-[#171725] text-white dark:bg-white dark:text-[#171725] px-[12px] text-[12px]"
                >
                  Add
                </button>
              </div>
            </div>
          )}
        </div>
      </div>

      {leaveConfirm && (
        <div className="absolute inset-0 z-10 flex items-center justify-center">
          <div className="absolute inset-0 bg-black/60" onClick={() => setLeaveConfirm(null)} />
          <div className="relative bg-white dark:bg-[#171725] max-w-[340px] w-[85%] p-[20px] flex flex-col gap-[14px] border border-[var(--border)]">
            <p className="text-[14px] text-[#171725] dark:text-white tracking-[0.5px]">
              Discard unfinished event?
            </p>
            <p className="text-[12px] leading-[18px] text-[#545461] dark:text-[#c4c4ca]">
              You have an event configuration in progress. Leaving now will discard it.
            </p>
            <div className="flex gap-px">
              <button
                onClick={() => setLeaveConfirm(null)}
                className="flex-1 py-[10px] bg-[#f5f5f6] dark:bg-[#282839] text-[#171725] dark:text-white text-[12px] uppercase tracking-[1px]"
              >
                Keep editing
              </button>
              <button
                onClick={() => {
                  const action = leaveConfirm;
                  newDirty.current = false;
                  setLeaveConfirm(null);
                  action();
                }}
                className="flex-1 py-[10px] bg-[var(--destructive)] text-white text-[12px] uppercase tracking-[1px]"
              >
                Discard
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function PastEventsTab({
  currentEventId,
  onNavigate,
}: {
  currentEventId: string;
  onNavigate: (id: string) => void;
}) {
  const [events, setEvents] = useState<any[] | null>(null);

  useEffect(() => {
    api
      .listEvents()
      .then(({ events }) => {
        const sorted = [...events].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
        setEvents(sorted);
      })
      .catch(() => setEvents([]));
  }, []);

  if (events === null) {
    return (
      <p className="text-[12px] text-[#545461] dark:text-[#c4c4ca]">Loading events…</p>
    );
  }

  if (events.length === 0) {
    return (
      <p className="text-[12px] text-[#545461] dark:text-[#c4c4ca]">No events found.</p>
    );
  }

  return (
    <div className="flex flex-col gap-[8px]" style={{ fontFamily: MONO }}>
      <span className="text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca]">
        All events
      </span>
      {events.map((e) => {
        const isCurrent = e.id === currentEventId;
        const statusColor =
          e.status === "completed"
            ? "text-[#00a88f] dark:text-[#00ffd9]"
            : e.status === "archived"
              ? "text-[#545461] dark:text-[#c4c4ca]"
              : "text-[#171725] dark:text-white";
        return (
          <button
            key={e.id}
            onClick={() => onNavigate(e.id)}
            className="text-left bg-[#f5f5f6] dark:bg-[#282839] p-[12px] flex flex-col gap-[4px] hover:opacity-80 transition-opacity"
          >
            <div className="flex items-start justify-between gap-[8px]">
              <span className="text-[12px] text-[#171725] dark:text-white">{e.name}</span>
              <span className={`text-[10px] uppercase tracking-[0.5px] shrink-0 ${statusColor}`}>
                {isCurrent ? "current" : e.status.replace("_", " ")}
              </span>
            </div>
            <span className="text-[11px] text-[#545461] dark:text-[#c4c4ca]">
              {e.teams?.map((t: any) => t.name).join(" vs ")} · {e.numberOfRounds} rounds ·{" "}
              {e.formats?.length ?? 0} formats
            </span>
          </button>
        );
      })}
    </div>
  );
}

function CorrectionRound({
  round,
  event,
  onCorrect,
}: {
  round: EventState["recordedRounds"][number];
  event: EventState;
  onCorrect: ManagementDrawerProps["onCorrect"];
}) {
  const [open, setOpen] = useState(false);
  const player = (id: string) => event.players.find((p) => p.id === id)?.name ?? "—";

  return (
    <div className="bg-[#f5f5f6] dark:bg-[#282839]">
      <button
        onClick={() => setOpen((o) => !o)}
        className="w-full flex items-center justify-between px-[12px] py-[8px] text-[12px] text-[#171725] dark:text-white"
      >
        <span>Round {round.roundNumber}</span>
        <span className="text-[11px] text-[#545461] dark:text-[#c4c4ca]">{open ? "Hide" : "Review"}</span>
      </button>
      {open && (
        <div className="flex flex-col gap-px p-[8px]">
          {round.pairings.map((p) => (
            <CorrectionRow
              key={p.id}
              label={`${player(p.teamAPlayerId)} vs ${player(p.teamBPlayerId)}`}
              aWins={p.teamAGameWins ?? 0}
              bWins={p.teamBGameWins ?? 0}
              onCorrect={(aWins, bWins, reason) =>
                onCorrect(round.roundNumber, p.id, aWins, bWins, reason)
              }
            />
          ))}
        </div>
      )}
    </div>
  );
}

function CorrectionRow({
  label,
  aWins,
  bWins,
  onCorrect,
}: {
  label: string;
  aWins: number;
  bWins: number;
  onCorrect: (aWins: number, bWins: number, reason: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [a, setA] = useState(aWins);
  const [b, setB] = useState(bWins);
  const [reason, setReason] = useState("");
  const invalid = a === 2 && b === 2;

  return (
    <div className="bg-white dark:bg-[#171725] px-[10px] py-[8px] text-[11px] text-[#171725] dark:text-white">
      <div className="flex items-center justify-between gap-[8px]">
        <span className="truncate">{label}</span>
        <span className="text-[#545461] dark:text-[#c4c4ca] tabular-nums">
          {aWins}–{bWins}
        </span>
        <button className="text-[#00a88f] dark:text-[#00ffd9]" onClick={() => setEditing((e) => !e)}>
          {editing ? "Cancel" : "Edit"}
        </button>
      </div>
      {editing && (
        <div className="flex flex-col gap-[6px] mt-[8px]">
          <div className="flex items-center gap-[8px]">
            <select className={inputCls} value={a} onChange={(e) => setA(Number(e.target.value))}>
              {[0, 1, 2].map((n) => (
                <option key={n} value={n}>
                  {n}
                </option>
              ))}
            </select>
            <span className="text-[#545461] dark:text-[#c4c4ca]">–</span>
            <select className={inputCls} value={b} onChange={(e) => setB(Number(e.target.value))}>
              {[0, 1, 2].map((n) => (
                <option key={n} value={n}>
                  {n}
                </option>
              ))}
            </select>
          </div>
          {invalid && (
            <span className="text-[var(--destructive)]">2–2 is not a valid result.</span>
          )}
          <input
            className={inputCls}
            placeholder="Correction reason (required)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
          <button
            disabled={!reason.trim() || invalid}
            onClick={() => {
              onCorrect(a, b, reason.trim());
              setEditing(false);
              setReason("");
            }}
            className="bg-[#171725] text-white dark:bg-white dark:text-[#171725] py-[6px] disabled:opacity-40"
          >
            Save correction
          </button>
        </div>
      )}
    </div>
  );
}
