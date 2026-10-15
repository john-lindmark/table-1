// Decklist text: Moxfield, ManaBox, Arena and MTGO exports, and plain one-card-per-line cube lists.
//   4 Lightning Bolt
//   4x Lightning Bolt (2X2) 117 *F*
//   1 Thalia, Guardian of Thraben [DKA] 4
//   SB: 2 Leyline of Sanctity
// Section headers (Deck, Sideboard, Maybeboard, Considering, Commander, Companion; with or without "//" and ":")
// switch sections; without headers, the first blank line after main deck cards starts the sideboard. Lines with
// no count are one copy each, but only when no line in the list has a count (a cube list).

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
const PRINTING = /\s+[([]([A-Za-z0-9]{2,6})[)\]](?:\s+([A-Za-z0-9★†\-]+))?/;

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

export function parseList(text: string): { name?: string; entries: Line[] } {
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
