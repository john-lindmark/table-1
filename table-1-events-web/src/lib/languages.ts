/* Card language (contract/card-language-2026-10-19.md). Every owned copy, binder copy and trade line has a language
   (Scryfall's codes); it can be changed wherever such a copy shows. Changing owned copies moves them to the new
   language in the same places (binders, Unsorted), as one undoable batch. Same rules as iOS `Languages.swift`. */
import type { CollectionOp, Item } from "./collection";

/** Scryfall's language codes: the eleven most printed first, then the rest. */
export const LANGUAGES: { code: string; name: string }[] = [
  { code: "en", name: "English" }, { code: "de", name: "German" }, { code: "fr", name: "French" }, { code: "it", name: "Italian" },
  { code: "es", name: "Spanish" }, { code: "pt", name: "Portuguese" }, { code: "ja", name: "Japanese" }, { code: "ko", name: "Korean" },
  { code: "ru", name: "Russian" }, { code: "zhs", name: "Chinese Simplified" }, { code: "zht", name: "Chinese Traditional" },
  { code: "he", name: "Hebrew" }, { code: "la", name: "Latin" }, { code: "grc", name: "Ancient Greek" }, { code: "ar", name: "Arabic" },
  { code: "sa", name: "Sanskrit" }, { code: "ph", name: "Phyrexian" }, { code: "qya", name: "Quenya" },
];
export const COMMON_LANGUAGES = 11;

export const languageName = (code: string) => LANGUAGES.find((l) => l.code === code)?.name ?? code.toUpperCase();

/** The language new copies go in as: a non-English printing is in its own language; otherwise the one picked for adds. */
export const langForNew = (printingLang: string, picked: string) => (printingLang !== "en" ? printingLang : picked);

/** Unsorted as a place (the binder route id). */
const UNSORTED = "unsorted";

/**
 * Moves `qty` copies of an item to another language, each copy staying where it is: from `from` when given (a binder id
 * or Unsorted), else Unsorted first, then binders in the order given. Null when nothing would change.
 */
export function languageChangeOps(item: Pick<Item, "cardId" | "finish" | "condition" | "lang" | "qty">, places: { place: string; qty: number }[],
                                  to: string, qty: number, from?: string | null): CollectionOp[] | null {
  if (to === item.lang || qty <= 0 || qty > item.qty) return null;
  const order = from != null ? places.filter((p) => p.place === from)
    : [...places.filter((p) => p.place === UNSORTED), ...places.filter((p) => p.place !== UNSORTED)];
  let left = qty;
  const ops: CollectionOp[] = [];
  for (const p of order) {
    if (left <= 0) break;
    const n = Math.min(left, p.qty);
    if (n <= 0) continue;
    const where = p.place === UNSORTED ? {} : { binder_id: p.place };
    ops.push({ card_id: item.cardId, finish: item.finish, condition: item.condition, lang: item.lang, delta: -n, ...where });
    ops.push({ card_id: item.cardId, finish: item.finish, condition: item.condition, lang: to, delta: n, ...where });
    left -= n;
  }
  return left === 0 ? ops : null;
}

const ADD_LANG_KEY = "table1.library.addLang";

/** The language picked for new copies (shared by card detail, binder adds and trades), remembered per browser. */
export function storedAddLang(): string {
  try {
    return localStorage.getItem(ADD_LANG_KEY) ?? "en";
  } catch {
    return "en";
  }
}

export function storeAddLang(code: string) {
  try {
    localStorage.setItem(ADD_LANG_KEY, code);
  } catch {
    /* storage blocked: kept for this screen */
  }
}
