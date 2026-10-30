// The first rows of a 17Lands file, to tell which run of an Arena cube it holds (contract/insights-2026-10-24.md
// § Arena cubes): the run's first draft day and the card names in the header. One ranged read of the file's start.
// Rows aren't in time order (Arena Powered Cube's first row is from day 6 of its run), so the run's first day is the
// earliest draft among the ~1,000 rows the read holds.
import { inflateMembers, startAt } from "./members.ts";
import { headerColumns, Lines } from "./parse.ts";

/** Bytes read from the file's start: a game header is ~40 KB of CSV, a row ~3 KB. */
export const PEEK_BYTES = 1_000_000;
/** Stop this short of the slice's end (deflate blocks are tens of KB), as the slices do. */
const RESERVE = 256 * 1024;
const OUT_BYTES = 4 << 20;
const NAME_PREFIX = { game: "deck_", draft: "pack_card_" } as const;

export interface Peek { started: string; names: string[]; rows: number }

/** The header and each row's draft day from `data` (the file's first bytes); null without a header and a row. */
export function firstRows(data: Uint8Array, total: number): { cols: string[]; days: string[] } | null {
  let cols: string[] | null = null, at = -1;
  const days: string[] = [];
  const dec = new TextDecoder();
  const lines = new Lines(new Uint8Array(0), (b) => {
    if (!cols) { cols = headerColumns(dec.decode(b)); at = cols.indexOf("draft_time"); return; }
    if (at < 0) return;
    // the draft time sits among the first few short fields: decode only the line's start
    const f = dec.decode(b.subarray(0, 400)).split(",");
    if (f.length > at) days.push(f[at].slice(0, 10));
  });
  try {
    inflateMembers(data, 0, total, startAt(data, 0, null, new Uint8Array(0)), RESERVE, OUT_BYTES, (o) => lines.push(o));
  } catch {
    // a broken block near the end: what came before it still counts
  }
  return cols && days.length ? { cols, days } : null;
}

/** The run's first draft day (UTC) and its cards, from a file's first rows. */
export function peekOf(kind: "game" | "draft", rows: { cols: string[]; days: string[] }): Peek | null {
  const days = rows.days.filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d)).sort();
  if (!days.length) return null;
  const prefix = NAME_PREFIX[kind];
  const names = [...new Set(rows.cols.filter((c) => c.startsWith(prefix)).map((c) => c.slice(prefix.length)))];
  return { started: days[0], names, rows: days.length };
}
