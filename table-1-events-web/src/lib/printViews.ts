// Print (contract/room-tools-2026-11-13.md § 5): the organizer's pairings by table, pairings A–Z, standings and
// result slips as a page on light paper in the sideboard guide's look (lib/sideboardGuide.ts: SF Mono, uppercase
// tracked labels, hairline boxes, the teal only as the header line). Pure: a model from the event, then HTML.
// The paper is whatever the printer holds: nothing is sized to a sheet, lists flow in columns and never split a
// row, and four rows of slips fit both Letter and A4 inside the 12 mm margins.
import { pairingsByPlayer, pairingsByTable, type DisplayMatch } from "./display";
import { seatLabel } from "./leagues";
import { roundName } from "./scheduledEvents";

export type PrintWhat = "pairings" | "pairings-az" | "standings" | "slips";
export const PRINT_VIEWS: { value: PrintWhat; label: string; detail: string }[] = [
  { value: "pairings", label: "Pairings by table", detail: "Tables in order, then the byes" },
  { value: "pairings-az", label: "Pairings A–Z", detail: "Every player with their table and opponent" },
  { value: "standings", label: "Standings", detail: "Points, record and tiebreakers" },
  { value: "slips", label: "Result slips", detail: "One per match, to fill in and sign" },
];
export const isPrintWhat = (v: string | null | undefined): v is PrintWhat => PRINT_VIEWS.some((p) => p.value === v);
export const printLabel = (what: PrintWhat) => PRINT_VIEWS.find((p) => p.value === what)!.label;

/** A match as the print views read it: the display's match plus what a slip adds. */
export interface PrintMatch extends DisplayMatch {
  /** Team events: the seat this match is played in (1 = A). */
  slot?: number | null;
  /** Extra time the table was given, in seconds. */
  extraSeconds?: number;
}
export interface PrintStanding { rank: number; name: string; points: number; record: string; omw: string; gw: string; dropped?: boolean }
export interface PrintModel {
  event: string;
  /** "MODERN · MEH GAMES". */
  facts: string;
  /** "Round 2 of 4", "Semifinals"; "" before round 1. */
  round: string;
  date: string;
  matches: PrintMatch[];
  standings: PrintStanding[];
  /** Team events: each team's line above the players. */
  teams?: { rank: number; name: string; points: number; record: string }[];
  seatFormats?: string[] | null;
  /** Playoff rounds have no draws: the slip leaves the Draws box out. */
  playoff?: boolean;
}

export const printRound = (stage: string | null | undefined, number: number, of: number) => (number > 0 ? roundName(stage, number, of) : "");

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

/** The sideboard guide's page, with lists and slips in place of its matchup boxes. */
export const PRINT_CSS = "@page{margin:12mm}"
  + "*{box-sizing:border-box;margin:0;padding:0}"
  + "html{-webkit-print-color-adjust:exact;print-color-adjust:exact}"
  + "body{font-family:ui-monospace,\"SF Mono\",\"JetBrains Mono\",Menlo,Consolas,monospace;color:#171725;"
  + "background:#fff;font-size:10pt;line-height:1.35}"
  + "header{border-bottom:2px solid #00ffd9;padding-bottom:6pt;margin-bottom:8pt}"
  + ".mark,.meta,.lab,th,.cap{text-transform:uppercase;letter-spacing:.15em}"
  + ".mark{font-size:7pt;color:#545461}"
  + "h1{font-size:16pt;font-weight:600;margin:2pt 0}"
  + ".meta{font-size:7.5pt;color:#545461}"
  + ".cols{columns:2;column-gap:10pt}"
  + ".row{display:flex;gap:6pt;align-items:baseline;break-inside:avoid;border-bottom:1px solid #c4c4ca;padding:3.5pt 2pt}"
  + ".n{width:2.6em;flex:none;font-weight:600;text-align:right}"
  + ".a,.b{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}"
  + ".b{color:#545461}"
  + ".v{flex:none;color:#545461;font-size:8pt}"
  + ".x{flex:none;font-size:8pt}"
  + "table{width:100%;border-collapse:collapse}"
  + "th{font-size:6.5pt;color:#545461;font-weight:400;text-align:right;padding:2pt 4pt;border-bottom:1px solid #171725}"
  + "td{padding:3.5pt 4pt;border-bottom:1px solid #c4c4ca;text-align:right;white-space:nowrap}"
  + "th.l,td.l{text-align:left}"
  + "td.w{width:100%;white-space:normal}"
  + "tr{break-inside:avoid}"
  + ".out{text-decoration:line-through;color:#545461}"
  + ".cap{font-size:7.5pt;color:#545461;margin:10pt 0 2pt}"
  + ".pair{display:flex;gap:4mm;break-inside:avoid;margin-bottom:4mm}"
  + ".slip{flex:1;min-width:0;height:52mm;border:1px solid #171725;padding:3mm;display:flex;flex-direction:column}"
  + ".slip.none{border:0}"
  + ".top{display:flex;justify-content:space-between;align-items:baseline;border-bottom:1px solid #c4c4ca;padding-bottom:1.5mm}"
  + ".tbl{font-size:13pt;font-weight:600}"
  + ".lab{font-size:6.5pt;color:#545461}"
  + ".side{display:flex;align-items:center;gap:3mm;margin-top:2.5mm}"
  + ".who{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:10.5pt}"
  + ".box{width:9mm;height:8mm;border:1px solid #171725;flex:none}"
  + ".foot{margin-top:auto;display:flex;align-items:flex-end;gap:3mm}"
  + ".sign{flex:1;border-bottom:1px solid #171725;height:7mm}"
  + ".empty{color:#545461;padding:12pt 0}";

