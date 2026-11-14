import { describe, expect, it } from "vitest";
import { PRINT_VIEWS, isPrintWhat, printHtml, printRound, type PrintModel } from "./printViews";

// Print (contract/room-tools-2026-11-13.md § 5): the four views as pages on light paper.

const model: PrintModel = {
  event: "Modern Open <Finals>", facts: "Modern · MeH Games", round: "Round 2 of 4", date: "2026-11-13",
  matches: [
    { tableNumber: 2, isBye: false, status: "pending", gameDraws: 0, extraSeconds: 300,
      sides: [{ side: 0, displayName: "Cy Park", gameWins: 0 }, { side: 1, displayName: "Dee Okafor", gameWins: 0 }] },
    { tableNumber: 1, isBye: false, status: "confirmed", gameDraws: 0,
      sides: [{ side: 0, displayName: "Bo Lindqvist", gameWins: 2 }, { side: 1, displayName: "Ann Ito", gameWins: 1 }] },
    { tableNumber: null, isBye: true, status: "confirmed", gameDraws: 0, sides: [{ side: 0, displayName: "Eli Moreau", gameWins: 2 }] },
  ],
  standings: [
    { rank: 1, name: "Bo Lindqvist", points: 6, record: "2-0", omw: "66.7%", gw: "80.0%" },
    { rank: 2, name: "Eli Moreau", points: 3, record: "1-1", omw: "50.0%", gw: "50.0%", dropped: true },
  ],
};
const body = (html: string) => html.slice(html.indexOf("<main>"));
const order = (html: string, ...names: string[]) => names.map((n) => html.indexOf(n));

describe("print views", () => {
  it("names the four views, in the menu's order", () => {
    expect(PRINT_VIEWS.map((v) => v.value)).toEqual(["pairings", "pairings-az", "standings", "slips"]);
    expect(isPrintWhat("slips")).toBe(true);
    expect(isPrintWhat("decklists")).toBe(false);
    expect(isPrintWhat(undefined)).toBe(false);
  });

  it("every page: light paper, the teal header line, the event and what it is, nothing sized to one sheet", () => {
    for (const v of PRINT_VIEWS) {
      const html = printHtml(v.value, model);
      expect(html.startsWith("<!doctype html>")).toBe(true);
      expect(html).toContain("background:#fff");
      expect(html).toContain("border-bottom:2px solid #00ffd9");
      expect(html).toContain("<h1>Modern Open &lt;Finals&gt;</h1>");          // names are escaped
      expect(html).toContain(`Modern · MeH Games · Round 2 of 4 · ${v.label} · 2026-11-13`);
      // Letter and A4 alike: margins only, the printer's own paper.
      expect(html).toContain("@page{margin:12mm}");
      expect(html).not.toMatch(/@page\{[^}]*size/);
    }
  });

  it("pairings by table: tables in order, then the bye; extra time on its row", () => {
    const html = body(printHtml("pairings", model));
    const [bo, cy, eli] = order(html, "Bo Lindqvist", "Cy Park", "Eli Moreau");
    expect(bo).toBeGreaterThan(0);
    expect(bo).toBeLessThan(cy);
    expect(cy).toBeLessThan(eli);
    expect(html).toContain('<span class="v">BYE</span>');
    expect(html).toContain('<span class="x">+5:00</span>');
    expect(html.match(/class="row"/g)).toHaveLength(3);
  });

  it("pairings A–Z: one row per player with their table and opponent", () => {
    const html = body(printHtml("pairings-az", model));
    const at = order(html, ">Ann Ito<", ">Bo Lindqvist<", ">Cy Park<", ">Dee Okafor<", ">Eli Moreau<");
    expect([...at].sort((a, b) => a - b)).toEqual(at);
    expect(html.match(/class="row"/g)).toHaveLength(5);
    expect(html).toContain('<span class="a">Ann Ito</span><span class="n">1</span><span class="b">Bo Lindqvist</span>');
    expect(html).toContain('<span class="a">Eli Moreau</span><span class="n">BYE</span>');
  });

  it("standings: points, record and tiebreakers; a dropped player struck through; teams first in a team event", () => {
    const html = body(printHtml("standings", model));
    expect(html).toContain("<td>1</td><td class=\"l w\">Bo Lindqvist</td><td><b>6</b></td><td>2-0</td><td>66.7%</td><td>80.0%</td>");
    expect(html).toContain('class="l w out">Eli Moreau');
    const team = body(printHtml("standings", { ...model, teams: [{ rank: 1, name: "Glacial Chasm", points: 6, record: "2-0" }] }));
    expect(team.indexOf("Glacial Chasm")).toBeLessThan(team.indexOf("Bo Lindqvist"));
    expect(team).toContain('<p class="cap">Players</p>');
  });

  it("result slips: one per match (never a bye), boxes for game wins and draws, a line to sign", () => {
    const html = body(printHtml("slips", model));
    expect(html.match(/class="slip"/g)).toHaveLength(2);
    expect(html.match(/class="slip none"/g)).toBeNull();                       // two matches fill the row
    expect(html).not.toContain("Eli Moreau");
    expect(html.indexOf("Table 1")).toBeLessThan(html.indexOf("Table 2"));
    expect(html.match(/Games won/g)).toHaveLength(4);
    expect(html.match(/class="box"/g)).toHaveLength(6);                        // two game boxes and a draws box a slip
    expect(html.match(/class="sign"/g)).toHaveLength(2);
    expect(html).toContain("Round 2 of 4 · +5:00");
    // An odd match out leaves an empty place beside it; a playoff has no draws to write down.
    const three = body(printHtml("slips", { ...model, matches: [...model.matches, { ...model.matches[0], tableNumber: 3 }], playoff: true }));
    expect(three.match(/class="slip"/g)).toHaveLength(3);
    expect(three.match(/class="slip none"/g)).toHaveLength(1);
    expect(three).not.toContain("Draws");
  });

  it("a team event's slip says the seat", () => {
    const html = printHtml("slips", { ...model, seatFormats: ["modern", "standard", "pioneer"], matches: [{ ...model.matches[1], slot: 2 }] });
    expect(html).toContain("Round 2 of 4 · B · STANDARD");
  });

  it("nothing to print reads as that", () => {
    const empty = { ...model, matches: [], standings: [], round: "" };
    expect(printHtml("pairings", empty)).toContain("No pairings yet");
    expect(printHtml("pairings-az", empty)).toContain("No pairings yet");
    expect(printHtml("standings", empty)).toContain("No players yet");
    expect(printHtml("slips", empty)).toContain("No matches to report");
    expect(printHtml("slips", empty)).toContain("Modern · MeH Games · Result slips · 2026-11-13");
  });

  it("the round's name", () => {
    expect(printRound("swiss", 2, 4)).toBe("Round 2 of 4");
    expect(printRound("semifinal", 5, 4)).toBe("Semifinals");
    expect(printRound(null, 0, 4)).toBe("");
  });
});
