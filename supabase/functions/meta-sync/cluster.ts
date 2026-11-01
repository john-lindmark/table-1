// Finds groups among the decks no archetype rule names ("Other"), so new archetypes can be proposed for review
// (contract/insights-2026-10-24.md § Archetypes). Leader clustering on nonland main-deck cards (Jaccard), refined
// twice around each group's common cards. Pure.

export interface ClusterDeck { id: number; colors: string; cards: string[] }
export interface Cluster { size: number; share: number; colors: string; signature: string[]; rule: string[] }

const jaccard = (a: Set<string>, b: Set<string>) => {
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / Math.max(1, a.size + b.size - inter);
};

/** Groups of at least minSize decks; signature = cards in ≥70% of the group, most distinctive first; rule = the
 *  2–3 signature cards rarest outside the group (what a rule would require). */
export function clusters(decks: ClusterDeck[], total: number, opts = { join: 0.4, keep: 0.35, minSize: 8 }): Cluster[] {
  const sets = decks.map((d) => new Set(d.cards));
  let centres: Set<string>[] = [];
  for (let pass = 0; pass < 3; pass++) {
    const groups: number[][] = centres.map(() => []);
    const cs = [...centres];
    sets.forEach((s, i) => {
      let best = 0, bi = -1;
      cs.forEach((c, j) => { const v = jaccard(s, c); if (v > best) { best = v; bi = j; } });
      if (best >= opts.join) groups[bi].push(i);
      else { cs.push(s); groups.push([i]); }
    });
    centres = groups.filter((g) => g.length >= 3).map((g) => {
      const n = new Map<string, number>();
      for (const i of g) for (const c of sets[i]) n.set(c, (n.get(c) ?? 0) + 1);
      return new Set([...n].filter(([, k]) => k / g.length >= 0.5).map(([c]) => c));
    });
  }
  const members: number[][] = centres.map(() => []);
  sets.forEach((s, i) => {
    let best = 0, bi = -1;
    centres.forEach((c, j) => { const v = jaccard(s, c); if (v > best) { best = v; bi = j; } });
    if (best >= opts.keep) members[bi].push(i);
  });
  const everywhere = new Map<string, number>();
  for (const s of sets) for (const c of s) everywhere.set(c, (everywhere.get(c) ?? 0) + 1);
  const out: Cluster[] = [];
  for (const g of members) {
    if (g.length < opts.minSize) continue;
    const n = new Map<string, number>();
    const colors = new Map<string, number>();
    for (const i of g) {
      for (const c of sets[i]) n.set(c, (n.get(c) ?? 0) + 1);
      for (const col of decks[i].colors) colors.set(col, (colors.get(col) ?? 0) + 1);
    }
    const sig = [...n].filter(([, k]) => k / g.length >= 0.7)
      .map(([c, k]) => ({ c, fin: k / g.length, fout: ((everywhere.get(c) ?? 0) - k) / Math.max(1, sets.length - g.length) }))
      .sort((a, b) => (b.fin - b.fout) - (a.fin - a.fout) || a.c.localeCompare(b.c));
    if (!sig.length) continue;
    out.push({
      size: g.length, share: g.length / Math.max(1, total),
      colors: [...colors].filter(([, k]) => k / g.length >= 0.5).map(([c]) => c).sort((a, b) => "WUBRG".indexOf(a) - "WUBRG".indexOf(b)).join(""),
      signature: sig.slice(0, 12).map((x) => x.c),
      rule: sig.filter((x) => x.fin >= 0.9).slice(0, 3).map((x) => x.c),
    });
  }
  return out.sort((a, b) => b.size - a.size);
}

/** True when a cluster is already known (approved, proposed or rejected): half or more of its signature shared. */
export function known(c: Cluster, signatures: string[][]): boolean {
  const mine = new Set(c.signature);
  return signatures.some((s) => s.length && s.filter((x) => mine.has(x)).length / Math.min(s.length, mine.size) >= 0.5);
}

export const NAME_SYSTEM = `You name Magic: The Gathering constructed archetypes for a metagame dashboard. You get a group of tournament decks from one format: their colors and the nonland cards almost all of them play, most distinctive first.

Answer with the name players use for this deck in that format (e.g. "Boros Energy", "Amulet Titan", "Izzet Prowess", "Mono-Blue Belcher"), at most 30 characters; a guild or shard name plus the deck's key card or plan when there's no common name. Pick its family: aggro, midrange, control, combo or ramp. Pick 1 to 3 rule cards from the given cards that every deck of this archetype plays and other decks rarely do.`;

export const NAME_SCHEMA = {
  type: "object", additionalProperties: false, required: ["name", "family", "rule_cards"],
  properties: {
    name: { type: "string" },
    family: { type: "string", enum: ["aggro", "midrange", "control", "combo", "ramp"] },
    rule_cards: { type: "array", items: { type: "string" } },
  },
} as const;

export const namePrompt = (format: string, c: Cluster) =>
  `Format: ${format}\nDecks in the group: ${c.size} (${(c.share * 100).toFixed(1)}% of recent decks)\nColors: ${c.colors || "colorless"}\nCards (most distinctive first): ${c.signature.join("; ")}`;

/** The proposal to store, or null when the answer doesn't fit (rule cards must come from the signature). */
export function proposal(c: Cluster, raw: unknown): { name: string; family: string; rule: { main: string[] } } | null {
  const r = raw as { name?: unknown; family?: unknown; rule_cards?: unknown };
  const name = typeof r?.name === "string" ? r.name.trim().slice(0, 30) : "";
  const family = typeof r?.family === "string" ? r.family : "";
  const cards = Array.isArray(r?.rule_cards) ? (r.rule_cards as unknown[]).filter((x): x is string => typeof x === "string") : [];
  const sig = new Set(c.signature);
  const rule = cards.filter((x) => sig.has(x)).slice(0, 3);
  if (!name || !["aggro", "midrange", "control", "combo", "ramp"].includes(family)) return null;
  return { name, family, rule: { main: rule.length ? rule : c.rule } };
}
