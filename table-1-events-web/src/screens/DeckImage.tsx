import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, GhostAction, Notice, Segmented, SwitchRow } from "../components/kit";
import { ZoomablePreview } from "../components/ZoomImage";
import { cardImageUrl, cornerRatio, formatName, type Catalog } from "../lib/catalog";
import { type Grouping } from "../lib/cardGrouping";
import {
  ASPECT, GAP, HEADER, PAD, ROW_GAP, SIDE_GUTTER, WIDTH, columns, count, fileName, fit, mainCount, ordered, plan, rows,
  type DeckImageCard, type DeckImageLayout, type Plan, type PlanLine,
} from "../lib/deckImage";
import { supabase } from "../lib/supabaseClient";
import { capture } from "../lib/telemetry";
import type { Entry } from "../lib/lists";
import { resolveLines } from "./Lists";

/* Deck image on the web (contract/deck-image-2026-10-20.md): the deck as one picture in melee.gg's visual decklist
   format, drawn on a canvas from Scryfall's card images (their CDN allows cross-origin reads), then Download (a JPEG)
   or Share (the system share sheet where the browser can share files; otherwise the image is copied). Layout rules
   are lib/deckImage's, the same as iOS and Android. */

const C = { bg: "#171725", surface: "#282839", hover: "#33334a", text: "#ffffff", muted: "#c4c4ca" };
const SCALE = 2;

function useStore<T extends string | boolean>(key: string, initial: T): [T, (v: T) => void] {
  const [v, set] = useState<T>(() => {
    try {
      const s = localStorage.getItem(key);
      if (s == null) return initial;
      return (typeof initial === "boolean" ? s === "true" : s) as T;
    } catch {
      return initial;
    }
  });
  return [v, (next: T) => { set(next); try { localStorage.setItem(key, String(next)); } catch { /* private mode */ } }];
}

async function myName(): Promise<string | null> {
  const { data: u } = await supabase.auth.getUser();
  if (!u.user) return null;
  const { data } = await supabase.from("profiles").select("display_name, handle").eq("id", u.user.id).maybeSingle();
  return [data?.display_name, data?.handle].map((s) => (s ?? "").trim()).find(Boolean) ?? null;
}

function loadImage(url: string): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = () => resolve(null);
    img.src = url;
  });
}

