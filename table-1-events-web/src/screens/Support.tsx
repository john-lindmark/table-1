import { useEffect, useMemo, useRef, useState } from "react";
import { Bar, Notice, Row, Screen, Section } from "../components/kit";
import { capture } from "../lib/telemetry";
import {
  FAQ, GUIDE, faqsOf, hitDetail, hitTitle, sectionGroups, sectionTitle, supportSearch, topicTitle,
  type SupportDoc,
} from "../lib/support";
import { ICON, Icon } from "./Library";

/*
 * Support (contract/support-2026-11-10.md): Account → Support, and table-1.site/support signed in or out. The home
 * is a search box over the FAQ and the guide, then the FAQ topics, the guide's sections and where to ask. A topic
 * lists its questions; a question opens its answer; a guide section reads whole, scrolled to the entry a search hit.
 */

type Go = {
  topic: (key: string) => void;
  guides: () => void;
  faq: (id: string, from: string) => void;
  guide: (section: string, entry: string | null, from: string) => void;
};

export function SupportHome({ onBack, go }: { onBack: () => void; go: Go }) {
  const [q, setQ] = useState(() => sessionStorageGet("t1.support.q"));
  const { hits, partial } = useMemo(() => supportSearch(q), [q]);
  const searching = q.trim().length >= 2;

  useEffect(() => { sessionStorageSet("t1.support.q", q); }, [q]);
  // One event once typing settles: how many words and results, never the words themselves.
  useEffect(() => {
    if (!searching) return;
    const t = setTimeout(() => capture("support_searched", { words: q.trim().split(/\s+/).length, results: hits.length, partial }), 1200);
    return () => clearTimeout(t);
  }, [q, searching, hits.length, partial]);

  const open = (doc: SupportDoc, rank: number) => {
    capture("support_result_opened", { kind: doc.kind, rank });
    if (doc.kind === "faq") go.faq(doc.id, "search");
    else go.guide(doc.entry.s, doc.id, "search");
  };

  return (
    <Screen>
      <Bar title="Support" onBack={onBack} />
      <label className="shrink-0 bg-t1-surface px-4 py-3 flex items-center gap-3">
        <span className="text-t1-muted"><Icon d={ICON.search} /></span>
        <input type="text" enterKeyHint="search" value={q} autoCapitalize="off" autoCorrect="off" spellCheck={false} aria-label="Search support"
               placeholder="Search questions and the guide" onChange={(e) => setQ(e.target.value)}
               className="flex-1 min-w-0 bg-transparent border-0 outline-0 text-[15px] text-t1-text placeholder:text-t1-muted/60" />
        {q && <button type="button" className="t1-label !text-t1-text" onClick={() => setQ("")}>Clear</button>}
      </label>

      {searching ? (
        <>
          {hits.length === 0 && <Notice tone="info">Nothing matches that. Try fewer or other words, or ask below.</Notice>}
          {hits.length > 0 && <Section title={partial ? "Closest matches" : "Results"} count={hits.length} />}
          {hits.map((h, i) => (
            <Row key={`${h.doc.kind}:${h.doc.id}`} title={hitTitle(h.doc)} detail={hitDetail(h.doc)} onClick={() => open(h.doc, i)} />
          ))}
        </>
      ) : (
        <>
          <Section title="Questions" />
          {FAQ.topics.map((t) => (
            <Row key={t.key} title={t.title} value={faqsOf(t.key).length} onClick={() => go.topic(t.key)} />
          ))}
          <Section title="Guide" />
          <Row title="Everything Table 1 does" detail={`${GUIDE.sections.length} sections`} onClick={go.guides} />
        </>
      )}
      <Contact />
    </Screen>
  );
}

function Contact() {
  return (
    <>
      <Section title="Still stuck" />
      <a href={FAQ.contact.discord} target="_blank" rel="noreferrer" onClick={() => capture("support_contact", { how: "discord" })}
         className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3">
        <span className="flex-1 min-w-0 flex flex-col gap-0.5">
          <span className="text-[13px]">Ask in the Table 1 Discord</span>
          <span className="t1-label">discord.gg</span>
        </span>
        <span className="t1-label">Open</span>
      </a>
      <a href={`mailto:${FAQ.contact.email}`} onClick={() => capture("support_contact", { how: "email" })}
         className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3">
        <span className="flex-1 min-w-0 flex flex-col gap-0.5">
          <span className="text-[13px]">Account and privacy</span>
          <span className="t1-label">{FAQ.contact.email}</span>
        </span>
        <span className="t1-label">Email</span>
      </a>
    </>
  );
}

