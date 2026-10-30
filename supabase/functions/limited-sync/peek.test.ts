// Which cube run a 17Lands file holds, from its first bytes (real FRA slices in testdata/insights/limited).
import { assertEquals } from "jsr:@std/assert@1";
import { firstRows, peekOf, PEEK_BYTES } from "./peek.ts";

const T = "../../testdata/insights/limited";

Deno.test("a game file's first draft day and the cards in its header", async () => {
  const file = await Deno.readFile(`${T}/game.csv.gz`);
  const p = peekOf("game", firstRows(file.subarray(0, PEEK_BYTES), file.length)!)!;
  assertEquals(p.started, "2026-09-29");
  assertEquals(p.names.length, 295);
  assertEquals(p.names.includes("Violent Echoes"), true);
});

Deno.test("a draft file's, from its pack columns", async () => {
  const file = await Deno.readFile(`${T}/draft.csv.gz`);
  const p = peekOf("draft", firstRows(file.subarray(0, PEEK_BYTES), file.length)!)!;
  assertEquals(p.started, "2026-09-29");
  assertEquals(p.names.includes("Violent Echoes"), true);
});

Deno.test("the run starts at the earliest draft read, whatever the rows' order", () => {
  assertEquals(peekOf("game", { cols: ["draft_time", "deck_A", "deck_B"], days: ["2025-11-04", "2025-10-30", "2025-11-08"] }),
    { started: "2025-10-30", names: ["A", "B"], rows: 3 });
});

Deno.test("rows with no draft day aren't a run", () => {
  assertEquals(peekOf("game", { cols: ["expansion", "draft_time"], days: ["", "None"] }), null);
});
