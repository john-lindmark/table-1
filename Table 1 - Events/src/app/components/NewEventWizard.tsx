import { useMemo, useState, type ReactNode } from "react";
import { Plus, Trash2 } from "lucide-react";
import { api } from "../lib/api";

const MONO = "var(--font-sf-mono)";

type Step = "details" | "teams" | "formats" | "review";
const STEPS: { id: Step; label: string }[] = [
  { id: "details", label: "Details" },
  { id: "teams", label: "Teams" },
  { id: "formats", label: "Formats" },
  { id: "review", label: "Review" },
];

interface TeamDraft {
  name: string;
  color: string;
}
interface FormatDraft {
  name: string;
  playersA: string[];
  playersB: string[];
}

const DEFAULT_COLORS = ["#00ffd9", "#7c7cff"];

const inputCls =
  "bg-[#f5f5f6] dark:bg-[#282839] text-[#171725] dark:text-white text-[13px] px-[12px] py-[8px] outline-none focus:ring-2 focus:ring-[#00ffd9] w-full";

function Label({ children }: { children: ReactNode }) {
  return (
    <span className="text-[11px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca]">
      {children}
    </span>
  );
}

function Err({ msg }: { msg?: string }) {
  if (!msg) return null;
  return <span className="text-[11px] text-[var(--destructive)]">{msg}</span>;
}

interface NewEventWizardProps {
  onDirtyChange: (dirty: boolean) => void;
  onCreated: (eventId: string) => void;
}

