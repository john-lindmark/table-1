// Draft seating drawing (client only; not an engine rule, so not in lib/seating.ts, which the parity check compares).
/**
 * Where each seat goes around one long table drawn upright (contract/event-night-2026-10-16.md § 3): `right` seats
 * down the right side, then `left` seats up the left side, with an end seat before each side when the ends are seated
 * (4+ players; an odd side count puts the extra player on the right). Pixel values. Same as iOS / Android TableLayout.
 */
export class TableLayout {
  static readonly CHIP_H = 46;
  static readonly GAP = 10;
  readonly ends: boolean;
  readonly right: number;
  readonly left: number;
  constructor(readonly count: number, ends: boolean) {
    this.ends = ends && count >= 4;
    const sides = count - (this.ends ? 2 : 0);
    this.right = Math.ceil(sides / 2);
    this.left = sides - this.right;
  }
  get rows() { return Math.max(this.right, this.left, 1); }
  private get step() { return TableLayout.CHIP_H + TableLayout.GAP; }
  /** Height of the drawing: the side rows, plus a row above and below for the ends. */
  get height() { return (this.rows + (this.ends ? 2 : 0)) * this.step - TableLayout.GAP + 8; }
  private get firstRowY() { return 4 + TableLayout.CHIP_H / 2 + (this.ends ? this.step : 0); }
  /** The table between the two columns, reaching up to the end seats. */
  tableRect(width: number, chipW: number): { x: number; y: number; w: number; h: number } {
    const x0 = chipW + 12, x1 = width - chipW - 12;
    const y0 = this.firstRowY - TableLayout.CHIP_H / 2 - (this.ends ? TableLayout.GAP / 2 : 0);
    const y1 = this.firstRowY + (this.rows - 1) * this.step + TableLayout.CHIP_H / 2 + (this.ends ? TableLayout.GAP / 2 : 0);
    return { x: x0, y: y0, w: Math.max(x1 - x0, 40), h: y1 - y0 };
  }
  /** Seat centres in seat order (clockwise from the top end, or from the right side's first seat). */
  positions(width: number, chipW: number): { x: number; y: number }[] {
    if (this.count === 0) return [];
    const mid = width / 2, rightX = width - chipW / 2 - 4, leftX = chipW / 2 + 4;
    const rowY = (r: number) => this.firstRowY + r * this.step;
    const out: { x: number; y: number }[] = [];
    if (this.ends) out.push({ x: mid, y: 4 + TableLayout.CHIP_H / 2 });
    for (let r = 0; r < this.right; r++) out.push({ x: rightX, y: rowY(r) });
    if (this.ends) out.push({ x: mid, y: rowY(this.rows - 1) + this.step });
    for (let r = this.left - 1; r >= 0; r--) out.push({ x: leftX, y: rowY(r + this.rows - this.left) });
    return out;
  }
}
