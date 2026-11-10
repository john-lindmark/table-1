import faqJson from "../../../marketing/bundle/support/faq.json";
import guideJson from "../../../marketing/bundle/support/guide.json";

/*
 * Support (contract/support-2026-11-10.md): answers to common questions, written for Support, and the user-facing
 * part of the Feature Guide (tools/support/make_guide.py scrubs it), from the files the apps bundle too. Search is one
 * rule on every platform, checked against testdata/support-search/cases.json from its Python reference.
 */

export interface SupportTopic { key: string; title: string }
export interface SupportFaq { id: string; topic: string; q: string; a: string; keywords?: string[]; guide?: string }
export interface GuideSection { id: string; title: string }
/** A guide entry: its section, the subheading it sits under, its lead (the bold words it opens on) and its text. */
export interface GuideEntry { id: string; s: string; h?: string; t?: string; x: string }

export interface FaqFile { updated: string; contact: { discord: string; email: string }; topics: SupportTopic[]; faqs: SupportFaq[] }
export interface GuideFile { source: string; sections: GuideSection[]; entries: GuideEntry[] }

export const FAQ = faqJson as FaqFile;
export const GUIDE = guideJson as GuideFile;

export const STOP = new Set(["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "my", "me", "i", "is",
  "it", "do", "does", "how", "can", "what", "why", "when", "where", "you", "your", "are", "be", "at", "by", "from", "this",
  "that", "there", "as", "if", "not"]);
export const LIMIT = 50;

/** Lowercase, accents off, apostrophes dropped (don't → dont); anything else that isn't a letter or digit splits. */
export function words(text: string): string[] {
  const s = text.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/['’]/g, "");
  const out: string[] = [];
  let cur = "";
  for (const c of s) {
    if ((c >= "a" && c <= "z") || (c >= "0" && c <= "9")) cur += c;
    else if (cur) { out.push(cur); cur = ""; }
  }
  if (cur) out.push(cur);
  return out;
}

/** The words a search looks for: stop words left out (unless that leaves none), each once. */
export function queryWords(q: string): string[] {
  const all = words(q);
  const kept = all.filter((w) => !STOP.has(w));
  return [...new Set(kept.length ? kept : all)];
}

function hit(q: string, w: string): boolean {
  return w.startsWith(q) || (q.length >= 4 && q.endsWith("s") && w.startsWith(q.slice(0, -1)));
}

export type SupportDoc =
  | { kind: "faq"; id: string; faq: SupportFaq; primary: string[]; fields: [number, string[]][] }
  | { kind: "guide"; id: string; entry: GuideEntry; primary: string[]; fields: [number, string[]][] };

export function sectionTitle(id: string): string {
  return GUIDE.sections.find((s) => s.id === id)?.title ?? id;
}
export function topicTitle(key: string): string {
  return FAQ.topics.find((t) => t.key === key)?.title ?? key;
}

let corpus: SupportDoc[] | null = null;
/** Every FAQ in file order, then every guide entry, with their fields' words and weights. */
export function supportDocs(): SupportDoc[] {
  if (corpus) return corpus;
  const docs: SupportDoc[] = [];
  for (const f of FAQ.faqs) {
    docs.push({ kind: "faq", id: f.id, faq: f, primary: words(f.q), fields: [
      [4, words(f.q)], [3, words((f.keywords ?? []).join(" "))], [2, words(topicTitle(f.topic))], [1, words(f.a)]] });
  }
  for (const e of GUIDE.entries) {
    docs.push({ kind: "guide", id: e.id, entry: e, primary: words(e.t ?? e.h ?? ""), fields: [
      [3, words(e.t ?? "")], [2, words(e.h ?? "")], [2, words(sectionTitle(e.s))], [1, words(e.x)]] });
  }
  corpus = docs;
  return docs;
}

function phrase(all: string[], primary: string[]): boolean {
  if (all.length < 2) return false;
  for (let i = 0; i + all.length <= primary.length; i++) {
    if (all.every((w, j) => primary[i + j].startsWith(w))) return true;
  }
  return false;
}

export interface SupportHit { doc: SupportDoc; score: number }

/**
 * Best first: every query word must match a word's start in some field (FAQ question 4, keywords 3, topic 2,
 * answer 1; guide lead 3, subheading 2, section 2, text 1); the score is twice the best weights' sum, +6 when the
 * whole query starts the question or lead in order, +1 for an FAQ. With nothing matching every word, the docs that
 * match the most words, marked `partial`.
 */
export function supportSearch(q: string, docs: SupportDoc[] = supportDocs()): { hits: SupportHit[]; partial: boolean } {
  const none = { hits: [], partial: false };
  if (q.trim().length < 2) return none;
  const qw = queryWords(q);
  if (!qw.length) return none;
  const all = words(q);
  const scored: { matched: number; score: number; order: number; doc: SupportDoc }[] = [];
  docs.forEach((doc, order) => {
    let matched = 0;
    let sum = 0;
    for (const w of qw) {
      let b = 0;
      for (const [weight, field] of doc.fields) if (weight > b && field.some((x) => hit(w, x))) b = weight;
      if (b) { matched++; sum += b; }
    }
    if (!matched) return;
    scored.push({ matched, order, doc, score: 2 * sum + (phrase(all, doc.primary) ? 6 : 0) + (doc.kind === "faq" ? 1 : 0) });
  });
  if (!scored.length) return none;
  let full = scored.filter((s) => s.matched === qw.length);
  let partial = false;
  if (!full.length) {
    if (qw.length < 2) return none;
    const top = Math.max(...scored.map((s) => s.matched));
    full = scored.filter((s) => s.matched === top);
    partial = true;
  }
  full.sort((a, b) => b.score - a.score || (a.doc.kind === "faq" ? 0 : 1) - (b.doc.kind === "faq" ? 0 : 1) || a.order - b.order);
  return { hits: full.slice(0, LIMIT).map((s) => ({ doc: s.doc, score: s.score })), partial };
}

/** A result's row: the question, or the entry's lead (else its opening words), and where it's from. */
export function hitTitle(doc: SupportDoc): string {
  if (doc.kind === "faq") return doc.faq.q;
  return doc.entry.t ?? clip(doc.entry.x, 90);
}
export function hitDetail(doc: SupportDoc): string {
  return doc.kind === "faq" ? `FAQ · ${topicTitle(doc.faq.topic)}` : `Guide · ${sectionTitle(doc.entry.s)}`;
}

export function clip(s: string, n: number): string {
  return s.length <= n ? s : `${s.slice(0, n - 1).replace(/\s+\S*$/, "")}…`;
}

/** A section's entries grouped by subheading, in order (entries before any subheading under ""). */
export function sectionGroups(id: string): { heading: string; entries: GuideEntry[] }[] {
  const out: { heading: string; entries: GuideEntry[] }[] = [];
  for (const e of GUIDE.entries) {
    if (e.s !== id) continue;
    const h = e.h ?? "";
    const last = out[out.length - 1];
    if (last && last.heading === h) last.entries.push(e);
    else out.push({ heading: h, entries: [e] });
  }
  return out;
}

export function faqsOf(topic: string): SupportFaq[] {
  return FAQ.faqs.filter((f) => f.topic === topic);
}
