// Scheduled events, the sign-up link, the waitlist, top 8, automatic rounds and decklists
// (contract/scheduled-events-2026-10-27.md). Checked against testdata/scheduled-events/cases.json
// (scheduledEvents.test.ts); iOS and Android carry the same rules. The bracket and final order come from
// playoffs.ts (the engine's own copy).

export { swissRounds, nextStep, type NextStep, type Stage } from "./playoffs";
import { swissRounds } from "./playoffs";

/** "Round 2 of 5", "Quarterfinals", "Semifinals", "Final". */
export function roundName(stage: string | null | undefined, number: number, of: number): string {
  return stage === "quarterfinal" ? "Quarterfinals" : stage === "semifinal" ? "Semifinals" : stage === "final" ? "Final"
    : `Round ${number} of ${of}`;
}

export const playersText = (n: number) => (n === 1 ? "1 player" : `${n} players`);

/** "12 players signed up", "12/16 players", "16/16 players · 3 on the waitlist". */
export function signUpLine(players: number, capacity: number | null, waitlist: number): string {
  if (capacity == null) return `${playersText(players)} signed up`;
  return `${players}/${capacity} players` + (waitlist > 0 ? ` · ${waitlist} on the waitlist` : "");
}

/** The Rounds row when Auto is on. */
export function autoLabel(players: number): string {
  if (players < 2) return "Auto · set when round 1 is paired";
  const n = swissRounds(players);
  return `Auto · ${n} round${n === 1 ? "" : "s"} for ${players} players`;
}

/** "Auto rounds · Top 8", "3 rounds · Top 4", "4 rounds". */
export function roundsLine(auto: boolean, rounds: number, topCut: number, open: boolean): string {
  return (auto && open ? "Auto rounds" : `${rounds} round${rounds === 1 ? "" : "s"}`)
    + (topCut === 4 || topCut === 8 ? ` · Top ${topCut}` : "");
}

export type PageButton = "organizer" | "in" | "waitlisted" | "closed" | "sign_in" | "waitlist" | "sign_up";

/** The event page's state from its sign_up and me fields. */
export function pageButton(signedIn: boolean, signUp: string | null | undefined, me: string | null | undefined): PageButton {
  if (me === "organizer") return "organizer";
  if (me === "player") return "in";
  if (me === "waitlisted") return "waitlisted";
  if (signUp === "closed") return "closed";
  if (!signedIn) return "sign_in";
  return signUp === "full" ? "waitlist" : "sign_up";
}

const MAIN = new Set(["deck", "main", "mainboard", "main deck", "commander"]);
const SIDE = new Set(["sideboard", "side", "side board"]);
const SKIP = new Set(["considering", "maybeboard", "maybe", "tokens", "about", "companion"]);

/** Card counts in a pasted list (t1_private.decklist_counts). */
export function decklistCounts(body: string): { main: number; side: number } {
  let main = 0, side = 0, section = "main", headers = false, seen = false;
  for (const raw of body.replace(/\r/g, "").split("\n")) {
    const line = raw.trim();
    if (!line) {
      if (!headers && seen && section === "main") section = "side";
      continue;
    }
    const head = line.replace(/[:\s]*(\(\d+\))?[:\s]*$/, "").toLowerCase();
    if (MAIN.has(head)) { section = "main"; headers = true; continue; }
    if (SIDE.has(head)) { section = "side"; headers = true; continue; }
    if (SKIP.has(head)) { section = "skip"; headers = true; continue; }
    const m = /^(sb:\s*)?(\d{1,3})\s*x?\s+\S/i.exec(line);
    if (!m) continue;
    const n = Number(m[2]);
    if (m[1]) side += n;
    else if (section === "main") { main += n; seen = true; }
    else if (section === "side") side += n;
  }
  return { main, side };
}

/** The deck format that fits an event's format; null = any deck (Other constructed). */
export function deckFormat(eventFormat: string | null | undefined): string | null {
  if (!eventFormat || eventFormat === "other_constructed") return null;
  return eventFormat === "canadian_highlander" ? "canlander" : eventFormat;
}

export const decklistsLine = (sent: number, players: number) => `${sent}/${players} decklists in`;

export const countsText = (main: number, side: number) => (side > 0 ? `${main} main · ${side} sideboard` : `${main} main`);

/** "Sat 8 Nov · 18:30" in this browser's time zone. */
export function when(iso: string | null | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const day = d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  const time = d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  return `${day} · ${time}`;
}

export const CONSTRUCTED = new Set(["standard", "pioneer", "modern", "legacy", "vintage", "pauper", "premodern",
  "canadian_highlander", "other_constructed"]);
