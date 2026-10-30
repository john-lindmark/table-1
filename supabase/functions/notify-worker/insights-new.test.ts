// insights.new alert text (contract/insights-2026-10-24.md § New in Insights). `deno test notify-worker/`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { insightsNewCopy } from "./insights-new.ts";

test("a set's first draft data", () => {
  assert.deepEqual(insightsNewCopy({ insights_section: "limited", insights_key: "FRA", name: "Foundations Remastered", what: "data" }),
    { title: "New in Insights", body: "Foundations Remastered: draft data from 17Lands is in. See the best cards and colour pairs." });
});

test("a new cube version", () => {
  assert.deepEqual(insightsNewCopy({ insights_section: "limited", insights_key: "PWR-2606", name: "Arena Powered Cube · Jun 2026", what: "data" }),
    { title: "New in Insights", body: "Arena Powered Cube · Jun 2026: draft data from 17Lands is in. See the best cards." });
});

test("a new Constructed format", () => {
  assert.deepEqual(insightsNewCopy({ insights_section: "constructed", insights_key: "vintage", name: "Vintage", what: "data" }),
    { title: "New in Insights", body: "Vintage is in Insights: the metagame, matchups and decklists." });
});

test("a set to rank", () => {
  assert.deepEqual(insightsNewCopy({ insights_section: "limited", insights_key: "NEW", name: "New Horizons", what: "rank" }),
    { title: "New set to rank", body: "New Horizons is out. Rank its cards and compare with your friends." });
});
