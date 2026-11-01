// Deck finder jobs (contract/deck-finder-2026-10-15.md § Jobs): a search runs on the server as a job the screen
// polls, so the tab can be closed and the search goes on. Rules shared with iOS and Android in
// testdata/deck-finder/cases.json (deckFinder.test.ts).
import { supabase } from "./supabaseClient";

export interface Line { qty: number; name: string }
export interface FoundDeck {
  name: string; archetype: string; format: string; event: string; date: string; placement: string; player: string;
  source_url: string; notes: string; from?: "table1" | "web"; main: Line[]; side: Line[];
}
export interface Result { status: "deck" | "question" | "not_found" | "error"; question?: string; options?: string[]; message?: string; deck?: FoundDeck }
export interface Answer { question: string; answer: string }
export interface Job {
  job_id: string;
  status: "queued" | "running" | "done" | "failed";
  query: string;
  format: string | null;
  answers: Answer[];
  result: Result | null;
  created_at: string;
  finished_at: string | null;
}

/** How often the screen asks after a running job, in ms. */
export const POLL_MS = 3000;

export const finished = (j: Job) => j.status === "done" || j.status === "failed";

/**
 * Whether Find a deck, opened with no job of its own, shows the account's newest job: a search still running is
 * picked up, and one that finished in the last hour (a closed tab's search) is shown.
 */
export function resume(status: string, finishedSecondsAgo: number | null): boolean {
  if (status === "queued" || status === "running") return true;
  return finishedSecondsAgo != null && finishedSecondsAgo < 3600;
}

export const resumeJob = (j: Job, now = Date.now()) =>
  resume(j.status, j.finished_at ? (now - new Date(j.finished_at).getTime()) / 1000 : null);

/** The line under a found deck's name: placement · event · date, whichever are known. */
export const headline = (placement: string, event: string, date: string) => [placement, event, date].filter(Boolean).join(" · ");

/** Starts a search; the job id to poll. Throws with the server's words when refused (the day's allowance). */
export async function start(query: string, format: string, answers: Answer[]): Promise<string> {
  const { data, error } = await supabase.rpc("deck_finder_start", { p_query: query, p_format: format, p_answers: answers });
  if (error) throw new Error(error.message);
  return (data as { job_id: string }).job_id;
}

/** One of your jobs, or with no id the newest of the last 24 hours; null when there is none. */
export async function job(id: string | null): Promise<Job | null> {
  const { data, error } = await supabase.rpc("deck_finder_job", { p_id: id });
  if (error) throw new Error(error.message);
  return (data as Job | null) ?? null;
}

/** The result a finished job shows (a failure with no result still says so). */
export const resultOf = (j: Job): Result =>
  j.result ?? { status: "error", message: "The deck finder couldn't finish that search. Try again." };