export function DeckImageScreen({ name, format, entries, catalog, owner, from, onClose }: {
  name: string; format: string; entries: Entry[]; catalog: Catalog;
  /** The deck's player on a shared deck; null on your own (your name, switchable). */
  owner: string | null;
  from: "own" | "profile"; onClose: () => void;
}) {
  const [layout, setLayout] = useStore<DeckImageLayout>("table1.deckImage.layout", "grid");
  const [groupingRaw, setGrouping] = useStore<string>("table1.deckImage.grouping", "type");
  const [showSide, setShowSide] = useStore<boolean>("table1.deckImage.sideboard", true);
  const [showName, setShowName] = useStore<boolean>("table1.deckImage.name", true);
  const grouping: Grouping = (["type", "color", "identity", "manaValue"] as const).find((g) => g === groupingRaw) ?? "type";
  const [me, setMe] = useState<string | null>(null);
  const [art, setArt] = useState<Map<number, HTMLImageElement> | null>(null);
  const [progress, setProgress] = useState<[number, number]>([0, 0]);
  const [url, setUrl] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  const blob = useRef<Blob | null>(null);

  const lines: PlanLine[] = useMemo(() => resolveLines(entries.filter((e) => e.board !== "maybe"), "deck", catalog).map((l) => ({
    cardId: l.cardId, oracleId: l.oracleId, name: l.name, board: l.board, qty: l.qty, p: l.p,
    set: l.p == null ? "" : catalog.pSet[l.p], finish: l.finish, keys: l.keys,
  })), [entries, catalog]);
  const hasSide = lines.some((l) => l.board === "side");
  const player = owner ?? (showName ? me : null);

  useEffect(() => { if (!owner) void myName().then(setMe).catch(() => setMe(null)); }, [owner]);
  // Every printing's image once; options only redraw.
  useEffect(() => {
    let live = true;
    const ps = [...new Set(lines.map((l) => l.p).filter((p): p is number => p != null))];
    setProgress([0, ps.length]);
    let done = 0;
    void Promise.all(ps.map(async (p) => {
      const img = await loadImage(cardImageUrl(catalog, p, "normal"));
      if (live) setProgress([++done, ps.length]);
      return [p, img] as const;
    })).then((all) => {
      if (!live) return;
      const m = new Map<number, HTMLImageElement>();
      for (const [p, img] of all) if (img) m.set(p, img);
      if (m.size < ps.length) setNote(`${ps.length - m.size} card images couldn't be loaded; their names show instead.`);
      setArt(m);
    });
    return () => { live = false; };
  }, [lines, catalog]);
  // Draw.
  useEffect(() => {
    if (!art) return;
    const p = plan(lines, grouping);
    const font = getComputedStyle(document.body).fontFamily || "ui-monospace, monospace";
    const canvas = draw({ name, format: formatName(format), player, plan: p, layout, showSide, art, font });
    let alive = true;
    canvas.toBlob((b) => {
      if (!alive || !b) return;
      blob.current = b;
      setUrl((old) => { if (old) URL.revokeObjectURL(old); return URL.createObjectURL(b); });
    }, "image/jpeg", 0.9);
    return () => { alive = false; };
  }, [art, lines, grouping, layout, showSide, player, name, format]);
  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [onClose]);

  const sent = (how: "download" | "share" | "copy") =>
    capture("deck_image_shared", { layout, grouping, sideboard: showSide, cards: lines.reduce((n, l) => n + l.qty, 0), from, how });
  const download = () => {
    if (!url) return;
    const a = document.createElement("a");
    a.href = url;
    a.download = fileName(name);
    a.click();
    setNote(`Downloaded ${fileName(name)}.`);
    setFail(null);
    sent("download");
  };
  const file = () => (blob.current ? new File([blob.current], fileName(name), { type: "image/jpeg" }) : null);
  const canShare = typeof navigator !== "undefined" && !!navigator.canShare && !!blob.current && navigator.canShare({ files: [file()!] });
  const share = async () => {
    const f = file();
    if (!f) return;
    try {
      if (navigator.canShare?.({ files: [f] })) {
        await navigator.share({ files: [f], title: name });
        sent("share");
        return;
      }
      // No file sharing here: copy the picture (as PNG, the one image type clipboards take everywhere).
      const png = await new Promise<Blob | null>((res) => {
        const img = new Image();
        img.onload = () => { const c = document.createElement("canvas"); c.width = img.width; c.height = img.height; c.getContext("2d")!.drawImage(img, 0, 0); c.toBlob(res, "image/png"); };
        img.onerror = () => res(null);
        img.src = url!;
      });
      if (!png) throw new Error("no image");
      await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
      setNote("Copied the image. Paste it into a message or post.");
      setFail(null);
      sent("copy");
    } catch (e) {
      if ((e as Error)?.name === "AbortError") return;
      setFail("Couldn't share or copy here. Download it instead.");
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={`Deck image of ${name}`}>
      <Bar title="Deck image" subtitle={name} onBack={onClose} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Segmented options={[{ value: "grid", label: "Cards" }, { value: "stacks", label: "Stacks" }]} value={layout}
                   onChange={(v) => setLayout(v as DeckImageLayout)} />
        <Segmented options={[{ value: "type", label: "Type" }, { value: "manaValue", label: "Mana value" }, { value: "color", label: "Color" },
                                { value: "identity", label: "Identity" }]}
                   value={grouping} onChange={(v) => setGrouping(v)} />
        {hasSide && <SwitchRow label="Sideboard" on={showSide} onChange={setShowSide} />}
        {!owner && <SwitchRow label="Your name" detail={me ?? "Not set"} on={showName} onChange={setShowName} />}
        {fail && <Notice tone="error">{fail}</Notice>}
        {note && <Notice tone="info">{note}</Notice>}
        {url ? <ZoomablePreview src={url} alt={`Deck image of ${name}`} title="Deck image" subtitle={name} screen="deck_image" />
          : <Notice tone="info">{art ? "Laying out the cards…" : `Getting card images… ${progress[0]} of ${progress[1]}`}</Notice>}
      </div>
      <div className="shrink-0 flex gap-px pb-px">
        <button type="button" disabled={!url} onClick={download}
                className="flex-1 bg-t1-accent text-t1-ink disabled:bg-t1-disabled px-4 py-3 text-[11px] uppercase tracking-[1px]">Download</button>
        <GhostAction label={canShare ? "Share" : "Copy image"} onClick={() => void share()} disabled={!url} />
      </div>
    </div>
  );
}

/* ── drawing (the iOS DeckImageCanvas, on a 2D canvas) ─────────────────── */

interface DrawInput {
  name: string; format: string; player: string | null; plan: Plan; layout: DeckImageLayout; showSide: boolean;
  art: Map<number, HTMLImageElement>; font: string;
}

