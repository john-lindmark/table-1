import { Suspense, lazy, type ComponentProps } from "react";
import { errorMessage, waitlistAdmit, waitlistRemove, type EventBundle } from "../lib/api";
import { bracket as bracketOf, type StagedRound } from "../lib/playoffs";
import { autoLabel, when } from "../lib/scheduledEvents";
import { capture } from "../lib/telemetry";
import type { PodPairing } from "../lib/draftPods";
import { podCount, podLabel } from "../lib/seating";
import type { Participant, RoundWithMatches, Table1Event, TopCut } from "../lib/types";
import { cutLabel, seatLabel } from "../lib/leagues";
import { teamBracket, type Team } from "../lib/teams";
import { Field, Notice, Section, Segmented, Stepper, SwitchRow } from "./kit";

// Scheduled events, the sign-up link, the waitlist, top 8 and decklists (contract/scheduled-events-2026-10-27.md):
// the form pieces Create and Setup → Details share, the waitlist rows, the bracket and the decklist panel.

/** The sign-up link (the standings page once round 1 is paired). */
export const eventLink = (eventId: string) => `${window.location.origin}/s/${eventId}`;

/** Local "YYYY-MM-DDTHH:MM" for an <input type="datetime-local">, and back to ISO. */
const toLocalInput = (iso: string) => {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
const fromLocalInput = (v: string) => (v ? new Date(v).toISOString() : null);

export interface ScheduleValue { startsAt: string | null; venueName: string; capacity: number | null }

/** Tomorrow at 18:00 here, a usual store night. */
function defaultStart(): string {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  d.setHours(18, 0, 0, 0);
  return d.toISOString();
}

/** When (Now | Later with a date and time), where, and the player cap. */
export function ScheduleFields({ value, onChange, onCommit }: {
  value: ScheduleValue; onChange: (v: ScheduleValue) => void; onCommit?: () => void;
}) {
  const now = new Date();
  const max = new Date(now.getTime() + 365 * 86_400_000);
  return (
    <>
      <Section title="When" />
      <Segmented
        value={value.startsAt ? "later" : "now"}
        onChange={(v) => onChange({ ...value, startsAt: v === "later" ? value.startsAt ?? defaultStart() : null })}
        options={[{ value: "now", label: "Now" }, { value: "later", label: "Later" }]}
      />
      {value.startsAt && (
        <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
          <span className="t1-label">Starts · {when(value.startsAt)}</span>
          <input
            type="datetime-local"
            value={toLocalInput(value.startsAt)}
            min={toLocalInput(now.toISOString())}
            max={toLocalInput(max.toISOString())}
            step={900}
            onChange={(e) => {
              const iso = fromLocalInput(e.target.value);
              if (iso) onChange({ ...value, startsAt: iso });
            }}
            className="bg-transparent border-0 outline-0 text-[15px] text-t1-text [color-scheme:dark]"
          />
        </label>
      )}
      {value.startsAt && <Notice tone="info">Shown on the event and its sign-up link. You still start round 1 yourself.</Notice>}
      <Field label="Where (optional)" value={value.venueName} onChange={(v) => onChange({ ...value, venueName: v.slice(0, 80) })}
             onBlur={onCommit} placeholder="e.g. The Card Shop" />
      <SwitchRow label="Player cap" detail={value.capacity ? `${value.capacity} players` : "No cap"} on={value.capacity != null}
                 onChange={(on) => onChange({ ...value, capacity: on ? value.capacity ?? 8 : null })} />
      {value.capacity != null && (
        <>
          <Stepper label="Cap" value={value.capacity} onChange={(n) => onChange({ ...value, capacity: n })} min={4} max={512} suffix="players" />
          <Notice tone="info">Sign-ups past the cap join a waitlist. You can still add players yourself.</Notice>
        </>
      )}
    </>
  );
}

/** Automatic rounds and the top cut (Swiss events of players), then the rounds stepper when set by hand. */
export function CutAndRoundsFields({ autoRounds, onAutoRounds, rounds, onRounds, topCut, onTopCut, players, swiss, autoDetail, cuts, teams }: {
  autoRounds: boolean; onAutoRounds: (v: boolean) => void; rounds: number; onRounds: (n: number) => void;
  topCut: TopCut; onTopCut: (v: TopCut) => void; players: number; swiss: boolean;
  /** Drafts with pods: the automatic count follows the pods (draftAutoLabel). */
  autoDetail?: string;
  /** The cuts this format can have (leagues.ts cutChoices): [0] hides the picker. Left out: none or top 8 for Swiss events of players. */
  cuts?: number[];
  /** Team sealed and Team Trios: the cut is between teams. */
  teams?: boolean;
}) {
  const choices = (cuts ?? (swiss ? [0, 8] : [0])) as TopCut[];
  const need = topCut === 4 ? 5 : 9;
  const what = teams ? "teams" : "players";
  return (
    <>
      {swiss && (
        <SwitchRow label="Automatic rounds" detail={autoRounds ? autoDetail ?? autoLabel(players) : "Set by hand"} on={autoRounds} onChange={onAutoRounds} />
      )}
      {(!swiss || !autoRounds) && <Stepper label="Rounds" value={rounds} onChange={onRounds} min={1} max={15} />}
      {choices.length > 1 && (
        <Segmented value={choices.includes(topCut) ? topCut : 0} onChange={onTopCut}
                   options={choices.map((c) => ({ value: c, label: cutLabel(c) }))} />
      )}
      {choices.length > 1 && topCut > 0 && choices.includes(topCut) && (
        <Notice tone="info">
          {teams ? "After Swiss, the top 4 teams play semifinals and a final, team against team. With fewer than 5 teams the event ends after Swiss."
            : players >= need || players < 2
            ? topCut === 4 ? "After Swiss, the top 4 play single elimination: semifinals 1 v 4 and 2 v 3, then the final."
              : "After Swiss, the top 8 play single elimination: quarterfinals, semifinals, final."
            : `Top ${topCut} needs ${need} or more ${what}: with ${players} the event ends after Swiss.`}
        </Notice>
      )}
    </>
  );
}

/** Drafts: how many pods (Auto = pods of up to 8) and how rounds 2+ pair (contract/draft-pods-2026-11-09.md). */
export function DraftPodFields({ pods, pairing, onChange, players, seated = false }: {
  pods: number | null; pairing: PodPairing; onChange: (pods: number | null, pairing: PodPairing) => void;
  players: number; seated?: boolean;
}) {
  return (
    <>
      <Section title="Pods" />
      <Segmented value={pods == null ? "auto" : "choose"}
                 onChange={(v) => onChange(v === "auto" ? null : Math.max(2, podCount(players, null)), pairing)}
                 options={[{ value: "auto", label: "Auto" }, { value: "choose", label: "Choose" }]} />
      {pods != null && <Stepper label="Pods" value={pods} onChange={(n) => onChange(n, pairing)} min={1} max={16} />}
      <Notice tone="info">{podLabel(players, pods)}{seated ? " · a new number re-draws the seats" : ""}</Notice>
      <Segmented value={pairing} onChange={(v) => onChange(pods, v)}
                 options={[{ value: "pod" as const, label: "Inside pods" }, { value: "cross" as const, label: "Across pods" }]} />
      <Notice tone="info">{pairing === "pod" ? "After round 1 you play your own pod." : "After round 1, Swiss across every pod."}</Notice>
    </>
  );
}

export type DecklistMode = "off" | "optional" | "required";

/** Decklists for constructed events: off, optional or required before round 1. */
export function DecklistsFields({ mode, onMode }: { mode: DecklistMode; onMode: (m: DecklistMode) => void }) {
  return (
    <>
      <Segmented label="Decklists" value={mode} onChange={onMode}
                 options={[{ value: "off", label: "Off" }, { value: "optional", label: "Optional" }, { value: "required", label: "Required" }]} />
      {mode === "required" && <Notice tone="info">Players add their list as text or from their Table 1 decks. Round 1 waits until every list is in.</Notice>}
      {mode === "optional" && <Notice tone="info">Players can add their list as text or from their Table 1 decks. Only you see them.</Notice>}
    </>
  );
}

export const beforeRound1 = (e: Table1Event) => (e.status === "setup" || e.status === "seated") && e.currentRound === 0;

/** Setup → Players: the waitlist with Let in (past the cap) and Remove. */
export function WaitlistRows({ bundle, onChanged, onError }: {
  bundle: EventBundle; onChanged: () => void; onError: (m: string) => void;
}) {
  if (bundle.waitlist.length === 0) return null;
  const open = beforeRound1(bundle.event);
  const run = (fn: () => Promise<void>) => fn().then(onChanged, (e) => onError(errorMessage(e)));
  return (
    <>
      <Section title="Waitlist" count={bundle.waitlist.length} />
      {bundle.waitlist.map((w) => (
        <div key={w.userId} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
          <span className="flex-1 min-w-0 flex flex-col">
            <span className="text-[13px] truncate">#{w.position} {w.displayName}</span>
            {!open && <span className="t1-label">Didn't get in</span>}
          </span>
          {open && (
            <>
              <button type="button" className="t1-label text-t1-accent" onClick={() => run(() => waitlistAdmit(bundle.event.id, w.userId))}>Let in</button>
              <button type="button" className="t1-label text-t1-danger" onClick={() => run(() => waitlistRemove(bundle.event.id, w.userId))}>Remove</button>
            </>
          )}
        </div>
      ))}
    </>
  );
}

export const decklistOf = (b: EventBundle, participantId: string) => b.decklists.find((d) => d.participantId === participantId);
export const decklistsMissing = (b: EventBundle) =>
  b.participants.filter((p) => p.status === "active" && !decklistOf(b, p.id)).length;
export const decklistDetail = (b: EventBundle, p: Participant) =>
  b.event.decklists === "off" ? null : decklistOf(b, p.id) ? "Decklist ✓" : "No decklist";

/** Standings → Top 8: each playoff stage paired so far, "(1) Ana 2–0 (8) Bo", the winner in the accent. */
export function Bracket({ participants, rounds }: { participants: Participant[]; rounds: StagedRound[] }) {
  const stages = bracketOf(participants, rounds);
  if (stages.length === 0) return null;
  const title = (s: string) => (s === "quarterfinal" ? "Quarterfinals" : s === "semifinal" ? "Semifinals" : "Final");
  return (
    <>
      <Section title={stages.some((s) => s.stage === "quarterfinal") ? "Top 8" : "Top 4"} />
      {stages.map((st) => (
        <div key={st.stage} className="flex flex-col gap-px">
          <p className="t1-label px-4 py-2">{title(st.stage)}</p>
          {st.matches.map((m) => (
            <div key={m.match_id} className="bg-t1-surface px-4 py-3 flex items-center gap-2 text-[13px]">
              {[0, 1].map((n) => {
                const s = m.sides[n];
                const won = !!s?.participant_id && s.participant_id === m.winner;
                return (
                  <span key={n} className={`flex-1 min-w-0 truncate ${n === 1 ? "text-right order-3" : ""} ${won ? "text-t1-accent font-bold" : ""}`}>
                    ({s?.seed ?? "–"}) {s?.display_name ?? "—"}
                  </span>
                );
              })}
              <span className="order-2 text-t1-muted tabular-nums">
                {m.status === "pending" ? "v" : `${m.sides[0]?.game_wins ?? 0}–${m.sides[1]?.game_wins ?? 0}`}
              </span>
            </div>
          ))}
        </div>
      ))}
      <Section title="Standings" />
    </>
  );
}

/**
 * A team event's top 4 (contract/teams-finals-alerts-2026-11-13.md § 1): each team match "(1) Alpha 2–1 (4) Delta" with
 * the winner in the accent, and under it the seats' matches with their seat labels (`A · MODERN`).
 */
export function TeamBracket({ teams, participants, rounds, seatFormats }: {
  teams: Team[]; participants: Participant[]; rounds: RoundWithMatches[]; seatFormats?: string[] | null;
}) {
  const stages = teamBracket(teams, participants, rounds);
  if (stages.length === 0) return null;
  return <TeamBracketView stages={stages} seatFormats={seatFormats} />;
}

/** The same bracket from the engine's `team_bracket` (the public page has no participant list to work it out from). */
export function TeamBracketView({ stages, seatFormats }: { stages: ReturnType<typeof teamBracket>; seatFormats?: string[] | null }) {
  if (stages.length === 0) return null;
  return (
    <>
      <Section title="Top 4" />
      {stages.map((st) => (
        <div key={st.stage} className="flex flex-col gap-px">
          <p className="t1-label px-4 py-2">{st.stage === "semifinal" ? "Semifinals" : st.stage === "final" ? "Final" : "Quarterfinals"}</p>
          {st.matches.map((tm, i) => (
            <div key={`${st.stage}-${i}`} className="flex flex-col gap-px">
              <div className="bg-t1-surface px-4 py-3 flex items-center gap-2 text-[13px]">
                {[0, 1].map((n) => {
                  const s = tm.sides[n];
                  const won = !!s && s.team_id === tm.winner && tm.status !== "pending";
                  return (
                    <span key={n} className={`flex-1 min-w-0 truncate ${n === 1 ? "text-right order-3" : ""} ${won ? "text-t1-accent font-bold" : ""}`}>
                      ({s?.seed ?? "–"}) {s?.name ?? "—"}
                    </span>
                  );
                })}
                <span className="order-2 text-t1-muted tabular-nums">{tm.sides[0]?.match_wins ?? 0}–{tm.sides[1]?.match_wins ?? 0}</span>
              </div>
              {tm.matches.map((m) => (
                <div key={m.match_id} className="bg-t1-surface pl-8 pr-4 py-2 flex items-center gap-2 text-[12px]">
                  <span className="w-[104px] shrink-0 t1-label truncate">{seatLabel(m.sides[0]?.slot, seatFormats)}</span>
                  {[0, 1].map((n) => {
                    const s = m.sides[n];
                    const won = !!s?.participant_id && s.participant_id === m.winner;
                    return (
                      <span key={n} className={`flex-1 min-w-0 truncate ${n === 1 ? "text-right order-3" : ""} ${won ? "text-t1-accent" : ""}`}>
                        {s?.display_name ?? (m.is_bye ? "Bye" : "—")}
                      </span>
                    );
                  })}
                  <span className="order-2 text-t1-muted tabular-nums">
                    {m.is_bye ? "" : m.status === "pending" ? "v" : `${m.sides[0]?.game_wins ?? 0}–${m.sides[1]?.game_wins ?? 0}`}
                  </span>
                </div>
              ))}
            </div>
          ))}
        </div>
      ))}
    </>
  );
}

/** The decklist panel loads on first open, so the Library's card data code stays out of the first page load. */
const LazyDecklistPanel = lazy(() => import("./DecklistPanel").then((m) => ({ default: m.DecklistPanel })));
export function DecklistPanel(props: ComponentProps<typeof LazyDecklistPanel>) {
  return <Suspense fallback={null}><LazyDecklistPanel {...props} /></Suspense>;
}

/** Copies the sign-up link, with telemetry. */
export async function copyEventLink(e: Table1Event): Promise<void> {
  await navigator.clipboard.writeText(eventLink(e.id));
  capture("event_link_shared", { before_round_1: beforeRound1(e) });
}
