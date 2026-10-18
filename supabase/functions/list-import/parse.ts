// Decklist text: Moxfield, ManaBox, Arena and MTGO exports, and plain one-card-per-line cube lists.
//   4 Lightning Bolt
//   4x Lightning Bolt (2X2) 117 *F*
//   1 Thalia, Guardian of Thraben [DKA] 4
//   SB: 2 Leyline of Sanctity
// Section headers (Deck, Sideboard, Maybeboard, Considering, Commander, Companion; with or without "//" and ":")
// switch sections; without headers, the first blank line after main deck cards starts the sideboard. Lines with
// no count are one copy each, but only when no line in the list has a count (a cube list).
// A CSV with a name column and a set, collector number or board column (Cube Cobra's export and bulk upload, or
// a collection export) is read by its columns instead: one copy per row unless it has a count column.

export interface Line {
  qty: number;
  board: "main" | "side" | "maybe" | "commander";
  name: string;
  set?: string;
  cn?: string;
  scryfall_id?: string;
  finish?: "foil" | "etched";
}

const HEADER = /^(?:\/\/\s*)?(deck|main|mainboard|main deck|sideboard|side|side board|maybe|maybeboard|considering|commander|companion|tokens?)\s*:?\s*(?:\(\d+\))?\s*$/i;
const CARD = /^(\d{1,3})\s*x?\s+(.+?)\s*$/i;
const PRINTING = /\s+[([]([A-Za-z0-9]{2,6})[)\]](?:\s+([A-Za-z0-9★†Φ_\-]+))?/;

function boardFor(header: string): Line["board"] | "skip" {
  const h = header.toLowerCase();
  if (h.startsWith("side") || h === "companion") return "side";
  if (h.startsWith("maybe") || h === "considering") return "maybe";
  if (h === "commander") return "commander";
  if (h.startsWith("token")) return "skip";
  return "main";
}

/** One card name and its printing details, with export decorations removed. */
function cardOf(rest: string): Omit<Line, "qty" | "board"> | null {
  let s = rest.replace(/\s+#\S+(\s+#\S+)*\s*$/, ""); // Moxfield tags
  let finish: Line["finish"];
  const fm = s.match(/\s+\*([FE])\*\s*$/i) ?? s.match(/\s+\((foil|etched)\)\s*$/i);
  if (fm) {
    finish = /^e/i.test(fm[1]) ? "etched" : "foil";
    s = s.slice(0, fm.index);
  }
  let set: string | undefined, cn: string | undefined;
  const pm = s.match(PRINTING);
  if (pm && pm.index !== undefined) {
    set = pm[1].toLowerCase();
    cn = pm[2];
    s = s.slice(0, pm.index);
  }
  const name = s.trim();
  return name ? { name, set, cn, finish } : null;
}

/** RFC 4180 rows: quoted fields may hold commas, doubled quotes and line breaks. */
function csvRows(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; }
    else if (c !== "\r") field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((f) => f.trim()));
}

/** Cube Cobra's CSV (name, CMC, Type, …, Set, Collector Number, Finish, board, maybeboard, …) and other card CSVs. */
function parseCsv(text: string): Line[] | null {
  const rows = csvRows(text);
  const head = (rows[0] ?? []).map((h) => h.trim().toLowerCase());
  const col = (...names: string[]) => head.findIndex((h) => names.includes(h));
  const name = col("name", "card name", "card");
  const set = col("set", "set code", "edition"), cn = col("collector number", "card number", "number");
  const board = col("board"), maybe = col("maybeboard"), finish = col("finish", "foil"), count = col("count", "quantity", "qty");
  if (name < 0 || (set < 0 && cn < 0 && board < 0 && maybe < 0)) return null;
  const out: Line[] = [];
  for (const r of rows.slice(1)) {
    const at = (i: number) => (i >= 0 ? (r[i] ?? "").trim() : "");
    if (!at(name)) continue;
    const b = at(board).toLowerCase().replace(/\s+/g, "");
    const f = at(finish).toLowerCase();
    out.push({
      qty: count >= 0 ? Number(at(count)) || 0 : 1,
      board: b.startsWith("maybe") || (!b && at(maybe).toLowerCase() === "true") ? "maybe" : b.startsWith("side") ? "side" : b === "commander" ? "commander" : "main",
      name: at(name),
      set: /^[A-Za-z0-9]{2,6}$/.test(at(set)) ? at(set).toLowerCase() : undefined,
      cn: at(cn) || undefined,
      finish: f.includes("etched") ? "etched" : /foil/.test(f) && !/^non/.test(f) ? "foil" : undefined,
    });
  }
  return out;
}

export function parseList(text: string): { name?: string; entries: Line[] } {
  const csv = parseCsv(text.replace(/^\uFEFF/, "").trimStart());
  if (csv) return { entries: csv };
  const counted: Line[] = [];
  const bare: Line[] = [];
  let board: Line["board"] | "skip" = "main";
  let headers = false;
  let name: string | undefined;
  let seenMain = false;
  let lastBlank = false;
  const lines = text.replace(/\r/g, "").split("\n");
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i].trim();
    if (!raw) {
      lastBlank = true;
      continue;
    }
    // Arena "About / Name <deck>" block.
    if (/^about$/i.test(raw)) continue;
    const nm = raw.match(/^name\s+(.+)$/i);
    if (nm && !CARD.test(raw)) {
      name = nm[1].trim();
      continue;
    }
    const h = raw.match(HEADER);
    if (h) {
      board = boardFor(h[1]);
      headers = true;
      lastBlank = false;
      continue;
    }
    let line = raw;
    let lineBoard = board;
    if (/^sb:\s*/i.test(line)) {
      line = line.replace(/^sb:\s*/i, "");
      lineBoard = "side";
    } else if (lastBlank && !headers && seenMain && board === "main") {
      board = "side";
      lineBoard = "side";
    }
    lastBlank = false;
    if (lineBoard === "skip" || line.startsWith("//") || line.startsWith("#")) continue;
    const m = line.match(CARD);
    if (m) {
      const c = cardOf(m[2]);
      if (!c) continue;
      counted.push({ qty: Number(m[1]), board: lineBoard, ...c });
      if (lineBoard === "main") seenMain = true;
    } else {
      const c = cardOf(line);
      if (c) bare.push({ qty: 1, board: lineBoard, ...c });
    }
  }
  return { name, entries: counted.length ? counted : bare };
}
