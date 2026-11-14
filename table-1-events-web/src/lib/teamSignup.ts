// Teams that sign themselves up (contract/teams-finals-alerts-2026-11-13.md § 2): a captain makes the team and
// shares its code, teammates join with it. `team_mine` is read by anyone who can open the event; a server before
// it, or a failed read, answers null and the event page shows no team part (the organizer builds the teams, as before).
import { phasesDemo, rpc } from "./leagues";
import { capture } from "./telemetry";

export interface TeamMember { participant_id: string; user_id: string | null; name: string; slot: number | null }
export interface MyTeam { id: string; name: string; captain_id: string | null; join_code: string | null; members: TeamMember[]; complete: boolean }
/** A team in everyone's list: a count of members; organizers get each team in full, with its code. */
export interface ListedTeam { id: string; name: string; members: number | TeamMember[]; complete: boolean; captain_id?: string | null; join_code?: string | null }
export interface TeamMine {
  team_signup: boolean; team_size: number | null; seat_formats: string[] | null; team: MyTeam | null; captain: boolean; can_create: boolean;
  teams: ListedTeam[];
}

export const TEAM_NAME_MAX = 40;
export const membersCount = (t: Pick<ListedTeam, "members">) => (Array.isArray(t.members) ? t.members.length : t.members);
/** A code as typed or pasted (a whole link too): its 8 characters, upper case. */
export function tidyTeamCode(text: string): string {
  const fromLink = /[?&]team=([A-Za-z0-9]+)/.exec(text)?.[1];
  return (fromLink ?? text).replace(/[^A-Za-z0-9]/g, "").toUpperCase().slice(0, 8);
}
/** The link a captain shares: the event page with the code filled in. */
export const teamLink = (origin: string, eventId: string, code: string) => `${origin}/s/${eventId}?team=${encodeURIComponent(code)}`;
/** Leave team's confirm: the captain's says who takes over. */
export function leaveTeamMessage(team: MyTeam, myUserId: string | null | undefined): string {
  const rest = team.members.filter((m) => m.user_id !== myUserId);
  if (rest.length === 0) return "You leave the event and the team closes.";
  return team.captain_id === myUserId ? `You leave the event. ${rest[0].name} becomes captain.` : "You leave the event. Your seat on the team opens.";
}
/** What the captain can do to a member's row (never to their own, except moving). */
export function memberMenu(team: MyTeam, member: TeamMember): ("up" | "down" | "captain" | "remove")[] {
  const i = team.members.findIndex((m) => m.participant_id === member.participant_id);
  const self = member.user_id != null && member.user_id === team.captain_id;
  return [...(i > 0 ? ["up" as const] : []), ...(i >= 0 && i < team.members.length - 1 ? ["down" as const] : []),
          ...(!self && member.user_id ? ["captain" as const] : []), ...(!self ? ["remove" as const] : [])];
}
/** `order` after moving a member one seat up or down: every member's participant id, seat A first. */
export function movedOrder(team: MyTeam, participantId: string, by: -1 | 1): string[] {
  const ids = team.members.map((m) => m.participant_id);
  const i = ids.indexOf(participantId), j = i + by;
  if (i < 0 || j < 0 || j >= ids.length) return ids;
  [ids[i], ids[j]] = [ids[j], ids[i]];
  return ids;
}

function clean(r: Partial<TeamMine> | null | undefined): TeamMine {
  return { team_signup: !!r?.team_signup, team_size: r?.team_size ?? null, seat_formats: r?.seat_formats ?? null, team: r?.team ?? null,
           captain: !!r?.captain, can_create: !!r?.can_create, teams: r?.teams ?? [] };
}

export async function teamMine(eventId: string, token?: string | null): Promise<TeamMine | null> {
  try {
    const d = await phasesDemo();
    return clean(d ? d.teamMine(eventId) : await rpc<TeamMine>("team_mine", token ? { p_event_id: eventId, p_token: token } : { p_event_id: eventId }));
  } catch {
    return null;
  }
}

export async function teamSignupSet(eventId: string, on: boolean): Promise<boolean> {
  const d = await phasesDemo();
  const r = d ? d.teamSignupSet(eventId, on) : await rpc<{ team_signup: boolean }>("team_signup_set", { p_event_id: eventId, p_on: on });
  capture("team_signup_set", { on: r.team_signup });
  return r.team_signup;
}

export async function teamCreate(eventId: string, name: string): Promise<TeamMine> {
  const d = await phasesDemo();
  const r = clean(d ? d.teamCreate(eventId, name) : await rpc<TeamMine>("team_create", { p_event_id: eventId, p_name: name.trim() }));
  capture("team_created", {});
  return r;
}

export async function teamJoin(eventId: string, code: string, how: "code" | "link"): Promise<TeamMine> {
  const d = await phasesDemo();
  const r = clean(d ? d.teamJoin(eventId, code) : await rpc<TeamMine>("team_join", { p_event_id: eventId, p_code: code }));
  capture("team_joined", { how });
  return r;
}

export type TeamPatch = { name: string } | { order: string[] } | { captain: string } | { remove: string };
export async function teamUpdate(teamId: string, patch: TeamPatch, eventId?: string): Promise<TeamMine> {
  const d = await phasesDemo();
  const r = clean(d ? d.teamUpdate(eventId ?? "", teamId, patch) : await rpc<TeamMine>("team_update", { p_team_id: teamId, p_patch: patch }));
  capture("team_updated", { what: Object.keys(patch)[0] });
  return r;
}

/** What a failed team call says: the server's own words for its refusals. */
export function teamError(e: unknown): string {
  const o = e as { code?: string; message?: string } | null;
  if (o?.code === "P0002") return "No team has that code.";
  if (o?.code === "23505") return "Another team has that name.";
  return typeof o?.message === "string" && o.message ? o.message : "Couldn't save. Check your connection.";
}
