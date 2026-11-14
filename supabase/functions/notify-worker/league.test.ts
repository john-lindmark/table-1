// Alert text for leagues (contract/public-events-leagues-2026-11-13.md § Notifications).
import { test } from "node:test";
import assert from "node:assert/strict";
import { judgeCallCopy, leagueCopy, publicNewCopy } from "./league.ts";

const mms = { league_name: "The Mountain Magic Series", season_name: "2026" };

test("a new event", () => {
  assert.deepEqual(leagueCopy("league.event", { ...mms, event_name: "Modern Open", format_label: "Modern", venue_name: "MeH Games" }),
    { title: "The Mountain Magic Series · 2026", body: "New event: Modern Open · Modern · MeH Games" });
  assert.equal(leagueCopy("league.event", { ...mms, event_name: "Modern", format_label: "Modern" }).body, "New event: Modern");
  assert.equal(leagueCopy("league.event", { ...mms, event_name: "Players Championship", final: true }).body,
    "The final is set: Players Championship");
});

test("results", () => {
  assert.equal(leagueCopy("league.results", { ...mms, event_name: "Modern Open", winner: "Bea" }).body, "Bea won Modern Open. Standings are updated.");
  assert.equal(leagueCopy("league.results", { ...mms, event_name: "Team Trios", winner: "Ann, Bo, Cy" }).body, "Ann, Bo, Cy won Team Trios. Standings are updated.");
  assert.equal(leagueCopy("league.results", { ...mms, event_name: "Modern Open" }).body, "Modern Open is in. Standings are updated.");
});

test("qualified", () => {
  assert.equal(leagueCopy("league.qualified", { ...mms, how: "winner", event_name: "Modern Open" }).body, "You qualified for the final by winning Modern Open.");
  assert.equal(leagueCopy("league.qualified", { ...mms, how: "points" }).body, "You qualified for the final on points.");
});

test("the season ends", () => {
  assert.equal(leagueCopy("league.season", { ...mms, first: "Bea" }).body, "The season is over. Bea finished first.");
  assert.equal(leagueCopy("league.season", mms).body, "The season is over. Final standings are up.");
});

test("titles", () => {
  assert.equal(leagueCopy("league.season", { league_name: "Friday Night 2026", season_name: "2026" }).title, "Friday Night 2026");
  assert.equal(leagueCopy("league.season", {}).title, "A league you follow");
});

test("a new public event", () => {
  assert.deepEqual(publicNewCopy({ event_name: "Modern Open", format_label: "Modern", venue_name: "MeH Games", near: true }),
    { title: "New Modern event near you", body: "Modern Open · MeH Games" });
  assert.deepEqual(publicNewCopy({ event_name: "Friday draft", format_label: "Draft · Bloomburrow", near: false }),
    { title: "New Draft event", body: "Friday draft" });
  assert.equal(publicNewCopy({}).title, "New event");
});

test("a judge call", () => {
  assert.deepEqual(judgeCallCopy({ table_number: 7, event_name: "Modern Open", by: "Bea" }), { title: "Judge! Table 7", body: "Modern Open · Bea" });
  assert.deepEqual(judgeCallCopy({}), { title: "Judge!", body: "A table is calling a judge." });
});
