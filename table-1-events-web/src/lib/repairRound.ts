// Re-pair a round (contract/repair-round-2026-11-09.md): the Live notice that an earlier result changed after the
// current round was paired, the confirm dialog, and how a round is named. Cases: testdata/repair-round/cases.json.

export interface RepairMatch {
  isBye: boolean;
  status: string;
  resultSource?: string | null;
  updatedAt?: string | null;
}
export interface RepairRound {
  number: number;
  status: string;
  stage?: string | null;
  pairingsPublishedAt?: string | null;
  matches: RepairMatch[];
}

export interface RepairPrompt {
  round: number;
  changed: number[];
  text: string;
}

const ms = (iso: string | null | undefined) => (iso ? Date.parse(iso) : NaN);

/** The current round, if it may be re-paired: the latest round, still active. */
export function repairableRound<R extends RepairRound>(rounds: R[]): R | null {
  const latest = [...rounds].sort((a, b) => a.number - b.number).at(-1);
  return latest && latest.status === "active" ? latest : null;
}

/** "A round 2 result changed after round 3 was paired." when the organizer corrected an earlier round since. */
export function repairPrompt(rounds: RepairRound[]): RepairPrompt | null {
  const current = repairableRound(rounds);
  const paired = ms(current?.pairingsPublishedAt);
  if (!current || Number.isNaN(paired)) return null;
  const changed = rounds
    .filter((r) => r.number < current.number)
    .filter((r) => r.matches.some((m) => !m.isBye && m.resultSource === "organizer" && ms(m.updatedAt) > paired))
    .map((r) => r.number)
    .sort((a, b) => a - b);
  if (changed.length === 0) return null;
  const text = changed.length === 1
    ? `A round ${changed[0]} result changed after round ${current.number} was paired.`
    : `Results in rounds ${andList(changed.map(String))} changed after round ${current.number} was paired.`;
  return { round: current.number, changed, text };
}

const andList = (xs: string[]) => (xs.length <= 1 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs.at(-1)}`);

/** "round 3", or "the quarterfinals" / "the semifinals" / "the final" in a top 8. */
export function repairLabel(stage: string | null | undefined, number: number): string {
  switch (stage) {
    case "quarterfinal": return "the quarterfinals";
    case "semifinal": return "the semifinals";
    case "final": return "the final";
    default: return `round ${number}`;
  }
}

/** Results already in (byes and unreported matches don't count). */
export const resultsIn = (matches: RepairMatch[]) => matches.filter((m) => !m.isBye && m.status !== "pending").length;

export function repairConfirm(label: string, matches: RepairMatch[]) {
  const results = resultsIn(matches);
  const base = "New pairings from the standings as they are now. Players get their new tables and the clock starts again.";
  const cleared = results === 0 ? ""
    : results === 1 ? ` The 1 result already in for ${label} is cleared.`
    : ` The ${results} results already in for ${label} are cleared.`;
  return { title: `Re-pair ${label}?`, message: base + cleared, results };
}