function page(m: PrintModel, what: PrintWhat, body: string): string {
  const meta = [m.facts, m.round, printLabel(what), m.date].filter(Boolean).map(esc).join(" · ");
  return '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
    + `<title>${esc(m.event)} · ${esc(printLabel(what))}</title>\n<style>${PRINT_CSS}</style>\n</head>\n<body>\n<header>\n`
    + `<div class="mark">Table 1</div>\n<h1>${esc(m.event)}</h1>\n<div class="meta">${meta}</div>\n</header>\n<main>\n${body}</main>\n</body>\n</html>\n`;
}

const extra = (seconds: number | undefined) => (seconds && seconds > 0 ? `+${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}` : "");

function byTable(m: PrintModel): string {
  const rows = pairingsByTable(m.matches);
  if (rows.length === 0) return '<p class="empty">No pairings yet</p>\n';
  // The display's rows carry no extra time: read it back by table.
  const extraOf = new Map(m.matches.filter((x) => !x.isBye && x.tableNumber != null).map((x) => [String(x.tableNumber), extra(x.extraSeconds)]));
  return `<div class="cols">\n${rows.map((r) => `<div class="row"><span class="n">${esc(r.table === "BYE" ? "–" : r.table)}</span>`
    + `<span class="a">${esc(r.a)}</span>${r.bye ? '<span class="v">BYE</span>' : `<span class="v">v</span><span class="a">${esc(r.b ?? "")}</span>`}`
    + `${extraOf.get(r.table) ? `<span class="x">${extraOf.get(r.table)}</span>` : ""}</div>`).join("\n")}\n</div>\n`;
}

function byPlayer(m: PrintModel): string {
  const rows = pairingsByPlayer(m.matches);
  if (rows.length === 0) return '<p class="empty">No pairings yet</p>\n';
  return `<div class="cols">\n${rows.map((r) => `<div class="row"><span class="a">${esc(r.name)}</span>`
    + `<span class="n">${esc(r.bye ? "BYE" : r.table)}</span><span class="b">${esc(r.opponent ?? "")}</span></div>`).join("\n")}\n</div>\n`;
}

function standings(m: PrintModel): string {
  if (m.standings.length === 0) return '<p class="empty">No players yet</p>\n';
  let out = "";
  if (m.teams?.length) {
    out += '<table>\n<tr><th>#</th><th class="l">Team</th><th>Pts</th><th>Record</th></tr>\n'
      + m.teams.map((t) => `<tr><td>${t.rank}</td><td class="l w">${esc(t.name)}</td><td><b>${t.points}</b></td><td>${esc(t.record)}</td></tr>`).join("\n")
      + '\n</table>\n<p class="cap">Players</p>\n';
  }
  return out + '<table>\n<tr><th>#</th><th class="l">Player</th><th>Pts</th><th>Record</th><th>OMW</th><th>GW</th></tr>\n'
    + m.standings.map((s) => `<tr><td>${s.rank}</td><td class="l w${s.dropped ? " out" : ""}">${esc(s.name)}</td><td><b>${s.points}</b></td>`
      + `<td>${esc(s.record)}</td><td>${esc(s.omw)}</td><td>${esc(s.gw)}</td></tr>`).join("\n")
    + "\n</table>\n";
}

/** One slip per match (byes have nothing to report), two across, four rows a page. */
function slips(m: PrintModel): string {
  const matches = m.matches.filter((x) => !x.isBye).sort((a, b) => (a.tableNumber ?? 0) - (b.tableNumber ?? 0));
  if (matches.length === 0) return '<p class="empty">No matches to report</p>\n';
  const name = (x: PrintMatch, side: number) => x.sides.find((s) => s.side === side)?.displayName || "—";
  const slip = (x: PrintMatch) => {
    const seat = x.slot ? seatLabel(x.slot, m.seatFormats) : "";
    return '<div class="slip">'
      + `<div class="top"><span class="tbl">Table ${x.tableNumber ?? "–"}</span><span class="lab">${esc([m.round, seat, extra(x.extraSeconds)].filter(Boolean).join(" · "))}</span></div>`
      + `<div class="side"><span class="who">${esc(name(x, 0))}</span><span class="lab">Games won</span><span class="box"></span></div>`
      + `<div class="side"><span class="who">${esc(name(x, 1))}</span><span class="lab">Games won</span><span class="box"></span></div>`
      + `<div class="foot">${m.playoff ? "" : '<span class="lab">Draws</span><span class="box"></span>'}<span class="lab">Signed</span><span class="sign"></span></div>`
      + "</div>";
  };
  let out = "";
  for (let i = 0; i < matches.length; i += 2) {
    out += `<div class="pair">${slip(matches[i])}${matches[i + 1] ? slip(matches[i + 1]) : '<div class="slip none"></div>'}</div>\n`;
  }
  return out;
}

/** The printed page for one of the four views. */
export function printHtml(what: PrintWhat, m: PrintModel): string {
  return page(m, what, what === "pairings" ? byTable(m) : what === "pairings-az" ? byPlayer(m) : what === "standings" ? standings(m) : slips(m));
}

/** How many slips a page holds (two across, four rows), for the preview's count. */
export const SLIPS_PER_PAGE = 8;
