// The deck image as SVG (the web's screens/DeckImage.tsx draw(), on paper instead of a canvas): header, the card grid
// with count badges, the sideboard column behind its divider, the Table 1 mark. Card art comes in as data URLs so the
// renderer needs no network. Pure: tests read the markup.
import { ASPECT, type Card, cornerRatio, count, fit, GAP, HEADER, mainCount, ordered, PAD, type Plan, ROW_GAP, SIDE_GUTTER, WIDTH } from "./layout.ts";

export const C = { bg: "#171725", surface: "#282839", hover: "#33334a", text: "#ffffff", muted: "#c4c4ca" };
export const FONT = "JetBrains Mono";

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** A mono font's width per character, in ems. */
const EM = 0.6;

/** Cuts a line to a width in points at a font size, with an ellipsis. */
export function clip(s: string, size: number, maxWidth: number): string {
  const max = Math.max(1, Math.floor(maxWidth / (size * EM)));
  if (s.length <= max) return s;
  return s.slice(0, Math.max(1, max - 1)) + "…";
}

export interface Art {
  /** data: URL of the card's JPEG, or null when it couldn't be fetched (the tile shows the name instead). */
  href: string | null;
}

export interface Picture {
  svg: string;
  width: number;
  height: number;
}

/** The Table 1 mark: eleven tiles on a 6 × 3 grid, right-aligned at `right`, `h` tall. */
const TILES: [number, number][] = [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0], [1, 1], [4, 1], [1, 2], [3, 2], [4, 2], [5, 2]];
function logo(right: number, top: number, h: number): string {
  const w = (h * 393) / 192.69, sx = w / 393, sy = h / 192.69, x0 = right - w;
  return TILES.map(([c, r]) =>
    `<rect x="${(x0 + c * 65.8036 * sx).toFixed(2)}" y="${(top + r * 64.8302 * sy).toFixed(2)}" width="${(63.982 * sx).toFixed(2)}" height="${(63.0294 * sy).toFixed(2)}" fill="${C.text}"/>`
  ).join("");
}

function text(s: string, x: number, y: number, size: number, color: string, o: { weight?: number; tracking?: number; anchor?: "start" | "middle" | "end"; max?: number } = {}): string {
  const line = o.max ? clip(s, size, o.max) : s;
  // y is the top of the text, as on the canvas: shift down by the ascent.
  return `<text x="${x}" y="${(y + size * 0.78).toFixed(1)}" font-family="${FONT}" font-weight="${o.weight ?? 400}" font-size="${size}" fill="${color}"` +
    `${o.tracking ? ` letter-spacing="${o.tracking}"` : ""}${o.anchor ? ` text-anchor="${o.anchor}"` : ""}>${esc(line)}</text>`;
}

let clipSeq = 0;

/** A card with its count on a square badge over the top-right corner. */
function tile(c: Card, art: Art | undefined, x: number, y: number, w: number): string {
  const h = w * ASPECT;
  const r = w * cornerRatio(c.set);
  const id = `c${++clipSeq}`;
  let out = `<clipPath id="${id}"><rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${w.toFixed(2)}" height="${h.toFixed(2)}" rx="${r.toFixed(2)}"/></clipPath>`;
  if (art?.href) {
    out += `<image x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${w.toFixed(2)}" height="${h.toFixed(2)}" preserveAspectRatio="none" clip-path="url(#${id})" xlink:href="${art.href}"/>`;
  } else {
    out += `<rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${w.toFixed(2)}" height="${h.toFixed(2)}" rx="${r.toFixed(2)}" fill="${C.hover}"/>` +
      text(c.name, x + 8, y + 8, 11, C.text, { max: w - 16 });
  }
  if (c.finish !== "nonfoil") {
    out += `<rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${w.toFixed(2)}" height="${h.toFixed(2)}" clip-path="url(#${id})" fill="url(#sheen)" opacity="${c.finish === "etched" ? 0.18 : 0.3}"/>`;
  }
  const b = Math.max(18, w * 0.16);
  const label = String(c.qty);
  const fs = b * 0.55;
  const bw = Math.max(b, label.length * fs * EM + (c.qty > 9 ? 6 : 0) + 4);
  const bx = x + w + b * 0.35 - bw, by = y - b * 0.35;
  out += `<rect x="${bx.toFixed(2)}" y="${by.toFixed(2)}" width="${bw.toFixed(2)}" height="${b.toFixed(2)}" fill="${C.surface}" stroke="rgba(196,196,202,0.6)" stroke-width="1"/>` +
    `<text x="${(bx + bw / 2).toFixed(2)}" y="${(by + b / 2 + fs * 0.36).toFixed(2)}" font-family="${FONT}" font-weight="600" font-size="${fs.toFixed(2)}" fill="${C.text}" text-anchor="middle">${label}</text>`;
  return out;
}

