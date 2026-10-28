/* The command zone of a Commander or Oathbreaker deck (contract/command-zone-2026-10-27.md): its cards live in the
   deck's "commander" section. Commander decks name a commander and may add a partner or background; Oathbreaker decks
   name an oathbreaker (a planeswalker) and its signature spell (an instant or sorcery). Cases shared with iOS and
   Android in testdata/command-zone/cases.json. */

export const ZONE_BOARD = "commander";
export const ZONE_FORMATS = new Set(["commander", "oathbreaker"]);

export type ZoneRole = "commander" | "partner" | "oathbreaker" | "signature";

export const ROLE_TITLE: Record<ZoneRole, string> = {
  commander: "Commander", partner: "Partner or background", oathbreaker: "Oathbreaker", signature: "Signature spell",
};
/** The slot's label above its card, short enough for half a phone's width. */
export const ROLE_LABEL: Record<ZoneRole, string> = {
  commander: "Commander", partner: "Partner", oathbreaker: "Oathbreaker", signature: "Signature spell",
};
export const ROLE_CHOOSE: Record<ZoneRole, string> = {
  commander: "Choose a commander", partner: "Add a partner or background", oathbreaker: "Choose an oathbreaker", signature: "Choose a signature spell",
};
export const ROLE_HINT: Record<ZoneRole, string> = {
  commander: "A legendary creature", partner: "Optional: a second commander", oathbreaker: "A planeswalker", signature: "An instant or sorcery",
};

/** Whether a card of this type line can fill the slot. Lenient: the deck's legality check has the last word. */
export function roleFits(role: ZoneRole, typeLine: string): boolean {
  const front = typeLine.split(" // ")[0];
  switch (role) {
    case "commander":
    case "partner":
      return front.includes("Background") || (front.includes("Legendary") && (front.includes("Creature") || front.includes("Planeswalker")));
    case "oathbreaker": return front.includes("Planeswalker");
    case "signature": return front.includes("Instant") || front.includes("Sorcery");
  }
}

export interface ZoneLine { cardId: string; typeLine: string; finish?: string; lang?: string }
export interface ZoneSlot { role: ZoneRole; cardId: string | null; finish: string; lang: string }

/** The slots a deck of this format shows, filled from its command-zone lines in order (see the contract). */
export function zoneSlots(format: string, lines: ZoneLine[]): ZoneSlot[] {
  const slot = (role: ZoneRole, l?: ZoneLine): ZoneSlot => ({ role, cardId: l?.cardId ?? null, finish: l?.finish ?? "nonfoil", lang: l?.lang ?? "en" });
  if (format === "commander") {
    const out = lines.slice(0, 2).map((l, i) => slot(i === 0 ? "commander" : "partner", l));
    if (out.length < 2) out.push(slot(out.length ? "partner" : "commander"));
    return out;
  }
  if (format === "oathbreaker") {
    return (["oathbreaker", "signature"] as ZoneRole[]).map((role) => slot(role, lines.find((l) => roleFits(role, l.typeLine))));
  }
  return [];
}

/** The lines after filling a slot: its card replaced in place, or the new card added after the others. */
export function zoneFilling(lines: ZoneLine[], slotCard: string | null, next: ZoneLine): ZoneLine[] {
  const out = lines.filter((l) => l.cardId !== next.cardId || l.cardId === slotCard);
  const i = slotCard == null ? -1 : out.findIndex((l) => l.cardId === slotCard);
  if (i >= 0) out[i] = next; else out.push(next);
  return out;
}

/** A deck line outside the command zone that could be moved in. */
export interface ZoneDeckLine { cardId: string; board: string; typeLine: string; finish?: string; lang?: string; qty?: number }

/** The deck's own cards a slot's picker offers first: main deck, then sideboard, those that fit. A deck made before the
 *  command zone has its commander in the main deck. */
export function zoneInDeck<T extends ZoneDeckLine>(role: ZoneRole, lines: T[]): T[] {
  return ["main", "side"].flatMap((b) => lines.filter((l) => l.board === b && roleFits(role, l.typeLine)));
}

/** A list_edit change that moves a deck card into a slot: every copy of a line to another section, or a count change. */
export type ZoneOp =
  | { kind: "move"; cardId: string; finish: string; lang: string; from: string; to: string }
  | { kind: "delta"; cardId: string; finish: string; lang: string; board: string; by: number };

/** The changes that put one copy of `line` in `slot`: the slot's card (if any) goes to the main deck; a single copy moves,
 *  one of several moves by deltas. */
export function zoneMovingIn(line: ZoneDeckLine, slot: ZoneSlot): ZoneOp[] {
  const finish = line.finish ?? "nonfoil", lang = line.lang ?? "en";
  const ops: ZoneOp[] = [];
  if (slot.cardId) ops.push({ kind: "move", cardId: slot.cardId, finish: slot.finish, lang: slot.lang, from: ZONE_BOARD, to: "main" });
  if ((line.qty ?? 1) <= 1) ops.push({ kind: "move", cardId: line.cardId, finish, lang, from: line.board, to: ZONE_BOARD });
  else ops.push({ kind: "delta", cardId: line.cardId, finish, lang, board: line.board, by: -1 },
                { kind: "delta", cardId: line.cardId, finish, lang, board: ZONE_BOARD, by: 1 });
  return ops;
}

/** What a command-zone line is called on the deck screen. */
export function zoneRoleName(format: string, typeLine: string): string {
  return format === "oathbreaker" ? (roleFits("oathbreaker", typeLine) ? "Oathbreaker" : "Signature spell") : "Commander";
}
