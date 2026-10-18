// Deck and cube export (contract/lists-2026-10-15.md, Export): the current version as Arena, Moxfield, MTGO or plain
// text, or as a Cube Cobra CSV. Same rules and output as iOS (ListExport.swift) and Android (ListExport.kt):
// testdata/list-export holds the files all three must write for its lists, and list-import's parser reads each one
// back as the same lines (supabase/functions/list-import/parse.test.ts).
//  - Names: double-faced, adventure and flip cards by their front face, split cards (and rooms) by both halves, the
//    way Arena, Moxfield and Cube Cobra name them.
//  - Printings are "(SET) number". A set code or collector number the importers can't read is left off (the line
//    then imports as that card's original printing).
//  - Lines sort by name, then set, collector number and finish.
import type { Catalog } from "./catalog";
import { finishOf, type Board, type Entry, type ListFinish, type ListKind } from "./lists";

export type ExportFormat = "arena" | "moxfield" | "mtgo" | "text" | "cubecobra";

export const exportFormats = (kind: ListKind): ExportFormat[] => (kind === "deck" ? ["arena", "moxfield", "mtgo", "text"] : ["cubecobra", "text"]);

export const EXPORT_LABEL: Record<ExportFormat, string> = {
  arena: "MTG Arena", moxfield: "Moxfield", mtgo: "MTGO", text: "Plain text", cubecobra: "Cube Cobra",
};
export const EXPORT_DETAIL: Record<ExportFormat, string> = {
  arena: "Deck, sideboard and commander with printings, to paste into Import",
  moxfield: "Printings, foils and considering, to paste into Import",
  mtgo: "A .txt file: the main deck, then the sideboard",
  text: "Counts and card names",
  cubecobra: "A CSV for Replace with CSV file upload",
};
/** MTGO and Cube Cobra read a file; the others are pasted, so they go out as text. */
export const EXPORT_FILE: Partial<Record<ExportFormat, "txt" | "csv">> = { mtgo: "txt", cubecobra: "csv" };

export interface ExportCard {
  name: string;
  typeLine: string;
  cmc: number;
  colors: string;
  set: string;
  cn: string;
  rarity: string;
}

export interface ExportLine {
  card: ExportCard;
  board: Board;
  qty: number;
  finish: ListFinish;
}

/** The list's lines with their cards from the catalog; `left` counts copies the catalog doesn't have. */
export function exportLines(c: Catalog, entries: Entry[]): { lines: ExportLine[]; left: number } {
  const lines: ExportLine[] = [];
  let left = 0;
  for (const e of entries) {
    const p = c.printingIndex.get(e.cardId);
    if (p === undefined) {
      left += e.qty;
      continue;
    }
    const o = c.pOracle[p];
    lines.push({
      card: { name: c.oName[o], typeLine: c.oType[o], cmc: c.oCmc[o], colors: c.oColors[o], set: c.pSet[p], cn: c.pCn[p], rarity: c.pRarity[p] },
      board: e.board, qty: e.qty, finish: finishOf(e),
    });
  }
  return { lines, left };
}

/** The name other apps know the card by. */
export function exportName(c: ExportCard): string {
  const faces = c.name.split(" // ");
  if (faces.length < 2) return c.name;
  const split = c.typeLine.split(" // ").every((t) =>
    !t.includes("Adventure") && !t.includes("Omen")
    && (t === "Instant" || t === "Sorcery" || t.startsWith("Instant — ") || t.startsWith("Sorcery — ") || t === "Enchantment — Room"));
  return split ? c.name : faces[0];
}

/** "(SET) number", or null when the importers couldn't read it back. */
export function exportPrinting(c: ExportCard): string | null {
  if (!/^[A-Za-z0-9]{2,6}$/.test(c.set) || !/^[A-Za-z0-9★†Φ_-]+$/.test(c.cn)) return null;
  return `(${c.set.toUpperCase()}) ${c.cn}`;
}

const FINISH_RANK: Record<string, number> = { nonfoil: 0, foil: 1, etched: 2 };
/** UTF-16 order, as iOS and Android sort. */
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
function order(a: ExportLine, b: ExportLine): number {
  return cmp(exportName(a.card), exportName(b.card)) || cmp(a.card.set, b.card.set) || cmp(a.card.cn, b.card.cn)
    || (FINISH_RANK[a.finish] ?? 3) - (FINISH_RANK[b.finish] ?? 3);
}

