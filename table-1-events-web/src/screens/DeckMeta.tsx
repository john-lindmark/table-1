import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Row } from "../components/kit";
import { deckInsight, loadDeckInsight, type DeckInsightAnswer } from "../lib/insights";
import { capture } from "../lib/telemetry";

/* A deck's archetype on the deck's own screen (contract/insights-2026-10-24.md § A deck's archetype): its name, how
   similar the deck is to the archetype's nearest list, 30-day win rate and change on last week (opens the archetype in Insights), then its best and worst matchups. Same as iOS
   DeckMetaRows and Android DeckMetaRows. */
export function DeckMetaRows({ listId, demo }: { listId: string; demo: boolean }) {
  const nav = useNavigate();
  const [answer, setAnswer] = useState<DeckInsightAnswer | null>(null);
  useEffect(() => {
    let live = true;
    setAnswer(null);
    void loadDeckInsight(listId, demo).then((r) => {
      if (!live || !r) return;
      setAnswer(r);
      if (r.a) capture("deck_insight_shown", { format: r.format, archetype: r.a });
    });
    return () => { live = false; };
  }, [listId, demo]);
  if (!answer) return null;
  const d = deckInsight(answer);
  if (!d.title) return d.note ? <Row title="In the meta" detail={d.note} /> : null;
  const open = () => {
    capture("deck_insight_opened", { format: answer.format, archetype: answer.a ?? 0 });
    nav(`/insights/${answer.format}/archetype/${answer.a}${demo ? "?demo" : ""}`);
  };
  return (
    <>
      <Row title={d.title} detail={<Lines lines={[d.similar, [d.win ?? "Too few matches for a win rate", d.change].filter(Boolean).join(" · ")].filter((l): l is string => !!l)} />} value="Insights" onClick={open} />
      {d.good.length > 0 && <Row title="Good against" detail={<Lines lines={d.good} />} onClick={open} />}
      {d.bad.length > 0 && <Row title="Bad against" detail={<Lines lines={d.bad} />} onClick={open} />}
    </>
  );
}

/** One matchup (or fact) a line, so a phone shows them whole. */
const Lines = ({ lines }: { lines: string[] }) => <>{lines.map((l) => <span key={l} className="block truncate">{l}</span>)}</>;
