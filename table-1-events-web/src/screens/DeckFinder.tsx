// Deck finder (contract/deck-finder-2026-10-15.md): describe a deck in plain words; an agent finds a recent
// tournament list, asks when the request is ambiguous, and the list is created with each card's original
// paper printing. Same flow as iOS and Android. The search runs on the server as a job (contract § Jobs): the
// screen polls it, and a search started before the tab was closed is picked up when Find a deck opens again.
import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, BigAction, Field, Notice, Row, Section, Segmented } from "../components/kit";
import { printingsByName } from "../lib/catalog";
import * as finder from "../lib/deckFinder";
import type { Answer, FoundDeck, Line, Result } from "../lib/deckFinder";
import { createList, type Entry } from "../lib/lists";
import { capture } from "../lib/telemetry";
import { CardRow, LibScreen, useCatalog } from "./Library";
import { useListsData } from "./Lists";

const FORMATS = ["modern", "pioneer", "standard", "legacy", "vintage", "pauper", "commander", "premodern"];

export function DeckFinderScreen({ onBack, onCreated }: { onBack: () => void; onCreated: (listId: string) => void }) {
  const { session, ready } = useListsData();
  const { catalog } = useCatalog();
  const [query, setQuery] = useState("");
  const [format, setFormat] = useState("modern");
  const [answers, setAnswers] = useState<Answer[]>([]);
  const [job, setJob] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);
  // The agent's work so far, shown while it runs (contract § Jobs "Show the work").
  const [steps, setSteps] = useState<string[]>([]);
  const [result, setResult] = useState<Result | null>(null);
  const [reply, setReply] = useState("");
  const [creating, setCreating] = useState(false);
  const resumed = useRef<string | null>(null);
  const deck = result?.status === "deck" ? result.deck : undefined;
  const resolved = useMemo(
    () => (deck && catalog ? printingsByName(catalog, [...deck.main, ...deck.side].map((l) => l.name)) : new Map<string, number>()),
    [deck, catalog],
  );

  const show = (r: Result) => {
    if (r.status !== "question") capture("deck_finder_used", { found: !!r.deck, from: r.deck?.from ?? "", resumed: resumed.current ?? "" });
    if (r.deck && FORMATS.includes(r.deck.format)) setFormat(r.deck.format);
    setResult(r);
    setSearching(false);
  };
  // Opening with no job of its own: the account's newest job when it's still running or just finished.
  useEffect(() => {
    if (!session || job) return;
    let gone = false;
    void finder.job(null).then((j) => {
      if (gone || !j || !finder.resumeJob(j)) return;
      resumed.current = "open";
      setQuery(j.query);
      if (j.format && FORMATS.includes(j.format)) setFormat(j.format);
      setAnswers(j.answers);
      setSteps(j.steps ?? []);
      if (finder.finished(j)) show(finder.resultOf(j));
      else { setSearching(true); setJob(j.job_id); }
    }).catch(() => {});
    return () => { gone = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session]);
  // Asks after the job every few seconds until it's finished (errors just wait for the next ask); at once when
  // the tab comes back.
  useEffect(() => {
    if (!job) return;
    let gone = false;
    const ask = async () => {
      const j = await finder.job(job).catch(() => null);
      if (gone || !j) return;
      if (j.steps) setSteps(j.steps);
      if (!finder.finished(j)) return;
      gone = true;
      show(finder.resultOf(j));
    };
    void ask();
    const timer = setInterval(() => void ask(), finder.POLL_MS);
    const visible = () => { if (document.visibilityState === "visible") void ask(); };
    document.addEventListener("visibilitychange", visible);
    return () => { gone = true; clearInterval(timer); document.removeEventListener("visibilitychange", visible); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [job]);

  const search = async (with_: Answer[]) => {
    setSearching(true);
    setResult(null);
    setSteps([]);
    try {
      resumed.current = null;
      setJob(await finder.start(query.trim(), format, with_));
    } catch (e) {
      setSearching(false);
      setResult({ status: "error", message: e instanceof Error ? e.message : "The deck finder couldn't search just now. Try again." });
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
          <>
            <Notice tone="info">Searching Table 1's results, mtgdecks, melee.gg, MTGGoldfish and MTGO for the newest strong finishes. This can take a minute or two: you can leave this page and come back, the search goes on.</Notice>
            {steps.length > 0 && <Section title="Working" />}
            {steps.map((s, i) => <Row key={i} title={s} detail={i === steps.length - 1 ? "…" : undefined} />)}
          </>
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
          <>
            <Notice tone="error">{result.message ?? "Nothing turned up. Try naming the archetype."}</Notice>
            <Row title="Search again" onClick={() => setResult(null)} />
          </>
        )}
        {!searching && deck && catalog && (
          <>
            <Row title={deck.name} detail={finder.headline(deck.placement, deck.event, deck.date)} />
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