export function draw(d: DrawInput): HTMLCanvasElement {
  const side = d.showSide ? d.plan.side : [];
  const f = fit(ordered(d.plan).length, side.length);
  const stacksH = d.layout === "stacks" ? stacksHeight(d.plan, side) : 0;
  const height = d.layout === "grid" ? f.height : stacksH;
  const canvas = document.createElement("canvas");
  canvas.width = WIDTH * SCALE;
  canvas.height = height * SCALE;
  const ctx = canvas.getContext("2d")!;
  ctx.scale(SCALE, SCALE);
  ctx.fillStyle = C.bg;
  ctx.fillRect(0, 0, WIDTH, height);
  const text = (s: string, x: number, y: number, size: number, color: string, o: { weight?: number; tracking?: number; align?: CanvasTextAlign; max?: number } = {}) => {
    ctx.font = `${o.weight ?? 400} ${size}px ${d.font}`;
    if ("letterSpacing" in ctx) (ctx as CanvasRenderingContext2D & { letterSpacing: string }).letterSpacing = `${o.tracking ?? 0}px`;
    ctx.fillStyle = color;
    ctx.textAlign = o.align ?? "left";
    ctx.textBaseline = "top";
    ctx.fillText(s, x, y, o.max);
  };
  // Header: name, "By", the line of facts; the Table 1 mark top right.
  text(d.name, PAD, 36, 30, C.text, { weight: 700, max: WIDTH - 2 * PAD - 160 });
  let y = 36 + 36 + 8;
  if (d.player) { text(`By ${d.player}`, PAD, y, 17, C.text, { weight: 500, max: WIDTH - 2 * PAD - 160 }); y += 21 + 8; }
  const date = new Date().toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  text([date, `Format: ${d.format}`, `Deck: ${mainCount(d.plan)} cards`, side.length ? `Sideboard: ${count(d.plan.side)} cards` : null].filter(Boolean).join(" · "),
       PAD, y, 14, C.muted, { max: WIDTH - 2 * PAD - 160 });
  logo(ctx, WIDTH - PAD, 36, 30);
  text("TABLE-1.SITE", WIDTH - PAD, 74, 11, C.muted, { tracking: 2.5, align: "right" });

  if (d.layout === "grid") {
    const ch = f.cw * ASPECT;
    ordered(d.plan).forEach((c, i) => tile(ctx, d, c, PAD + (i % f.cols) * (f.cw + GAP), HEADER + Math.floor(i / f.cols) * (ch + ROW_GAP), f.cw));
    if (side.length) {
      const sideX = WIDTH - PAD - f.cw;
      const mainRows = Math.ceil(ordered(d.plan).length / f.cols);
      const h = Math.max(mainRows * ch + (mainRows - 1) * ROW_GAP, ch + (side.length - 1) * f.step);
      divider(ctx, d, sideX - SIDE_GUTTER / 2, HEADER, h);
      side.forEach((c, i) => tile(ctx, d, c, sideX, HEADER + i * f.step, f.cw));
    }
  } else {
    drawStacks(ctx, d, side, text);
  }
  return canvas;
}

const SW = 140, SH = SW * ASPECT, SSTEP = SH * 0.118;
const sideCols = (side: DeckImageCard[]) => (side.length === 0 ? 0 : side.length > 10 ? 2 : 1);
const mainPerRow = (side: DeckImageCard[]) =>
  Math.max(1, Math.floor((WIDTH - 2 * PAD - (sideCols(side) > 0 ? sideCols(side) * (SW + GAP) + SIDE_GUTTER : 0) + GAP) / (SW + GAP)));
const columnH = (n: number) => 15 + 12 + SH + Math.max(0, n - 1) * SSTEP;

function stacksHeight(plan: Plan, side: DeckImageCard[]): number {
  const rs = rows(columns(plan.main, 9), mainPerRow(side));
  const mainH = rs.reduce((h, r) => h + Math.max(...r.map((c) => columnH(c.cards.length))), 0) + 28 * Math.max(0, rs.length - 1);
  const per = Math.ceil(side.length / Math.max(1, sideCols(side)));
  const sideH = side.length ? columnH(per) : 0;
  return Math.ceil(HEADER + Math.max(mainH, sideH) + PAD);
}

