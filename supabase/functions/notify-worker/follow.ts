// Alert text for `follow.updated` and `trade.wants` (contract/follows-2026-10-25.md): one push per round of changes to a binder, deck
// or cube someone follows. `data` comes from t1_private.follow_digest.

const cards = (n: number) => `${n} card${n === 1 ? "" : "s"}`;

/** "A", "A and B", "A, B and C", or "A, B, C and 4 more" when there are more than the names given. */
export function nameList(names: string[], total: number): string {
  const more = Math.max(0, total - names.length);
  if (!names.length) return more ? `${more} more` : "";
  if (more) return `${names.join(", ")} and ${more} more`;
  if (names.length === 1) return names[0];
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

/** `trade.wants` (contract § Trade wants): a friend put cards you want up for trade. Never says "their" or "her". */
export function tradeWantsCopy(d: Record<string, unknown>): { title: string; body: string } {
  const owner = String(d.owner_name ?? "") || "A friend";
  const names = Array.isArray(d.names) ? d.names.map(String) : [];
  const n = Number(d.n ?? names.length);
  const list = nameList(names, n);
  return { title: "Trade match", body: `${owner} put ${n === 1 ? "a card" : `${n} cards`} you want up for trade${list ? `: ${list}` : ""}.` };
}

export function followCopy(d: Record<string, unknown>): { title: string; body: string } {
  const owner = String(d.owner_name ?? "") || "Someone";
  const added = Number(d.added ?? 0), removed = Number(d.removed ?? 0);
  const ins = Array.isArray(d.in) ? d.in.map(String) : [], outs = Array.isArray(d.out) ? d.out.map(String) : [];
  const inList = nameList(ins, Number(d.in_n ?? ins.length)), outList = nameList(outs, Number(d.out_n ?? outs.length));
  const title = String(d.name ?? "") || "Something you follow";
  let body: string;
  if (added && removed) body = `${owner} added ${cards(added)} and took out ${removed}.${inList ? ` In: ${inList}.` : ""}`;
  else if (added) body = `${owner} added ${cards(added)}${inList ? `: ${inList}` : ""}.`;
  else body = `${owner} took out ${cards(removed)}${outList ? `: ${outList}` : ""}.`;
  return { title, body };
}
