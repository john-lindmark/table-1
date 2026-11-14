import { useCallback, useEffect, useRef, useState } from "react";
import { errorMessage, leaveEvent } from "../lib/api";
import { seatLabel, teamLine, leaguesDemoOn } from "../lib/leagues";
import {
  TEAM_NAME_MAX, leaveTeamMessage, memberMenu, membersCount, movedOrder, teamCreate, teamError, teamJoin, teamLink, teamMine, teamSignupSet,
  teamUpdate, tidyTeamCode, type ListedTeam, type MyTeam, type TeamMember, type TeamMine,
} from "../lib/teamSignup";
import { Dialog, GhostAction, Menu, Notice, Section, SwitchRow, type MenuItem } from "./kit";

/* Teams that sign themselves up (contract/teams-finals-alerts-2026-11-13.md § 2): on the event page Sign up a team and
   Join a team (a code field with Paste; /s/<event>?team=<CODE> arrives with it filled in), Your team with the
   captain's menu, and the Teams list; in Setup → Teams the organizer's switch and each team's code. */

/** team_mine, read once and again whenever `version` changes; null while the server has none or the event isn't a team event. */
export function useTeamMine(eventId: string | null | undefined, enabled: boolean, token?: string | null, version: unknown = 0) {
  const [mine, setMine] = useState<TeamMine | null>(null);
  const live = useRef(true);
  // Set again on every mount: StrictMode mounts, unmounts and mounts once more in dev.
  useEffect(() => {
    live.current = true;
    return () => { live.current = false; };
  }, []);
  const reload = useCallback(async () => {
    if (!eventId || !enabled) return;
    const r = await teamMine(eventId, token);
    if (live.current) setMine(r);
  }, [eventId, enabled, token]);
  useEffect(() => {
    void reload();
  }, [reload, version]);
  return { mine: enabled ? mine : null, setMine, reload };
}

/** The code in the address (`?team=CODE`), read once. */
export const teamCodeInAddress = () => tidyTeamCode(new URLSearchParams(window.location.search).get("team") ?? "");

const inputClass = "flex-1 min-w-0 bg-t1-surface px-4 py-4 outline-0 border-0 text-[16px] placeholder:text-t1-muted/60";
const go = "bg-t1-text text-t1-bg px-6 text-[11px] uppercase tracking-[1px] disabled:bg-t1-disabled disabled:text-t1-ink";

