// Deck finder (contract/deck-finder-2026-10-15.md): describe a deck in plain words; an agent finds a recent
// tournament list, asks when the request is ambiguous, and the list is created with each card's original
// paper printing. Same flow as iOS and Android.
import { useMemo, useState } from "react";
import { Bar, BigAction, Field, Notice, Row, Section, Segmented } from "../components/kit";
import { printingsByName } from "../lib/catalog";
import { createList, type Entry } from "../lib/lists";
import { supabase } from "../lib/supabaseClient";
import { capture } from "../lib/telemetry";
import { CardRow, LibScreen, useCatalog } from "./Library";
import { useListsData } from "./Lists";

interface Line { qty: number; name: string }
interface FoundDeck {
  name: string; archetype: string; format: string; event: string; date: string; placement: string; player: string;
  source_url: string; notes: string; main: Line[]; side: Line[];
}
interface Result { status: "deck" | "question" | "not_found" | "error"; question?: string; options?: string[]; message?: string; deck?: FoundDeck }
interface Answer { question: string; answer: string }

const FORMATS = ["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "premodern"];

async function findDeck(query: string, format: string, answers: Answer[]): Promise<Result> {
  const { data, error } = await supabase.functions.invoke("deck-finder", { body: { query, format, answers } });
  if (error) {
    // A refusal (sign in, daily allowance) carries the server's own message.
    const body = await (error as { context?: Response }).context?.json?.().catch(() => null);
    return { status: "error", message: body?.error ?? "The deck finder couldn't search just now. Try again." };
  }
  const r = (typeof data === "string" ? JSON.parse(data) : data) as Result & { error?: string };
  return r.error ? { status: "error", message: r.error } : r;
}

export function DeckFinderScreen({ onBack, onCreated }: { onBack: () => void; onCreated: (listId: string) => void }) {
  const { session, ready } = useListsData();
  const { catalog } = useCatalog();
  const [query, setQuery] = useState("");
  const [format, setFormat] = useState("modern");
  const [answers, setAnswers] = useState<Answer[]>([]);
  const [searching, setSearching] = useState(false);
  const [result, setResult] = useState<Result | null>(null);
  const [reply, setReply] = useState("");
  const [creating, setCreating] = useState(false);
  const deck = result?.status === "deck" ? result.deck : undefined;
  const resolved = useMemo(
    () => (deck && catalog ? printingsByName(catalog, [...deck.main, ...deck.side].map((l) => l.name)) : new Map<string, number>()),
    [deck, catalog],
  );

  const search = async (with_: Answer[]) => {
    setSearching(true);
    try {
      const r = await findDeck(query.trim(), format, with_);
      if (r.status === "deck" || r.status === "not_found") capture("deck_finder_used", { found: !!r.deck });
      if (r.deck && FORMATS.includes(r.deck.format)) setFormat(r.deck.format);
      setResult(r);
    } finally {
      setSearching(false);
    }
  };
  const answer = (text: string) => {
    if (!result?.question || !text.trim()) return;
    const next = [...answers, { question: result.question, answer: text.trim() }];
    setAnswers(next);
    setReply("");
    void search(next);
  };
  const create = async (d: FoundDeck) => {
    if (!catalog) return;
    setCreating(true);
    try {
      const byKey = new Map<string, Entry>();
      for (const [board, lines] of [["main", d.main], ["side", d.side]] as const) {
        for (const l of lines) {
          const p = resolved.get(l.name);
          if (p === undefined) continue;
          const cardId = catalog.pId[p];
          const e = byKey.get(`${board}|${cardId}`);
          if (e) e.qty += l.qty;
          else byKey.set(`${board}|${cardId}`, { cardId, board, qty: l.qty });
        }
      }
      const source = [d.placement, d.event, d.date].filter(Boolean).join(", ");
      const id = await createList("deck", d.name.slice(0, 60), format, [...byKey.values()],
                                  source ? `Found: ${source}`.slice(0, 120) : "Found online", "finder");
      onCreated(id);
    } finally {
      setCreating(false);
    }
  };

  if (!ready) return <LibScreen><div className="flex-1" /></LibScreen>;
  if (!session) return <LibScreen><Bar title="Find a deck" onBack={onBack} /><Notice tone="info">Sign in to find decks.</Notice></LibScreen>;
  const lineRow = (l: Line, i: number) => (
    <div key={i} className="h-[60px]">
      <CardRow c={catalog!} p={resolved.get(l.name) ?? null} title={l.name} value={l.qty} detail={resolved.has(l.name) ? undefined : "Not found"} />
    </div>
  );
  const count = (ls: Line[]) => ls.reduce((n, l) => n + l.qty, 0);
  const missing = deck ? [...new Set([...deck.main, ...deck.side].map((l) => l.name).filter((n) => !resolved.has(n)))].sort() : [];

  return (
    <LibScreen>
      <Bar title="Find a deck" subtitle="Recent tournament lists" onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Field label="Describe the deck" value={query} onChange={setQuery} autoFocus />
        <Segmented options={FORMATS.map((f) => ({ value: f, label: f }))} value={format} onChange={setFormat} columns={4} />
        {!deck && (
          <BigAction label={searching ? "Searching…" : "Find deck"} busy={searching} disabled={searching || query.trim().length < 3}
                     onClick={() => { setAnswers([]); void search([]); }} />
        )}
        {searching && (
          <Notice tone="info">Searching mtgdecks, melee.gg, MTGGoldfish and MTGO results for the newest strong finishes. This can take a minute or two.</Notice>
        )}
        {!searching && result?.status === "question" && (
          <>
            <Section title={result.question ?? "Which deck?"} />
            {(result.options ?? []).map((o) => <Row key={o} title={o} onClick={() => answer(o)} />)}
            <Field label="Or type an answer" value={reply} onChange={setReply} />
            <BigAction label="Answer" onClick={() => answer(reply)} disabled={!reply.trim()} />
          </>
        )}
        {!searching && (result?.status === "not_found" || result?.status === "error") && (
          <Notice tone="error">{result.message ?? "Nothing turned up. Try naming the archetype."}</Notice>
        )}
        {!searching && deck && catalog && (
          <>
            <Row title={deck.name} detail={[deck.placement, deck.event, deck.date].filter(Boolean).join(" · ")} />
            {(deck.player || deck.notes) && (
              <Notice tone="info">{[deck.player ? `Played by ${deck.player}.` : "", deck.notes].filter(Boolean).join(" ")}</Notice>
            )}
            {deck.source_url && <Row title="Source" detail={new URL(deck.source_url).host} onClick={() => window.open(deck.source_url, "_blank", "noopener")} />}
            {missing.length > 0 && <Notice tone="error">Not in the card data, left out: {missing.join(", ")}</Notice>}
            <BigAction label={`Create deck · ${count(deck.main)} + ${count(deck.side)}`} onClick={() => void create(deck)}
                       busy={creating} disabled={creating || resolved.size === 0} />
            <Row title="Search again" onClick={() => setResult(null)} />
            <Section title="Main deck" count={count(deck.main)} />
            {deck.main.map(lineRow)}
            {deck.side.length > 0 && <Section title="Sideboard" count={count(deck.side)} />}
            {deck.side.map(lineRow)}
          </>
        )}
      </div>
    </LibScreen>
  );
}