export function SupportGuideIndex({ onBack, go }: { onBack: () => void; go: Go }) {
  return (
    <Screen>
      <Bar title="Guide" onBack={onBack} />
      {GUIDE.sections.map((s) => <Row key={s.id} title={s.title} onClick={() => go.guide(s.id, null, "index")} />)}
    </Screen>
  );
}

export function SupportTopicScreen({ topic, onBack, go }: { topic: string; onBack: () => void; go: Go }) {
  const faqs = faqsOf(topic);
  return (
    <Screen>
      <Bar title={topicTitle(topic)} onBack={onBack} />
      {faqs.length === 0 && <Notice tone="info">This isn't available.</Notice>}
      {faqs.map((f) => <Row key={f.id} title={f.q} onClick={() => go.faq(f.id, "topic")} />)}
    </Screen>
  );
}

export function SupportFaqScreen({ id, from, onBack, go }: { id: string; from: string; onBack: () => void; go: Go }) {
  const faq = FAQ.faqs.find((f) => f.id === id);
  useEffect(() => { if (faq) capture("support_opened", { screen: "faq", id: faq.id, from }); }, [faq, from]);
  if (!faq) {
    return <Screen><Bar title="Support" onBack={onBack} /><Notice tone="info">This isn't available.</Notice></Screen>;
  }
  return (
    <Screen>
      <Bar title={topicTitle(faq.topic)} onBack={onBack} />
      <div className="bg-t1-surface px-4 py-5 flex flex-col gap-4">
        <h1 className="text-[18px] leading-[26px]">{faq.q}</h1>
        {faq.a.split("\n\n").map((p, i) => <p key={i} className="text-[14px] leading-[22px] text-t1-text/90">{p}</p>)}
      </div>
      {faq.guide && (
        <Row title={sectionTitle(faq.guide)} detail="In the guide" onClick={() => go.guide(faq.guide!, null, "faq")} />
      )}
      <Contact />
    </Screen>
  );
}

export function SupportGuideScreen({ section, entry, from, onBack }: { section: string; entry: string | null; from: string; onBack: () => void }) {
  const groups = sectionGroups(section);
  const target = useRef<HTMLDivElement | null>(null);
  useEffect(() => { capture("support_opened", { screen: "guide", id: section, from }); }, [section, from]);
  useEffect(() => { target.current?.scrollIntoView({ block: "center" }); }, [entry]);
  if (!groups.length) {
    return <Screen><Bar title="Support" onBack={onBack} /><Notice tone="info">This isn't available.</Notice></Screen>;
  }
  return (
    <Screen>
      <Bar title={sectionTitle(section)} subtitle="Guide" onBack={onBack} />
      {groups.map((g, gi) => (
        <div key={gi} className="flex flex-col gap-px">
          {g.heading && <Section title={g.heading} />}
          {g.entries.map((e) => (
            <div key={e.id} id={e.id} ref={e.id === entry ? target : undefined}
                 className={`bg-t1-surface px-4 py-3 text-[14px] leading-[22px] ${e.id === entry ? "border-l border-t1-accent" : ""}`}>
              {e.t && <span className="text-t1-text">{e.t}{/[.?!]$/.test(e.t) ? " " : /^[(:]/.test(e.x) ? " " : ": "}</span>}
              <span className="text-t1-text/85">{e.x}</span>
            </div>
          ))}
        </div>
      ))}
    </Screen>
  );
}

function sessionStorageGet(key: string): string {
  try { return sessionStorage.getItem(key) ?? ""; } catch { return ""; }
}
function sessionStorageSet(key: string, value: string) {
  try { if (value) sessionStorage.setItem(key, value); else sessionStorage.removeItem(key); } catch { /* private mode */ }
}
