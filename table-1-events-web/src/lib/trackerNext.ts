/**
 * The life tracker follows its player into the next round (contract/life-tracker-options-2026-10-20.md § Next round).
 * A tracker opened on one match only listened to that match, so once the next round was paired it kept showing the
 * old one (2026-11-11). tracker_next answers with the player's match in the event's newest later round.
 * Cases: testdata/tracker-next/cases.json.
 */
export interface TrackerNextAnswer {
  round: number;
  match_id: string | null;
  bye: boolean;
}

export type TrackerNext =
  | { do: "stay" }
  /** The round is paired but its matches are still being written (events-engine inserts the round first). */
  | { do: "soon" }
  | { do: "move"; match_id: string }
  /** A bye next round: shown on the strip, the match stays. */
  | { do: "notice"; text: string };

/** How often an open tracker asks; also on returning to the page. */
export const NEXT_EVERY_MS = 15_000;
export const NEXT_SOON_MS = 2_000;

export function decideNext(current: string | null | undefined, answer: TrackerNextAnswer | null): TrackerNext {
  if (!current || !answer) return { do: "stay" };
  if (answer.match_id) return answer.match_id === current ? { do: "stay" } : { do: "move", match_id: answer.match_id };
  if (answer.bye) return { do: "notice", text: `Round ${answer.round} paired | you have a bye` };
  return { do: "soon" };
}
