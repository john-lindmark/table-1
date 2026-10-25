// Wire shapes between the meta-sync worker and the database (meta_ingest) and the published pack.

export interface DeckIn {
  player: string;                 // source's own id for the player; hashed by the server, never stored
  rank: number | null;
  wins: number | null;
  losses: number | null;
  draws: number | null;
  top8: boolean;
  main: [string, number][];       // [card name, copies]
  side: [string, number][];
}

export interface MatchIn {
  round: string;
  a: string;
  b: string;
  a_wins: number | null;
  b_wins: number | null;
  result: "a" | "b" | "draw";
}

export interface EventIn {
  source: "mtgo" | "topdeck";
  source_id: string;
  format: string;
  name: string;
  kind: "challenge" | "league" | "showcase" | "qualifier" | "championship" | "paper" | "other";
  on: string;                     // yyyy-mm-dd
  players: number | null;
  url: string | null;
  complete: boolean;              // every deck of the field is in decks
  decks: DeckIn[];
  matches: MatchIn[];
}

export type Tier = "big" | "all";
export const WINDOWS = [7, 14, 30, 90] as const;

export interface ShareRow { a: number; share: number; prev: number | null; decks: number; top8: number; conv: number | null }
export interface CardRow { c: string; n: string; rate: number; prev: number | null; copies: number }
export interface Window {
  decks: number; weighted: number; events: number; thin: boolean; brief: string | null;
  share: ShareRow[];
  cards: { main: { up: CardRow[]; down: CardRow[] }; side: { up: CardRow[]; down: CardRow[] } };
}
export interface Series { from: string; days: number; lines: { a: number; v: (number | null)[] }[]; other: (number | null)[] }
export interface NewSet {
  set_code: string; name: string; released: string;
  cards: { c: string; n: string; rate: number; copies: number; in: number[] | null }[];
}
export interface View { windows: Record<string, Window>; series: Series; new_set: NewSet | null }
export interface Archetype { id: number; name: string; family: string; colors: string }
export interface Change { id: number; on: string; kind: string; cards: string[]; set_code: string | null; note: string | null; url: string | null }
export interface BanStudy {
  change: number; on: string;
  before: { a: number; share: number }[];
  after: Record<string, { a: number; share: number }[]>;
  after_days?: number;
  losers: { a: number; before: number; after: number }[];
  gainers: { a: number; before: number; after: number }[];
  replacements: { c: string; n: string; before: number; after: number; in: number }[];
  settled_days: number | null;
  brief: string | null;
  daily?: { from: string; lines: { a: number; v: (number | null)[] }[] };
}
export interface Matchups { archetypes: number[]; cells: [number, number, number, number, number][] }
export interface EventRow { name: string; on: string; players: number | null; tier: string; source: string; url: string | null; top8: number[] | null; winner: number | null }
export interface Base {
  format: string; name: string; through: string; sources: string[]; default_tier: Tier;
  archetypes: Archetype[]; changes: Change[]; events: EventRow[];
}
export interface ConstructedPack extends Base {
  v: 1; kind: "constructed"; built_at: string;
  tiers: Record<Tier, View>;
  bans: BanStudy[];
  matchups: Matchups;
}