function divider(x: number, top: number, h: number): string {
  const cy = top + h / 2;
  return `<rect x="${x.toFixed(2)}" y="${top}" width="1" height="${h.toFixed(2)}" fill="rgba(196,196,202,0.5)"/>` +
    `<rect x="${(x - 8).toFixed(2)}" y="${(cy - 40).toFixed(2)}" width="17" height="80" fill="${C.bg}"/>` +
    `<text transform="translate(${(x + 4.5).toFixed(2)} ${cy.toFixed(2)}) rotate(-90)" font-family="${FONT}" font-size="11" letter-spacing="2.5" fill="${C.muted}" text-anchor="middle">SIDEBOARD</text>`;
}

export interface PictureInput {
  name: string;
  format: string;
  player: string | null;
  plan: Plan;
  art: Map<string, Art>;
  date?: Date;
}

export function formatName(f: string): string {
  const map: Record<string, string> = {
    standard: "Standard", pioneer: "Pioneer", modern: "Modern", legacy: "Legacy", vintage: "Vintage", pauper: "Pauper",
    premodern: "Premodern", canadian_highlander: "Canadian Highlander", commander: "Commander", oathbreaker: "Oathbreaker",
    cube: "Cube", other: "Other",
  };
  return map[f] ?? f.replace(/_/g, " ").replace(/^\w/, (c) => c.toUpperCase());
}

/** The whole picture, 1200 pt wide, as tall as the cards need. */
export function picture(d: PictureInput): Picture {
  clipSeq = 0;
  const side = d.plan.side;
  const main = ordered(d.plan);
  const f = fit(main.length, side.length);
  const height = f.height;
  const parts: string[] = [];
  parts.push(`<rect width="${WIDTH}" height="${height}" fill="${C.bg}"/>`);
  parts.push(`<defs><linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1">` +
    ["#ff73bf", "#ffd966", "#73ffb3", "#59bfff", "#bf80ff", "#ff73bf"].map((col, i) => `<stop offset="${(i / 5).toFixed(2)}" stop-color="${col}"/>`).join("") +
    `</linearGradient></defs>`);
  // Header: name, "By", the line of facts; the Table 1 mark top right.
  parts.push(text(d.name, PAD, 36, 30, C.text, { weight: 700, max: WIDTH - 2 * PAD - 160 }));
  let y = 36 + 36 + 8;
  if (d.player) {
    parts.push(text(`By ${d.player}`, PAD, y, 17, C.text, { weight: 500, max: WIDTH - 2 * PAD - 160 }));
    y += 21 + 8;
  }
  const date = (d.date ?? new Date()).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const facts = [date, `Format: ${formatName(d.format)}`, `Deck: ${mainCount(d.plan)} cards`, side.length ? `Sideboard: ${count(side)} cards` : null]
    .filter(Boolean).join(" · ");
  parts.push(text(facts, PAD, y, 14, C.muted, { max: WIDTH - 2 * PAD - 160 }));
  parts.push(logo(WIDTH - PAD, 36, 30));
  parts.push(text("TABLE-1.SITE", WIDTH - PAD, 74, 11, C.muted, { tracking: 2.5, anchor: "end" }));

  const ch = f.cw * ASPECT;
  main.forEach((c, i) => parts.push(tile(c, d.art.get(c.cardId), PAD + (i % f.cols) * (f.cw + GAP), HEADER + Math.floor(i / f.cols) * (ch + ROW_GAP), f.cw)));
  if (side.length) {
    const sideX = WIDTH - PAD - f.cw;
    const mainRows = Math.ceil(main.length / f.cols);
    const h = Math.max(mainRows * ch + (mainRows - 1) * ROW_GAP, ch + (side.length - 1) * f.step);
    parts.push(divider(sideX - SIDE_GUTTER / 2, HEADER, h));
    side.forEach((c, i) => parts.push(tile(c, d.art.get(c.cardId), sideX, HEADER + i * f.step, f.cw)));
  }
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${WIDTH}" height="${height}" viewBox="0 0 ${WIDTH} ${height}">${parts.join("")}</svg>`;
  return { svg, width: WIDTH, height };
}

/** Which Scryfall size a card needs for a given drawn width in pixels: small is 146 px wide. */
export const artSize = (cardPx: number): "small" | "normal" => (cardPx > 160 ? "normal" : "small");
