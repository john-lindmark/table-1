// Moderation (contract/moderation-2026-10-18.md): what Table 1 changed on your content and why, with one appeal per
// change; and, for moderators, the review queue. The server decides everything; this store only shows it and sends
// answers back. Same as iOS Moderation.swift and Android Moderation.kt.
import { useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";
import { capture } from "./telemetry";
import type { Person } from "./friends";

export interface ModerationMe { moderator: boolean; unseen: number; restricted_until: string | null }

export interface ModerationNotice {
  id: number; subject_kind: string; label: string; action: string; category: string | null; reason_text: string; at: string;
  seen: boolean; appeal: "none" | "open" | "reverted" | "upheld"; can_appeal: boolean;
}

export interface ReviewCheck {
  id: number; subject_kind: string; text: string | null; bucket: string | null; path: string | null; status: string;
  category: string | null; reason: string | null; source: string; enforced: boolean; owner: Person | null; strikes: number; reports: number;
}

export interface ReviewAppeal {
  id: number; label: string; action: string; category: string | null; note: string | null; owner: Person | null;
  text: string | null; path: string | null; bucket: string | null;
}

export interface FlaggedAccount { user_id: string; display_name: string; handle: string | null; strikes: number; reporters: number; restricted_until: string | null }

export interface ReviewQueue { mode: "shadow" | "enforce"; checks: ReviewCheck[]; appeals: ReviewAppeal[]; flagged: FlaggedAccount[] }

export const waiting = (q: ReviewQueue) => q.checks.length + q.appeals.length + q.flagged.length;

/** What the change did to the content, in a few words. */
export function whatChanged(action: string): string {
  switch (action) {
    case "reset_name": return "Changed to a neutral name";
    case "clear_handle": case "remove_avatar": return "Removed";
    case "unshare": return "No longer shared";
    case "rename_event": return "Renamed with the event code";
    case "rename_guest": return "Renamed by seat";
    case "hide_photo": return "Hidden from other players";
    case "clear_note": return "Cleared";
    default: return "Changed";
  }
}

export function noticeStatus(n: Pick<ModerationNotice, "appeal" | "seen">): string {
  switch (n.appeal) {
    case "open": return "Appeal sent";
    case "reverted": return "Restored";
    case "upheld": return "Upheld";
    default: return n.seen ? "" : "New";
  }
}

const SUBJECT: Record<string, string> = {
  display_name: "Display name", handle: "Handle", avatar: "Profile photo", list_name: "Deck or cube name", binder_name: "Binder name",
  event_name: "Event name", guest_name: "Guest name", deck_photo: "Deck photo", deck_photo_note: "Deck photo note",
};
export const subjectWord = (kind: string) => SUBJECT[kind] ?? kind;

const CATEGORY: Record<string, string> = {
  hate: "Hate", harassment: "Harassment", sexual: "Sexual", child_safety: "Child safety", violence: "Violence", self_harm: "Self-harm",
  spam: "Spam", personal_info: "Personal info", impersonation: "Impersonation", "": "Unclear",
};
export const categoryWord = (c: string | null) => CATEGORY[c ?? ""] ?? "Other";

/** "Oct 18, 2026" from an ISO timestamp. */
export function modDate(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

export const APPEAL_NOTE_MAX = 500;

/* ── store ───────────────────────────────────────────────────────────── */

interface State { me: ModerationMe | null; notices: ModerationNotice[] | null; queue: ReviewQueue | null; error: string | null }
let state: State = { me: null, notices: null, queue: null, error: null };
const listeners = new Set<() => void>();
const set = (patch: Partial<State>) => { state = { ...state, ...patch }; listeners.forEach((f) => f()); };
const subscribe = (f: () => void) => { listeners.add(f); return () => void listeners.delete(f); };
export const useModeration = () => useSyncExternalStore(subscribe, () => state);
export const moderationNow = () => state;
export const resetModeration = () => set({ me: null, notices: null, queue: null, error: null });

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args ?? {});
  if (error) throw error;
  return data as T;
}

export async function loadModerationMe() {
  try { set({ me: await rpc<ModerationMe>("moderation_me") }); } catch { /* the Account rows just don't show */ }
}

export async function loadNotices() {
  try { set({ notices: await rpc<ModerationNotice[]>("moderation_notices"), error: null }); } catch (e) { set({ error: (e as Error).message }); }
}

/** What the Account rows need. */
export async function loadModerationRows() {
  await loadModerationMe();
  await loadNotices();
  if (state.me?.moderator) await loadQueue();
}

export async function markNoticesSeen() {
  if (!(state.me?.unseen ?? 0) && !state.notices?.some((n) => !n.seen)) return;
  try { await rpc("moderation_notices_seen"); } catch { /* seen next time */ }
  await loadModerationMe();
}

export async function appeal(id: number, note: string) {
  const n = note.trim().slice(0, APPEAL_NOTE_MAX);
  await rpc("moderation_appeal", { p_action_id: id, p_note: n || null });
  capture("moderation_appealed");
  await loadNotices();
}

export async function loadQueue() {
  try { set({ queue: await rpc<ReviewQueue>("moderation_queue", { p_limit: 100 }), error: null }); } catch (e) { set({ error: (e as Error).message }); }
}

export async function resolveCheck(check: ReviewCheck, decision: "allow" | "block") {
  await rpc("moderation_resolve", { p_check_id: check.id, p_decision: decision });
  capture("moderation_resolved", { decision, subject: check.subject_kind });
  await loadQueue();
}

export async function resolveAppeal(a: ReviewAppeal, decision: "uphold" | "revert") {
  const r = await rpc<{ delete_path?: string | null }>("moderation_appeal_resolve", { p_action_id: a.id, p_decision: decision });
  // An upheld profile photo: the file goes too.
  if (r?.delete_path) await supabase.functions.invoke("moderate", { body: { purge: r.delete_path } }).catch(() => {});
  capture("moderation_resolved", { decision, subject: "appeal" });
  await loadQueue();
}

export async function restrict(userId: string, days: number, reason: string) {
  await rpc("moderation_restrict", { p_user_id: userId, p_days: days, p_reason: reason || null });
  capture("moderation_resolved", { decision: days === 0 ? "lift" : "restrict", subject: "account" });
  await loadQueue();
}

export async function setMode(mode: "shadow" | "enforce") {
  await rpc("moderation_set_mode", { p_mode: mode });
  await loadQueue();
}

/** Short-lived links to the photos under review (the `moderate` function signs them for moderators). */
export async function photoUrls(items: { bucket: string; path: string }[]): Promise<Record<string, string>> {
  if (!items.length) return {};
  try {
    const { data, error } = await supabase.functions.invoke("moderate", { body: { sign: items } });
    if (error) return {};
    return (data as { urls?: Record<string, string> })?.urls ?? {};
  } catch {
    return {};
  }
}
