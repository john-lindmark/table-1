import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { DisplayFrame, DisplayMessage, roundLabel, viewOf } from "./Display";
import { displaySize, type DisplayView } from "../lib/display";
import { demoDisplay } from "../lib/displayDemo";

// The TV display, /d/<event> (contract/public-events-leagues-2026-11-13.md § 5), drawn from the dev stand-in events.
// What's checked is what a TV must and must not show; sizes and layout are looked at in a browser.
const NOW = Date.parse("2026-11-13T18:00:00Z");
const TV = displaySize(1920, 1080);
const draw = (id: string, view: DisplayView, turns = { pairings: 0, standings: 0 }, o: { elapsed?: number; resultsIn?: number } = {}) =>
  renderToStaticMarkup(<DisplayFrame data={demoDisplay(id, { now: NOW, ...o })!} view={view} now={NOW} size={TV} width={1920} height={1080}
                                     turns={turns} origin="https://table-1.site" />);
const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("TV display", () => {
  it("has no app chrome: no back arrow, tabs or links", () => {
    for (const view of ["clock", "pairings", "standings"] as const) {
      const html = draw("demo", view);
      expect(html).not.toContain('aria-label="Back"');
      expect(html).not.toContain("<a ");
      expect(html).not.toContain("<button");
      expect(html).not.toContain("<nav");
    }
  });

  it("clock: the round, the time left and the results count", () => {
    const t = text(draw("demo", "clock"));
    expect(t).toContain("ROUND 2 OF 6");
    expect(t).toContain("38:00");
    expect(t).toContain("9/32 IN");
    expect(text(draw("demo-small", "clock"))).toContain("Paused");
    expect(text(draw("demo", "clock", undefined, { elapsed: 3135 }))).toContain("−02:15");
  });

  it("clock with the round timer off: the round and the results count only", () => {
    const html = draw("demo-off", "clock");
    expect(text(html)).toContain("ROUND 3 OF 4");
    expect(text(html)).toContain("5/8 IN");
    expect(html).not.toContain('role="timer"');
    expect(draw("demo-off", "standings")).not.toContain('role="timer"');
  });

  it("pairings: both lists, 11 rows a page at 1080, the page each is on", () => {
    const first = text(draw("demo", "pairings"));
    expect(first).toContain("A–Z 1/6");
    expect(first).toContain("By table 1/3");
    // The clock stays in the bar while a list is up.
    expect(first).toContain("38:00");
    const later = text(draw("demo", "pairings", { pairings: 4, standings: 0 }));
    expect(later).toContain("A–Z 5/6");
    expect(later).toContain("By table 2/3");
    expect(text(draw("demo-small", "pairings"))).toContain("BYE");
  });

  it("standings: rank, name, points, record, OMW; teams for a team event", () => {
    const t = text(draw("demo", "standings"));
    for (const word of ["Standings 1/3", "Pts", "Record", "OMW", "%"]) expect(t).toContain(word);
    const team = text(draw("demo-team", "standings"));
    expect(team).toContain("Team standings");
    expect(team).toContain("Team Ito");
    expect(team).toContain("Match wins");
    expect(team).not.toContain("OMW");
  });

  it("before round 1: the name, the start time and the sign-up QR's place", () => {
    const d = demoDisplay("demo-welcome", { now: NOW })!;
    expect(viewOf("standings", d.event, NOW, NOW)).toBe("welcome");
    const t = text(draw("demo-welcome", "welcome"));
    expect(t).toContain("Modern Open");
    // 18:30 tomorrow, in the machine's own time format.
    expect(t).toMatch(/(18|6)[:.]30/);
    expect(t).toContain("Sign up");
    expect(t).toContain("12/16 players");
  });

  it("after the finish: final standings, whatever was asked", () => {
    const d = demoDisplay("demo-final", { now: NOW })!;
    expect(viewOf("clock", d.event, NOW, NOW)).toBe("standings");
    expect(viewOf("auto", d.event, NOW, NOW)).toBe("standings");
    const html = draw("demo-final", "standings");
    expect(text(html)).toContain("Final standings");
    expect(html).not.toContain('role="timer"');
  });

  it("auto follows the round: pairings first, then the clock, standings once every result is in", () => {
    const at = (elapsed: number, resultsIn: number, open: number) =>
      viewOf("auto", demoDisplay("demo", { now: NOW, elapsed, resultsIn })!.event, NOW, NOW - open * 1000);
    expect(at(60, 0, 10)).toBe("pairings");
    expect(at(720, 9, 10)).toBe("clock");
    expect(at(720, 9, 105)).toBe("standings");
    expect(at(720, 0, 105)).toBe("clock");
    expect(at(2000, 32, 10)).toBe("standings");
    expect(roundLabel(demoDisplay("demo")!.event)).toBe("ROUND 2 OF 6");
  });

  it("an event the viewer can't open says so, in the same look", () => {
    const html = renderToStaticMarkup(<DisplayMessage size={TV}>This event isn&apos;t available</DisplayMessage>);
    expect(html).toContain("This event isn&#x27;t available");
    expect(html).not.toContain('aria-label="Back"');
  });
});
