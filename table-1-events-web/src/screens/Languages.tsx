import { useEffect, useRef, useState } from "react";
import { Bar, Menu, Row, Section } from "../components/kit";
import { COMMON_LANGUAGES, LANGUAGES, languageChangeOps, languageName } from "../lib/languages";
import { applyOps, type Item } from "../lib/collection";
import { printingPlaces } from "../lib/changePrinting";
import { capture } from "../lib/telemetry";
import { errorMessage } from "../lib/api";

/* Card language (contract/card-language-2026-10-19.md): one full-screen picker, current language marked, and the row that
   opens it. */

/** Every language, current one marked; picking closes it (picking the current one changes nothing). */
export function LanguagePicker({ current, subtitle, onPick, onClose }: {
  current: string; subtitle?: string; onPick: (code: string) => void; onClose: () => void;
}) {
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") closeRef.current(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg text-t1-text flex flex-col gap-px" role="dialog" aria-modal="true" aria-label="Language">
      <Bar title="Language" subtitle={subtitle} onBack={onClose} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px w-full max-w-[640px] mx-auto">
        {LANGUAGES.map((l, i) => (
          <div key={l.code} className="flex flex-col gap-px">
            {i === COMMON_LANGUAGES && <Section title="Other" />}
            <Row title={l.name} detail={l.code.toUpperCase()}
                 value={l.code === current ? <span className="t1-label !text-t1-accent">Selected</span> : undefined}
                 onClick={() => { onClose(); if (l.code !== current) onPick(l.code); }} />
          </div>
        ))}
      </div>
    </div>
  );
}

/** "Language · English" with Change: what a copy is in, and the way to change it. */
export function LanguageRow({ lang, title = "Language", onClick }: { lang: string; title?: string; onClick: () => void }) {
  return <Row title={`${title} · ${languageName(lang)}`} value={<span className="t1-label !text-t1-text">Change</span>} onClick={onClick} />;
}

/** The language new copies go in as, with its picker. */
export function NewCopiesLanguageRow({ lang, onChange }: { lang: string; onChange: (code: string) => void }) {
  const [picking, setPicking] = useState(false);
  return (
    <>
      <LanguageRow lang={lang} title="New copies in" onClick={() => setPicking(true)} />
      {picking && <LanguagePicker current={lang} subtitle="For new copies" onClose={() => setPicking(false)} onPick={onChange} />}
    </>
  );
}

/**
 * Card detail → a copy you own → Language: pick, then "One copy" or "All N copies" when there are several. Copies stay
 * where they are (Unsorted first, then binders), as one batch the caller can undo.
 */
export function OwnedLanguageRow({ item, label, onDone, onError }: {
  item: Item; label: string; onDone: (batch: string, text: string) => void; onError: (e: string) => void;
}) {
  const [picking, setPicking] = useState(false);
  const [asking, setAsking] = useState<string | null>(null);
  const run = async (lang: string, n: number) => {
    const ops = languageChangeOps(item, printingPlaces(item), lang, n);
    if (!ops) return;
    try {
      const res = await applyOps(ops);
      capture("language_changed", { where: "owned", copies: n });
      onDone(res.batch_id, `Moved ${n} ${label} to ${languageName(lang)}`);
    } catch (e) {
      onError(errorMessage(e));
    }
  };
  return (
    <>
      <LanguageRow lang={item.lang} onClick={() => setPicking(true)} />
      {picking && (
        <LanguagePicker current={item.lang} subtitle={label} onClose={() => setPicking(false)}
                        onPick={(lang) => { if (item.qty <= 1) void run(lang, 1); else setAsking(lang); }} />
      )}
      {asking && (
        <Menu title={`Mark as ${languageName(asking)}`} onClose={() => setAsking(null)} items={[
          { title: "One copy", onClick: () => void run(asking, 1) },
          { title: `All ${item.qty} copies`, onClick: () => void run(asking, item.qty) },
        ]} />
      )}
    </>
  );
}
