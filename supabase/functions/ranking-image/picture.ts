// A ranking's list as a picture (contract/discord-2026-10-29.md § Rankings): the apps' Top 100 image
// (contract/cube-rankings-2026-10-21.md, web screens/Rankings.tsx drawTop) on paper instead of a canvas, for the final's
// top 50 or 100 and for one color's list alike. Piles of ten in rank order, each card over the one above so only its
// name bar shows (the last in a pile whole), a rank badge on every card; header with the ranking's title and its byline.
// Card art comes in as data URLs so the renderer needs no network. Pure: tests read the markup.
import { cornerRatio } from "../deck-image/layout.ts";
import { type Art, C, FONT, type Picture, text } from "../deck-image/svg.ts";

/** The app's numbers (drawTop), in points. */
export const CW = 168, CH = Math.round((CW * 680) / 488), PEEK = 26, GAP = 14, PAD = 32, PER = 10, HEAD = 90;
/** A short list (a color of 17 cards) still gets room for its header. */
export const MIN_WIDTH = 760;
/** The most places a picture shows (the apps' top 100). */
export const MAX_CARDS = 100;

export interface RankedCard {
  name: string;
  /** The printing drawn (the cube's own, else the card's usual one); null when none is known. */
  cardId: string | null;
  set: string | null;
}

export interface RankingPictureInput {
  /** Who ranked it, then the label: "Mara Quinn · Power only". */
  title: string;
  /** "Ranking of Lindmark Cube · White · 12 of 17 ranked so far · Ranked on Table 1 · Nov 3, 2026". */
  byline: string;
  cards: RankedCard[];
  art: Map<string, Art>;
}

export function size(n: number): { width: number; height: number; piles: number } {
  const piles = Math.max(1, Math.ceil(Math.min(n, MAX_CARDS) / PER));
  const width = Math.max(MIN_WIDTH, PAD * 2 + piles * (CW + GAP) - GAP);
  const height = PAD + HEAD + 24 + (Math.min(PER, Math.max(1, n)) - 1) * PEEK + CH + PAD;
  return { width, height, piles };
}

/** The background over a card's square corner outside its radius: at corner (cx, cy), the card lying toward (dx, dy). */
export function corner(cx: number, cy: number, r: number, dx: 1 | -1, dy: 1 | -1): string {
  if (r <= 0) return "";
  const f = (v: number) => v.toFixed(2);
  // From the corner along the top or bottom edge, the quarter arc back to the side edge, then home.
  const sweep = dx === dy ? 0 : 1;
  return `<path d="M${f(cx)} ${f(cy)}H${f(cx + dx * r)}A${f(r)} ${f(r)} 0 0 ${sweep} ${f(cx)} ${f(cy + dy * r)}Z" fill="${C.bg}"/>`;
}

/** Text placed by its baseline, as the canvas does. */
const at = (s: string, x: number, baseline: number, fs: number, color: string, o: Parameters<typeof text>[5] = {}) =>
  text(s, x, baseline - fs * 0.78, fs, color, o);

export function rankingPicture(d: RankingPictureInput): Picture {
  const cards = d.cards.slice(0, MAX_CARDS);
  const { width, height } = size(cards.length);
  const parts: string[] = [`<rect width="${width}" height="${height}" fill="${C.bg}"/>`];
  parts.push(at(d.title, PAD, PAD + 28, 30, C.text, { weight: 700, max: width - PAD * 2 - 140 }));
  parts.push(at(d.byline, PAD, PAD + 56, 14, C.muted, { max: width - PAD * 2 - 140 }));
  parts.push(at("TABLE-1.SITE", width - PAD, PAD + 20, 11, C.muted, { anchor: "end", tracking: 2.5 }));
  cards.forEach((card, i) => {
    const pile = Math.floor(i / PER), k = i % PER;
    const x = PAD + pile * (CW + GAP), y = PAD + HEAD + 24 + k * PEEK;
    if (k === 0) parts.push(at(`#${i + 1}–${Math.min(i + PER, cards.length)}`, x, PAD + HEAD + 12, 12, C.muted));
    const r = CW * cornerRatio(card.set ?? "");
    const art = card.cardId ? d.art.get(card.cardId) : undefined;
    if (art?.href) {
      // No clip path: a clip is a whole extra layer per card in resvg, most of the render's CPU (2026-11-04, 546s on
      // the edge). The rounded corners are painted over in the background where they show: the pile's top card's top
      // corners and its last card's bottom ones (elsewhere a corner sits on the card above, a few pixels either way).
      parts.push(`<image x="${x}" y="${y}" width="${CW}" height="${CH}" preserveAspectRatio="none" xlink:href="${art.href}"/>`);
      if (k === 0) parts.push(corner(x, y, r, 1, 1), corner(x + CW, y, r, -1, 1));
      if (k === PER - 1 || i === cards.length - 1) parts.push(corner(x, y + CH, r, 1, -1), corner(x + CW, y + CH, r, -1, -1));
    } else {
      // No art: the name where the name bar would be, on the hover color, as the app draws it.
      parts.push(`<rect x="${x}" y="${y}" width="${CW}" height="${CH}" rx="${r.toFixed(2)}" fill="${C.hover}"/>`);
      parts.push(at(card.name, x + 8, y + 16, 11, C.text, { max: CW - 40 }));
    }
    // The rank on a white square in the name bar's right end.
    parts.push(`<rect x="${x + CW - 26}" y="${y + 4}" width="24" height="18" fill="${C.text}"/>`);
    parts.push(`<text x="${x + CW - 14}" y="${y + 17}" font-family="${FONT}" font-weight="700" font-size="${String(i + 1).length > 2 ? 10 : 11}" fill="${C.bg}" text-anchor="middle">${i + 1}</text>`);
  });
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${parts.join("")}</svg>`;
  return { svg, width, height };
}