function drawStacks(ctx: CanvasRenderingContext2D, d: DrawInput, side: DeckImageCard[], text: (s: string, x: number, y: number, size: number, color: string, o?: { tracking?: number; max?: number }) => void) {
  const column = (title: string | null, cards: DeckImageCard[], x: number, y: number) => {
    // Kept to the column's width, like the iOS title's single line.
    if (title) text(title.toUpperCase(), x, y, 12, C.muted, { tracking: 2, max: SW });
    cards.forEach((c, i) => tile(ctx, d, c, x, y + 27 + i * SSTEP, SW, true));
  };
  let y = HEADER;
  for (const r of rows(columns(d.plan.main, 9), mainPerRow(side))) {
    r.forEach((c, i) => column(c.title, c.cards, PAD + i * (SW + GAP), y));
    y += Math.max(...r.map((c) => columnH(c.cards.length))) + 28;
  }
  if (side.length) {
    const n = sideCols(side), per = Math.ceil(side.length / n);
    const x0 = WIDTH - PAD - n * SW - (n - 1) * GAP;
    const mainBottom = y - 28;
    ctx.fillStyle = "rgba(196,196,202,0.5)";
    ctx.fillRect(x0 - SIDE_GUTTER / 2, HEADER, 1, Math.max(mainBottom - HEADER, columnH(per)));
    rows(side, per).forEach((cards, i) => column(i === 0 ? `Sideboard · ${count(d.plan.side)}` : null, cards, x0 + i * (SW + GAP), HEADER));
  }
}

function divider(ctx: CanvasRenderingContext2D, d: DrawInput, x: number, top: number, h: number) {
  ctx.fillStyle = "rgba(196,196,202,0.5)";
  ctx.fillRect(x, top, 1, h);
  ctx.save();
  ctx.translate(x + 0.5, top + h / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.font = `400 11px ${d.font}`;
  if ("letterSpacing" in ctx) (ctx as CanvasRenderingContext2D & { letterSpacing: string }).letterSpacing = "2.5px";
  const w = ctx.measureText("SIDEBOARD").width;
  ctx.fillStyle = C.bg;
  ctx.fillRect(-w / 2 - 8, -8, w + 16, 16);
  ctx.fillStyle = C.muted;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText("SIDEBOARD", 0, 0);
  ctx.restore();
}

/** A card with its count on a square badge over the top-right corner. */
function tile(ctx: CanvasRenderingContext2D, d: DrawInput, c: DeckImageCard, x: number, y: number, w: number, _stack = false) {
  const h = w * ASPECT;
  const r = w * cornerRatio(c.set);
  ctx.save();
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
  ctx.clip();
  const img = c.p == null ? undefined : d.art.get(c.p);
  if (img) {
    ctx.drawImage(img, x, y, w, h);
  } else {
    ctx.fillStyle = C.hover;
    ctx.fillRect(x, y, w, h);
    ctx.font = `400 11px ${d.font}`;
    ctx.fillStyle = C.text;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText(c.name, x + 8, y + 8, w - 16);
  }
  if (c.finish !== "nonfoil") {
    const g = ctx.createLinearGradient(x, y, x + w, y + h);
    ["#ff73bf", "#ffd966", "#73ffb3", "#59bfff", "#bf80ff", "#ff73bf"].forEach((col, i) => g.addColorStop(i / 5, col));
    ctx.globalCompositeOperation = "overlay";
    ctx.globalAlpha = c.finish === "etched" ? 0.3 : 0.55;
    ctx.fillStyle = g;
    ctx.fillRect(x, y, w, h);
  }
  ctx.restore();
  const b = Math.max(18, w * 0.16);
  ctx.font = `600 ${b * 0.55}px ${d.font}`;
  if ("letterSpacing" in ctx) (ctx as CanvasRenderingContext2D & { letterSpacing: string }).letterSpacing = "0px";
  const label = String(c.qty);
  const bw = Math.max(b, ctx.measureText(label).width + (c.qty > 9 ? 6 : 0));
  const bx = x + w + b * 0.35 - bw, by = y - b * 0.35;
  ctx.fillStyle = C.surface;
  ctx.fillRect(bx, by, bw, b);
  ctx.strokeStyle = "rgba(196,196,202,0.6)";
  ctx.lineWidth = 1;
  ctx.strokeRect(bx + 0.5, by + 0.5, bw - 1, b - 1);
  ctx.fillStyle = C.text;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(label, bx + bw / 2, by + b / 2 + 0.5);
}

/** The Table 1 mark: eleven tiles on a 6 × 3 grid (the iOS T1Logo), right-aligned at x, `h` tall. */
function logo(ctx: CanvasRenderingContext2D, right: number, top: number, h: number) {
  const w = (h * 393) / 192.69, sx = w / 393, sy = h / 192.69, x0 = right - w;
  ctx.fillStyle = C.text;
  for (const [cx, cy] of [[0, 0], [1, 0], [2, 0], [3, 0], [4, 0], [1, 1], [4, 1], [1, 2], [3, 2], [4, 2], [5, 2]]) {
    ctx.fillRect(x0 + cx * 65.8036 * sx, top + cy * 64.8302 * sy, 63.982 * sx, 63.0294 * sy);
  }
}
