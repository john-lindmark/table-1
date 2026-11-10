// Popular cube sources (popular.ts) on trimmed copies of the real pages (testdata/popular-cubes/, 2026-11-10).
import { assertEquals } from "jsr:@std/assert@1";
import { cubeCobraCards, mtgoCards, scryfallCards, unescapeHtml } from "./popular.ts";

const dir = new URL("../../../testdata/popular-cubes/", import.meta.url);
const read = (f: string) => Deno.readTextFileSync(new URL(f, dir));

Deno.test("mtgo: the current list only, past the header row, names unescaped", () => {
  const cards = mtgoCards(read("mtgo.html"));
  assertEquals(cards.length, 6);
  assertEquals(cards.slice(0, 3).map((c) => c.name), ["Aang's Iceberg", "Abandoned Air Temple", "Adeline, Resplendent Cathar"]);
});

Deno.test("mtgo: a page without the heading reads nothing (the put keeps the old list)", () => {
  assertEquals(mtgoCards("<table><tr><td>White</td><td>Swords to Plowshares</td></tr></table>"), []);
});

Deno.test("cube cobra: main board with printings, no basics", () => {
  const cards = cubeCobraCards(JSON.parse(read("cubecobra.json")));
  assertEquals(cards.length, 4);
  assertEquals(cards[0], { name: "Giver of Runes", card_id: "4e117771-5a8b-4812-b487-32ba34b7f724" });
});

Deno.test("scryfall: each card with its printing and Oracle id", () => {
  const cards = scryfallCards(JSON.parse(read("scryfall.json")));
  assertEquals(cards.length, 3);
  assertEquals(cards[0].name, "Ajani, Nacatl Pariah // Ajani, Nacatl Avenger");
  assertEquals(cards[0].oracle_id, "2588f348-d7a3-46c8-9ace-dca53ed5ef99");
});

Deno.test("entities", () => {
  assertEquals(unescapeHtml("Jace&#8217;s &amp; Tom&#x27;s &rsquo;"), "Jace’s & Tom's ’");
});