/** Sums lines that print the same, keeping the first one's place. */
function merged(lines: ExportLine[], text: (l: ExportLine) => string): string[] {
  const qty = new Map<string, number>();
  for (const l of lines) {
    const t = text(l);
    qty.set(t, (qty.get(t) ?? 0) + l.qty);
  }
  return [...qty].map(([t, q]) => `${q} ${t}`);
}

export function renderList(lines: ExportLine[], kind: ListKind, format: ExportFormat): string {
  const sorted = lines.filter((l) => l.qty > 0).sort(order);
  if (format === "cubecobra") return cubeCobra(sorted);
  const board = (...b: Board[]) => sorted.filter((l) => b.includes(l.board));
  const printed = (l: ExportLine) => [exportName(l.card), exportPrinting(l.card)].filter(Boolean).join(" ");
  let blocks: string[][] = [];
  if (format === "arena" || format === "moxfield") {
    const sections: [string, ExportLine[]][] = [["Commander", board("commander")], ["Deck", board("main")], ["Sideboard", board("side")]];
    if (format === "moxfield") sections.push(["Maybeboard", board("maybe")]);
    for (const [title, ls] of sections) {
      if (!ls.length) continue;
      const rows = format === "arena" ? merged(ls, printed)
        : merged(ls, (l) => printed(l) + (l.finish === "foil" ? " *F*" : l.finish === "etched" ? " *E*" : ""));
      blocks.push([title, ...rows]);
    }
  } else if (format === "mtgo") {
    // MTGO has no commander section: the commander goes in the sideboard, as MTGO's Commander decks do.
    blocks = [merged(board("main"), (l) => exportName(l.card)), merged(board("side", "commander"), (l) => exportName(l.card))]
      .filter((b) => b.length);
  } else {
    const sections: [string, ExportLine[]][] = kind === "deck"
      ? [["Commander", board("commander")], ["Deck", board("main")], ["Sideboard", board("side")], ["Considering", board("maybe")]]
      : [["Main", board("main", "side", "commander")], ["Considering", board("maybe")]];
    const filled = sections.filter(([, ls]) => ls.length);
    for (const [title, ls] of filled) {
      const rows = merged(ls, (l) => exportName(l.card));
      blocks.push(filled.length > 1 ? [title, ...rows] : rows);
    }
  }
  return blocks.length ? blocks.map((b) => b.join("\n")).join("\n\n") + "\n" : "";
}

/** Cube Cobra's own CSV columns and quoting (its export, which its bulk upload reads): one row per copy, the main
 *  list then Considering (maybeboard). Color Category, status, images, notes and tags are left for Cube Cobra. */
export const CUBE_COBRA_HEADER =
  "name,CMC,Type,Color,Set,Collector Number,Rarity,Color Category,status,Finish,board,maybeboard,image URL,image Back URL,tags,Notes,MTGO ID,Custom,Voucher,Artist";
const RARITY: Record<string, string> = { c: "common", u: "uncommon", r: "rare", m: "mythic", s: "special", b: "bonus" };

function cubeCobra(sorted: ExportLine[]): string {
  const q = (s: string) => `"${s.replace(/"/g, '""')}"`;
  const rows = [CUBE_COBRA_HEADER];
  for (const maybe of [false, true]) {
    for (const l of sorted) {
      if ((l.board === "maybe") !== maybe) continue;
      const c = l.card;
      const colors = [..."WUBRG"].filter((x) => c.colors.includes(x)).join("");
      const finish = l.finish === "foil" ? "Foil" : l.finish === "etched" ? "Etched" : "Non-foil";
      // Cube Cobra swaps the first dash back.
      const row = [q(exportName(c)), String(c.cmc), q(c.typeLine.replace("—", "-")), colors, q(c.set), q(c.cn), RARITY[c.rarity] ?? "", "", "",
        finish, maybe ? "maybeboard" : "mainboard", String(maybe), "", "", q(""), q(""), "", "false", "false", q("")].join(",");
      for (let i = 0; i < l.qty; i++) rows.push(row);
    }
  }
  return rows.join("\r\n") + "\r\n";
}

/** "Izzet Tempo.txt": the list's name with only letters, digits, spaces, dashes and underscores. */
export function exportFileName(listName: string, kind: ListKind, format: ExportFormat): string {
  const base = listName.replace(/[^\p{L}\p{N} _-]/gu, "").split(" ").filter(Boolean).join(" ").slice(0, 60);
  return `${base || kind}.${EXPORT_FILE[format] ?? "txt"}`;
}
