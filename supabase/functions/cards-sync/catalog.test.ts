// cards-sync card mapping checks. Runs under Deno (`deno test`) and Node 23+ (`node --test catalog.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { pairCode, producedMana, slimCard, tokenCardIds } from "./catalog.ts";

const card = (over: Record<string, unknown>) => ({
  id: "c1", oracle_id: "o1", name: "Test", set: "tst", collector_number: "1", games: ["paper"], ...over,
});

test("produced mana keeps Scryfall's letters in WUBRGC order", () => {
  assert.equal(producedMana(card({ type_line: "Land — Island Mountain", produced_mana: ["R", "U"] })), "UR");
  assert.equal(producedMana(card({ type_line: "Creature — Bird", produced_mana: ["W", "B", "G", "R", "U"] })), "WUBRG");
  assert.equal(producedMana(card({ type_line: "Land", produced_mana: ["C", "W"] })), "WC");
  assert.equal(producedMana(card({ type_line: "Artifact", produced_mana: ["C", "T"] })), "C");
  assert.equal(producedMana(card({ type_line: "Instant" })), "");
});

test("lands that search for basic land types make those colors; any basic land is F", () => {
  const fetch = (type_line: string, oracle_text: string, produced_mana?: string[]) =>
    producedMana(card({ type_line, oracle_text, produced_mana }));
  assert.equal(fetch("Land", "{T}, Pay 1 life, Sacrifice Polluted Delta: Search your library for an Island or Swamp card, put it onto the battlefield, then shuffle."), "UB");
  assert.equal(fetch("Land", "{T}, Sacrifice Evolving Wilds: Search your library for a basic land card, put it onto the battlefield tapped, then shuffle."), "F");
  assert.equal(fetch("Land", "{T}: Add {C}.\n{2}, {T}, Sacrifice Krosan Verge: Search your library for a Forest card and a Plains card, put them onto the battlefield tapped, then shuffle.", ["C"]), "WGC");
  assert.equal(fetch("Land", "{1}, {T}, Sacrifice Jund Panorama: Search your library for a basic Swamp, Mountain, or Forest card, put it onto the battlefield tapped, then shuffle.", ["C"]), "BRGC");
  assert.equal(fetch("Land", "{T}: Add {C}.\n{4}, {T}: Search your library for a Gate card, reveal it, put it into your hand, then shuffle.", ["C"]), "C");
  assert.equal(fetch("Land", "{T}: Add {C}.\nTransmute {1}{U}{U} ({1}{U}{U}, Discard this card: Search your library for a card with the same mana value as the discarded card, reveal it, put it into your hand, then shuffle.)", ["C"]), "C");
  // Only lands: a spell that searches for a Forest makes no mana.
  assert.equal(fetch("Sorcery", "Search your library for up to two basic land cards, reveal those cards, put one onto the battlefield tapped and the other into your hand, then shuffle."), "");
  // A spell // land card reads as its front face, so only Scryfall's letters count.
  assert.equal(producedMana(card({ type_line: "Sorcery // Land", produced_mana: ["U"], card_faces: [
    { type_line: "Sorcery", oracle_text: "Draw cards." }, { type_line: "Land", oracle_text: "{T}: Add {U}." }] })), "U");
});

test("token links are the token parts, sorted, never the card itself", () => {
  assert.deepEqual(tokenCardIds(card({ all_parts: [
    { component: "combo_piece", id: "c1" }, { component: "token", id: "t2" }, { component: "token", id: "t1" },
    { component: "token", id: "t2" }, { component: "meld_part", id: "m1" }] })), ["t1", "t2"]);
  assert.deepEqual(tokenCardIds(card({ id: "t1", all_parts: [{ component: "token", id: "t1" }] })), []);
  assert.deepEqual(tokenCardIds(card({})), []);
});

test("slimCard carries both", () => {
  const s = slimCard(card({ type_line: "Land", produced_mana: ["G"], all_parts: [{ component: "token", id: "t1" }] }));
  assert.equal(s?.produced_mana, "G");
  assert.deepEqual(s?.token_card_ids, ["t1"]);
});

test("pair codes name who a card shares the command zone with", () => {
  const code = (oracle_text: string, keywords: string[] = []) => pairCode(card({ type_line: "Legendary Creature — Human", oracle_text, keywords }));
  assert.equal(code("Partner (You can have two commanders if both have partner.)", ["Partner"]), "P");
  assert.equal(code("Flying\nPartner"), "P");
  assert.equal(code("Lifelink, partner", ["Lifelink", "Partner"]), "P");
  assert.equal(code("Partner with Toothy, Imaginary Friend (When this creature enters, target player may put Toothy into their hand.)",
                    ["Partner with"]), "P:Toothy, Imaginary Friend");
  assert.equal(code("Partner—Father & son (You can have two commanders if both have this ability.)"), "G:Father & son");
  assert.equal(code("Friends forever (You can have two commanders if both have friends forever.)", ["Friends forever"]), "F");
  assert.equal(code("Choose a Background (You can have a Background as a second commander.)", ["Choose a Background"]), "B");
  assert.equal(code("Doctor’s companion (You can have two commanders if the other is the Doctor.)"), "D");
  assert.equal(code("Doctor's companion (You can have two commanders if the other is the Doctor.)"), "D");
  assert.equal(code("Whenever you attack, create a 1/1 partner token."), "");
  assert.equal(code("Haste"), "");
  assert.equal(pairCode(card({ type_line: "Legendary Creature // Legendary Creature", card_faces: [
    { oracle_text: "Vigilance" }, { oracle_text: "Partner" }] })), "P");
  assert.equal(slimCard(card({ oracle_text: "Partner", keywords: ["Partner"] }))?.pair_code, "P");
});

test("slimCard keeps TCGplayer product ids", () => {
  const s = slimCard(card({ tcgplayer_id: 557093, tcgplayer_etched_id: 557094 }));
  assert.equal(s?.tcgplayer_id, 557093);
  assert.equal(s?.tcgplayer_etched_id, 557094);
  assert.equal(slimCard(card({}))?.tcgplayer_id, null);
});