/** Everyone's Teams list: each name with `2/3` or `COMPLETE`. */
export function TeamsList({ mine }: { mine: TeamMine }) {
  const size = mine.team_size ?? 3;
  if (mine.teams.length === 0) return null;
  return (
    <>
      <Section title="Teams" count={mine.teams.length} />
      {mine.teams.map((t) => {
        const line = teamLine({ members: membersCount(t), complete: t.complete }, size);
        return (
          <div key={t.id} className={`bg-t1-surface px-4 py-3 flex items-center gap-3 ${t.id === mine.team?.id ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}>
            <span className="flex-1 min-w-0 text-[13px] truncate">{t.name}</span>
            <span className={`shrink-0 t1-label tabular-nums ${t.complete ? "!text-t1-text" : ""}`}>{line}</span>
          </div>
        );
      })}
    </>
  );
}

/**
 * The event page's team part for a signed-in person: Sign up a team and Join a team when they're on none, Your team
 * when they are. `onChanged` reloads the page around it (signing a team up signs you up to the event).
 */
export function TeamSignupBlock({ eventId, eventName, mine, userId, onMine, onChanged, onLeft }: {
  eventId: string; eventName: string; mine: TeamMine; userId: string | null; onMine: (m: TeamMine) => void; onChanged: () => void;
  onLeft?: () => void;
}) {
  const fromLink = useRef(teamCodeInAddress());
  const [code, setCode] = useState(fromLink.current);
  const [naming, setNaming] = useState<null | "new" | "rename">(null);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<"code" | "link" | null>(null);
  const [menu, setMenu] = useState<TeamMember | null>(null);
  const [leaving, setLeaving] = useState(false);
  const canRead = typeof navigator !== "undefined" && !!navigator.clipboard?.readText;
  const me = userId ?? (leaguesDemoOn() ? "demo" : null);
  const team = mine.team;
  const size = mine.team_size ?? 3;

  const run = async (call: () => Promise<TeamMine>, after?: () => void) => {
    setBusy(true);
    setError(null);
    try {
      onMine(await call());
      after?.();
      onChanged();
    } catch (e) {
      setError(teamError(e));
    } finally {
      setBusy(false);
    }
  };
  const copy = async (what: "code" | "link", text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(what);
      window.setTimeout(() => setCopied(null), 1500);
    } catch { /* the code is on screen to read out */ }
  };
  const share = async (t: MyTeam) => {
    const url = teamLink(window.location.origin, eventId, t.join_code ?? "");
    if (navigator.share) {
      try {
        await navigator.share({ title: `${t.name} · ${eventName}`, url });
        return;
      } catch { /* closed: fall through to copying */ }
    }
    void copy("link", url);
  };

  if (team) {
    const captain = mine.captain;
    const items = (m: TeamMember): MenuItem[] => memberMenu(team, m).map((a) => (
      a === "up" ? { title: "Move up", onClick: () => void run(() => teamUpdate(team.id, { order: movedOrder(team, m.participant_id, -1) }, eventId)) }
      : a === "down" ? { title: "Move down", onClick: () => void run(() => teamUpdate(team.id, { order: movedOrder(team, m.participant_id, 1) }, eventId)) }
      : a === "captain" ? { title: "Make captain", onClick: () => void run(() => teamUpdate(team.id, { captain: m.user_id! }, eventId)) }
      : { title: "Remove", detail: "They leave the event", onClick: () => void run(() => teamUpdate(team.id, { remove: m.participant_id }, eventId)) }));
    return (
      <>
        <Section title="Your team" right={<span className={team.complete ? "text-t1-text" : ""}>{teamLine({ members: team.members.length, complete: team.complete }, size)}</span>} />
        <div className="bg-t1-surface px-4 py-4 flex items-center gap-3">
          <span className="flex-1 min-w-0 text-[20px] leading-[26px] tracking-[0.5px] break-words">{team.name}</span>
          {captain && <button type="button" className="shrink-0 t1-label hover:text-t1-text" onClick={() => { setName(team.name); setError(null); setNaming("rename"); }}>Rename team</button>}
        </div>
        {team.members.map((m) => {
          const open = captain && memberMenu(team, m).length > 0;
          const body = (
            <>
              <span className="w-[112px] shrink-0 t1-label !text-t1-accent truncate">{seatLabel(m.slot, mine.seat_formats)}</span>
              <span className="flex-1 min-w-0 text-[13px] truncate">{m.user_id === me ? `You · ${m.name}` : m.name}</span>
              {m.user_id != null && m.user_id === team.captain_id && <span className="shrink-0 t1-label">Captain</span>}
            </>
          );
          return open
            ? <button key={m.participant_id} type="button" disabled={busy} onClick={() => setMenu(m)} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3 text-left w-full">{body}</button>
            : <div key={m.participant_id} className="bg-t1-surface px-4 py-3 flex items-center gap-3">{body}</div>;
        })}
        {team.join_code && !team.complete && (
          <div className="flex gap-px">
            <div className="flex-1 min-w-0 bg-t1-surface px-4 py-3 flex flex-col gap-0.5">
              <span className="t1-label">Team code</span>
              <span className="text-[17px] tracking-[4px] select-all">{team.join_code}</span>
            </div>
            <button type="button" onClick={() => void copy("code", team.join_code!)} className="bg-t1-surface hover:bg-t1-surface-hover px-5 text-[11px] uppercase tracking-[1px]">
              {copied === "code" ? "Copied" : "Copy"}
            </button>
            <button type="button" onClick={() => void share(team)} className="bg-t1-surface hover:bg-t1-surface-hover px-5 text-[11px] uppercase tracking-[1px]">
              {copied === "link" ? "Link copied" : "Share"}
            </button>
          </div>
        )}
        {error && <Notice tone="error">{error}</Notice>}
        <div className="flex"><GhostAction label="Leave team" disabled={busy} onClick={() => { setError(null); setLeaving(true); }} /></div>
        {menu && <Menu title={`${seatLabel(menu.slot, mine.seat_formats)} · ${menu.name}`} items={items(menu)} onClose={() => setMenu(null)} />}
        {naming === "rename" && (
          <Dialog title="Rename team" cancelLabel="Cancel" confirmLabel="Save" busy={busy} error={error}
                  onCancel={() => setNaming(null)}
                  onConfirm={() => void run(() => teamUpdate(team.id, { name: name.trim() }, eventId), () => setNaming(null))}>
            <input value={name} autoFocus maxLength={TEAM_NAME_MAX} onChange={(e) => setName(e.target.value)} aria-label="Team name"
                   className="bg-t1-surface px-3 py-3 outline-0 border-0 text-[15px]" />
          </Dialog>
        )}
        {leaving && (
          <Dialog title={`Leave ${team.name}?`} message={leaveTeamMessage(team, me)} cancelLabel="Stay" confirmLabel="Leave team" tone="danger" busy={busy} error={error}
                  onCancel={() => setLeaving(false)}
                  onConfirm={() => {
                    setBusy(true);
                    const leave = leaguesDemoOn()
                      ? import("../lib/phasesDemo").then((d) => d.demoLeave(eventId))
                      : leaveEvent(eventId, false);
                    leave.then(() => { setLeaving(false); onMine({ ...mine, team: null, captain: false }); onLeft?.(); onChanged(); },
                      (e) => setError(errorMessage(e))).finally(() => setBusy(false));
                  }} />
        )}
      </>
    );
  }

  if (!mine.team_signup) return null;
  const full = !mine.can_create;
  return (
    <>
      {full && <Notice tone="info">The event is full. You can still join a team that has a seat.</Notice>}
      {!full && (naming === "new" ? (
        <div className="flex gap-px">
          <input value={name} autoFocus maxLength={TEAM_NAME_MAX} placeholder="Team name" aria-label="Team name" onChange={(e) => { setError(null); setName(e.target.value); }}
                 onKeyDown={(e) => { if (e.key === "Enter" && name.trim().length >= 2) void run(() => teamCreate(eventId, name), () => setNaming(null)); }}
                 className={inputClass} />
          <button type="button" disabled={busy || name.trim().length < 2} onClick={() => void run(() => teamCreate(eventId, name), () => setNaming(null))} className={go}>
            Sign up
          </button>
        </div>
      ) : (
        <button type="button" onClick={() => { setName(""); setError(null); setNaming("new"); }}
                className="bg-t1-accent text-t1-ink px-4 py-7 text-[17px] leading-6 text-center tracking-[5px] uppercase font-bold">
          Sign up a team
        </button>
      ))}
      <Section title="Join a team" />
      <div className="flex gap-px">
        <input value={code} placeholder="TEAM CODE" aria-label="Team code" autoCapitalize="characters" autoCorrect="off" spellCheck={false}
               onChange={(e) => { setError(null); setCode(tidyTeamCode(e.target.value)); }}
               onPaste={(e) => { e.preventDefault(); setError(null); setCode(tidyTeamCode(e.clipboardData.getData("text"))); }}
               onKeyDown={(e) => { if (e.key === "Enter" && code.length === 8) void run(() => teamJoin(eventId, code, code === fromLink.current ? "link" : "code")); }}
               className={`${inputClass} tracking-[4px] uppercase`} />
        {canRead && !code && (
          <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover px-5 text-[11px] uppercase tracking-[1px]"
                  onClick={() => void navigator.clipboard.readText().then((t) => setCode(tidyTeamCode(t)), () => setError("This browser didn't let Table 1 read what you copied. Paste it into the box instead."))}>
            Paste
          </button>
        )}
        <button type="button" disabled={busy || code.length !== 8} className={go}
                onClick={() => void run(() => teamJoin(eventId, code, code === fromLink.current ? "link" : "code"))}>
          Join
        </button>
      </div>
      {error && <Notice tone="error">{error}</Notice>}
    </>
  );
}

/** Setup → Teams: the Teams sign up switch; with it on, each team with its code and `2/3`. */
export function OrganizerTeamSignup({ eventId, on, mine, onChanged }: {
  eventId: string; on: boolean; mine: TeamMine | null; onChanged: () => void;
}) {
  const [pending, setPending] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  if (!mine) return null;
  const shown = pending ?? on;
  const size = mine.team_size ?? 3;
  const set = (next: boolean) => {
    setPending(next);
    setError(null);
    teamSignupSet(eventId, next).then(onChanged, (e) => setError(teamError(e))).finally(() => setPending(null));
  };
  const copy = async (t: ListedTeam) => {
    try {
      await navigator.clipboard.writeText(t.join_code ?? "");
      setCopied(t.id);
      window.setTimeout(() => setCopied(null), 1500);
    } catch { /* the code is on screen */ }
  };
  return (
    <>
      <SwitchRow label="Teams sign up" detail={shown ? "Captains sign their teams up and share a code" : "You build the teams"} on={shown} onChange={set} disabled={pending != null} />
      {error && <Notice tone="error">{error}</Notice>}
      {shown && mine.teams.map((t) => (
        <div key={t.id} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
          <span className="flex-1 min-w-0 flex flex-col gap-0.5">
            <span className="text-[13px] truncate">{t.name}</span>
            <span className="t1-label truncate">{Array.isArray(t.members) ? t.members.map((m) => m.name).join(" · ") || "No players" : ""}</span>
          </span>
          {t.join_code && (
            <button type="button" onClick={() => void copy(t)} aria-label={`Copy ${t.name}'s code`} className="shrink-0 text-[13px] tracking-[3px] hover:text-t1-accent">
              {copied === t.id ? "COPIED" : t.join_code}
            </button>
          )}
          <span className={`shrink-0 w-[76px] text-right t1-label tabular-nums ${t.complete ? "!text-t1-text" : ""}`}>{teamLine({ members: membersCount(t), complete: t.complete }, size)}</span>
        </div>
      ))}
      {shown && mine.teams.length === 0 && <Notice tone="info">No teams yet. Share the event's sign-up link: captains sign their teams up there.</Notice>}
    </>
  );
}
