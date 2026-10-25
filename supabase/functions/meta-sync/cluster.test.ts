import { assert, assertEquals } from "jsr:@std/assert@1";
import { clusters, known, proposal, type ClusterDeck } from "./cluster.ts";

// Two archetypes with their own core and some noise each, plus singletons that belong to nothing.
const deck = (id: number, core: string[], noise: string[], colors: string): ClusterDeck => ({ id, colors, cards: [...core, ...noise] });
const burn = ["Lava Spike", "Rift Bolt", "Boltwave", "Skewer the Critics", "Goblin Guide", "Eidolon of the Great Revel"];
const tron = ["Karn, the Great Creator", "Expedition Map", "Devourer of Destiny", "Thought-Knot Seer", "Chalice of the Void"];
const decks: ClusterDeck[] = [
  ...Array.from({ length: 12 }, (_, i) => deck(i, burn, [`Flex ${i % 3}`], "R")),
  ...Array.from({ length: 9 }, (_, i) => deck(100 + i, tron, [`Tech ${i % 2}`], "")),
  ...Array.from({ length: 5 }, (_, i) => deck(200 + i, [`Odd ${i}`, `Other ${i}`], [], "G")),
];

Deno.test("groups decks that share their core; leaves the rest out", () => {
  const c = clusters(decks, 200);
  assertEquals(c.map((x) => x.size), [12, 9]);
  assertEquals(c[0].colors, "R");
  assert(burn.every((x) => c[0].signature.includes(x)));
  assertEquals(c[0].rule.length, 3);
  assert(c[0].rule.every((x) => burn.includes(x)));
  assertEquals(c[0].share, 12 / 200);
  assertEquals(clusters(decks, 200, { join: 0.4, keep: 0.35, minSize: 10 }).length, 1);
});

Deno.test("a group already known (half its signature shared) isn't proposed again", () => {
  const [b] = clusters(decks, 200);
  assertEquals(known(b, [burn.slice(0, 3)]), true);
  assertEquals(known(b, [tron]), false);
  assertEquals(known(b, [[]]), false);
});

Deno.test("proposal: Claude's name and family, rule cards only from the signature", () => {
  const [b] = clusters(decks, 200);
  assertEquals(proposal(b, { name: "Burn", family: "aggro", rule_cards: ["Lava Spike", "Made Up Card"] }),
    { name: "Burn", family: "aggro", rule: { main: ["Lava Spike"] } });
  assertEquals(proposal(b, { name: "Burn", family: "aggro", rule_cards: ["Made Up Card"] })?.rule.main, b.rule, "falls back to the cluster's own rule");
  assertEquals(proposal(b, { name: "Burn", family: "tempo", rule_cards: [] }), null);
  assertEquals(proposal(b, { name: "", family: "aggro", rule_cards: [] }), null);
  assertEquals(proposal(b, null), null);
});