export function NewEventWizard({ onDirtyChange, onCreated }: NewEventWizardProps) {
  const [step, setStep] = useState<Step>("details");

  const [name, setName] = useState("");
  const [numberOfRounds, setNumberOfRounds] = useState(5);
  const [matchupMethod, setMatchupMethod] = useState<"round_robin" | "swiss">("round_robin");
  const [drawsAllowed, setDrawsAllowed] = useState(false);
  const [timerMinutes, setTimerMinutes] = useState(50);
  const [teams, setTeams] = useState<TeamDraft[]>([
    { name: "", color: DEFAULT_COLORS[0] },
    { name: "", color: DEFAULT_COLORS[1] },
  ]);
  const [formats, setFormats] = useState<FormatDraft[]>([
    { name: "", playersA: [""], playersB: [""] },
  ]);

  const [submitting, setSubmitting] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const [created, setCreated] = useState(false);
  const [showErrors, setShowErrors] = useState(false);

  // Mark the wizard dirty as soon as any meaningful input is made.
  const markDirty = () => onDirtyChange(true);

  // ---- validation ----
  const errors = useMemo(() => {
    const e: Record<string, string> = {};
    if (!name.trim()) e.name = "Event name is required.";
    if (!Number.isFinite(numberOfRounds) || numberOfRounds < 1)
      e.rounds = "At least 1 round is required.";
    if (!Number.isFinite(timerMinutes) || timerMinutes <= 0)
      e.timer = "Timer must be greater than 0 minutes.";
    teams.forEach((t, i) => {
      if (!t.name.trim()) e[`team-${i}`] = "Team name is required.";
    });
    if (teams[0].name.trim() && teams[0].name.trim() === teams[1].name.trim())
      e.teamDup = "Team names must be different.";
    if (formats.length < 1 || formats.length > 6)
      e.formatCount = "Configure between 1 and 6 formats.";
    const seen = new Set<string>();
    formats.forEach((f, i) => {
      const fname = f.name.trim();
      if (!fname) e[`fmt-${i}`] = "Format name is required.";
      else if (seen.has(fname.toLowerCase())) e[`fmt-${i}`] = "Format names must be unique.";
      else seen.add(fname.toLowerCase());
      const a = f.playersA.filter((p) => p.trim()).length;
      const b = f.playersB.filter((p) => p.trim()).length;
      if (a < 1 || b < 1) e[`fmt-players-${i}`] = "Add at least one player per team.";
    });
    return e;
  }, [name, numberOfRounds, timerMinutes, teams, formats]);

  const stepValid = (s: Step): boolean => {
    if (s === "details") return !errors.name && !errors.rounds && !errors.timer;
    if (s === "teams")
      return !errors["team-0"] && !errors["team-1"] && !errors.teamDup;
    if (s === "formats")
      return (
        !errors.formatCount &&
        !formats.some((_, i) => errors[`fmt-${i}`] || errors[`fmt-players-${i}`])
      );
    return Object.keys(errors).length === 0;
  };

  const goNext = () => {
    setShowErrors(true);
    if (!stepValid(step)) return;
    setShowErrors(false);
    const idx = STEPS.findIndex((s) => s.id === step);
    setStep(STEPS[Math.min(idx + 1, STEPS.length - 1)].id);
  };
  const goBack = () => {
    setShowErrors(false);
    const idx = STEPS.findIndex((s) => s.id === step);
    setStep(STEPS[Math.max(idx - 1, 0)].id);
  };

  const submit = async () => {
    setShowErrors(true);
    if (Object.keys(errors).length > 0 || submitting) return;
    setSubmitting(true);
    setServerError(null);
    const cfg = {
      name: name.trim(),
      numberOfRounds,
      defaultTimerSeconds: Math.round(timerMinutes * 60),
      matchupMethod,
      drawsAllowed,
      teams: teams.map((t) => ({ name: t.name.trim(), color: t.color })),
      formats: formats.map((f) => ({
        name: f.name.trim(),
        players: [
          ...f.playersA
            .map((p) => p.trim())
            .filter(Boolean)
            .map((pn, i) => ({ teamName: teams[0].name.trim(), name: pn, displayOrder: i })),
          ...f.playersB
            .map((p) => p.trim())
            .filter(Boolean)
            .map((pn, i) => ({ teamName: teams[1].name.trim(), name: pn, displayOrder: i })),
        ],
      })),
    };
    try {
      const { eventId } = await api.createEvent(cfg);
      setCreated(true);
      onDirtyChange(false);
      // Brief success state before navigating into the new dashboard.
      window.setTimeout(() => onCreated(eventId), 600);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error("Failed to create event via create_event_with_configuration:", msg);
      setServerError(msg);
      setSubmitting(false);
    }
  };

  // ---- format/player helpers ----
  const setFormat = (i: number, patch: Partial<FormatDraft>) => {
    markDirty();
    setFormats((prev) => prev.map((f, idx) => (idx === i ? { ...f, ...patch } : f)));
  };
  const addFormat = () => {
    if (formats.length >= 6) return;
    markDirty();
    setFormats((prev) => [...prev, { name: "", playersA: [""], playersB: [""] }]);
  };
  const removeFormat = (i: number) => {
    markDirty();
    setFormats((prev) => prev.filter((_, idx) => idx !== i));
  };
  const setPlayer = (fi: number, side: "A" | "B", pi: number, value: string) => {
    markDirty();
    setFormats((prev) =>
      prev.map((f, idx) => {
        if (idx !== fi) return f;
        const key = side === "A" ? "playersA" : "playersB";
        const arr = [...f[key]];
        arr[pi] = value;
        return { ...f, [key]: arr };
      }),
    );
  };
  const addPlayer = (fi: number, side: "A" | "B") => {
    markDirty();
    setFormats((prev) =>
      prev.map((f, idx) => {
        if (idx !== fi) return f;
        const key = side === "A" ? "playersA" : "playersB";
        return { ...f, [key]: [...f[key], ""] };
      }),
    );
  };
  const removePlayer = (fi: number, side: "A" | "B", pi: number) => {
    markDirty();
    setFormats((prev) =>
      prev.map((f, idx) => {
        if (idx !== fi) return f;
        const key = side === "A" ? "playersA" : "playersB";
        const arr = f[key].filter((_, i) => i !== pi);
        return { ...f, [key]: arr.length ? arr : [""] };
      }),
    );
  };

  const btnPrimary =
    "bg-[#171725] text-white dark:bg-white dark:text-[#171725] px-[16px] py-[10px] text-[12px] uppercase tracking-[1px] disabled:opacity-40";
  const btnGhost =
    "bg-[#f5f5f6] dark:bg-[#282839] text-[#171725] dark:text-white px-[16px] py-[10px] text-[12px] uppercase tracking-[1px]";

  if (created) {
    return (
      <div className="flex flex-col items-center justify-center gap-[10px] py-[40px]" style={{ fontFamily: MONO }}>
        <div className="size-[40px] rounded-full bg-[#00ffd9] flex items-center justify-center text-[#171725] text-[20px]">
          ✓
        </div>
        <p className="text-[#171725] dark:text-white text-[13px]">Event created</p>
        <p className="text-[#545461] dark:text-[#c4c4ca] text-[11px]">Opening dashboard…</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-[16px]" style={{ fontFamily: MONO }}>
      {/* Step indicator */}
      <div className="flex gap-px">
        {STEPS.map((s, i) => (
          <div
            key={s.id}
            className={`flex-1 py-[6px] text-center text-[10px] uppercase tracking-[1px] ${
              step === s.id
                ? "bg-[#00ffd9] text-[#171725]"
                : "bg-[#f5f5f6] dark:bg-[#282839] text-[#545461] dark:text-[#c4c4ca]"
            }`}
          >
            {i + 1}. {s.label}
          </div>
        ))}
      </div>

      {step === "details" && (
        <div className="flex flex-col gap-[14px]">
          <label className="flex flex-col gap-[6px]">
            <Label>Event name</Label>
            <input
              className={inputCls}
              value={name}
              placeholder="Denver Team League"
              onChange={(e) => {
                markDirty();
                setName(e.target.value);
              }}
            />
            {showErrors && <Err msg={errors.name} />}
          </label>
          <label className="flex flex-col gap-[6px]">
            <Label>Number of rounds</Label>
            <input
              type="number"
              min={1}
              className={inputCls}
              value={numberOfRounds}
              onChange={(e) => {
                markDirty();
                setNumberOfRounds(Number(e.target.value));
              }}
            />
            {showErrors && <Err msg={errors.rounds} />}
          </label>
          <div className="flex flex-col gap-[6px]">
            <Label>Match pairing</Label>
            <div className="flex gap-px">
              {(["round_robin", "swiss"] as const).map((m) => (
                <button
                  key={m}
                  onClick={() => {
                    markDirty();
                    setMatchupMethod(m);
                  }}
                  className={`flex-1 py-[10px] text-[12px] uppercase tracking-[1px] ${
                    matchupMethod === m
                      ? "bg-[#171725] text-white dark:bg-white dark:text-[#171725]"
                      : "bg-[#f5f5f6] dark:bg-[#282839] text-[#545461] dark:text-[#c4c4ca]"
                  }`}
                >
                  {m === "round_robin" ? "Round Robin" : "Swiss"}
                </button>
              ))}
            </div>
          </div>
          <div className="flex items-center justify-between">
            <Label>Draws allowed</Label>
            <button
              onClick={() => {
                markDirty();
                setDrawsAllowed((d) => !d);
              }}
              className={`w-[44px] h-[24px] rounded-full relative transition-colors ${
                drawsAllowed ? "bg-[#00ffd9]" : "bg-[#cbced4]"
              }`}
              aria-pressed={drawsAllowed}
            >
              <span
                className={`absolute top-[2px] size-[20px] rounded-full bg-white transition-all ${
                  drawsAllowed ? "left-[22px]" : "left-[2px]"
                }`}
              />
            </button>
          </div>
          <label className="flex flex-col gap-[6px]">
            <Label>Default match timer (minutes)</Label>
            <input
              type="number"
              min={1}
              className={inputCls}
              value={timerMinutes}
              onChange={(e) => {
                markDirty();
                setTimerMinutes(Number(e.target.value));
              }}
            />
            {showErrors && <Err msg={errors.timer} />}
          </label>
        </div>
      )}

      {step === "teams" && (
        <div className="flex flex-col gap-[14px]">
          {teams.map((t, i) => (
            <div key={i} className="flex flex-col gap-[6px]">
              <Label>Team {i + 1}</Label>
              <div className="flex gap-[8px] items-center">
                <input
                  className={inputCls}
                  value={t.name}
                  placeholder={i === 0 ? "Team Fire" : "Team Ice"}
                  onChange={(e) => {
                    markDirty();
                    setTeams((prev) =>
                      prev.map((x, idx) => (idx === i ? { ...x, name: e.target.value } : x)),
                    );
                  }}
                />
                <input
                  type="color"
                  className="w-[40px] h-[36px] bg-transparent cursor-pointer shrink-0"
                  value={t.color}
                  onChange={(e) => {
                    markDirty();
                    setTeams((prev) =>
                      prev.map((x, idx) => (idx === i ? { ...x, color: e.target.value } : x)),
                    );
                  }}
                />
              </div>
              {showErrors && <Err msg={errors[`team-${i}`]} />}
            </div>
          ))}
          {showErrors && <Err msg={errors.teamDup} />}
        </div>
      )}

      {step === "formats" && (
        <div className="flex flex-col gap-[16px]">
          {formats.map((f, fi) => (
            <div key={fi} className="flex flex-col gap-[10px] bg-[#f5f5f6] dark:bg-[#282839] p-[12px]">
              <div className="flex items-center gap-[8px]">
                <input
                  className={inputCls}
                  value={f.name}
                  placeholder={`Format ${fi + 1} (e.g. Modern)`}
                  onChange={(e) => setFormat(fi, { name: e.target.value })}
                />
                {formats.length > 1 && (
                  <button
                    onClick={() => removeFormat(fi)}
                    className="text-[var(--destructive)] shrink-0"
                    aria-label="Remove format"
                  >
                    <Trash2 size={16} />
                  </button>
                )}
              </div>
              {showErrors && <Err msg={errors[`fmt-${fi}`]} />}

              <div className="grid grid-cols-2 gap-[8px]">
                {(["A", "B"] as const).map((side) => {
                  const list = side === "A" ? f.playersA : f.playersB;
                  const teamName = teams[side === "A" ? 0 : 1].name.trim() || `Team ${side}`;
                  return (
                    <div key={side} className="flex flex-col gap-[6px]">
                      <span className="text-[10px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] truncate">
                        {teamName}
                      </span>
                      {list.map((p, pi) => (
                        <div key={pi} className="flex gap-[4px] items-center">
                          <input
                            className={`${inputCls} !py-[6px] !text-[12px]`}
                            value={p}
                            placeholder={`Player ${pi + 1}`}
                            onChange={(e) => setPlayer(fi, side, pi, e.target.value)}
                          />
                          {list.length > 1 && (
                            <button
                              onClick={() => removePlayer(fi, side, pi)}
                              className="text-[#545461] dark:text-[#c4c4ca] shrink-0"
                              aria-label="Remove player"
                            >
                              <Trash2 size={13} />
                            </button>
                          )}
                        </div>
                      ))}
                      <button
                        onClick={() => addPlayer(fi, side)}
                        className="flex items-center gap-[4px] text-[10px] uppercase tracking-[1px] text-[#00a88f] dark:text-[#00ffd9]"
                      >
                        <Plus size={12} /> Player
                      </button>
                    </div>
                  );
                })}
              </div>
              {showErrors && <Err msg={errors[`fmt-players-${fi}`]} />}
            </div>
          ))}
          {formats.length < 6 && (
            <button onClick={addFormat} className={`${btnGhost} flex items-center justify-center gap-[6px]`}>
              <Plus size={14} /> Add format
            </button>
          )}
          {showErrors && <Err msg={errors.formatCount} />}
        </div>
      )}

      {step === "review" && (
        <div className="flex flex-col gap-[12px] text-[12px] text-[#171725] dark:text-white">
          <ReviewRow label="Event name" value={name || "—"} />
          <ReviewRow
            label="Teams"
            value={teams.map((t) => t.name || "—").join("  vs  ")}
          />
          <ReviewRow label="Rounds" value={String(numberOfRounds)} />
          <ReviewRow
            label="Match pairing"
            value={matchupMethod === "round_robin" ? "Round Robin" : "Swiss"}
          />
          <ReviewRow label="Timer" value={`${timerMinutes} min`} />
          <ReviewRow label="Draws" value={drawsAllowed ? "Allowed" : "Not allowed"} />
          <div className="flex flex-col gap-[8px]">
            <Label>Formats & players</Label>
            {formats.map((f, fi) => (
              <div key={fi} className="bg-[#f5f5f6] dark:bg-[#282839] p-[10px] flex flex-col gap-[6px]">
                <span className="text-[12px]">{f.name || `Format ${fi + 1}`}</span>
                <div className="grid grid-cols-2 gap-[8px] text-[11px] text-[#545461] dark:text-[#c4c4ca]">
                  <div className="flex flex-col gap-[2px]">
                    <span className="text-[#171725] dark:text-white">{teams[0].name || "Team 1"}</span>
                    {f.playersA.filter((p) => p.trim()).map((p, i) => (
                      <span key={i}>{p}</span>
                    ))}
                  </div>
                  <div className="flex flex-col gap-[2px]">
                    <span className="text-[#171725] dark:text-white">{teams[1].name || "Team 2"}</span>
                    {f.playersB.filter((p) => p.trim()).map((p, i) => (
                      <span key={i}>{p}</span>
                    ))}
                  </div>
                </div>
              </div>
            ))}
          </div>
          {serverError && (
            <p className="text-[11px] text-[var(--destructive)]">
              Could not create event: {serverError}
            </p>
          )}
        </div>
      )}

      {/* Navigation */}
      <div className="flex gap-px pt-[4px]">
        {step !== "details" && (
          <button onClick={goBack} disabled={submitting} className={`${btnGhost} flex-1`}>
            Back
          </button>
        )}
        {step !== "review" ? (
          <button onClick={goNext} className={`${btnPrimary} flex-1`}>
            Next
          </button>
        ) : (
          <button onClick={submit} disabled={submitting} className={`${btnPrimary} flex-1`}>
            {submitting ? "Creating…" : "Create event"}
          </button>
        )}
      </div>
    </div>
  );
}

function ReviewRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-[12px]">
      <Label>{label}</Label>
      <span className="text-[12px] text-[#171725] dark:text-white text-right">{value}</span>
    </div>
  );
}
