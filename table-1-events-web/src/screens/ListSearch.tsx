import { useEffect, useMemo, useState } from "react";
import { Row, Section } from "../components/kit";
import { capture } from "../lib/telemetry";
import { formatName, normName } from "../lib/catalog";
import { binderTotals, useBinders } from "../lib/binders";
import { countOf, useLists } from "../lib/lists";
import { useCollection } from "../lib/collection";
import { loadDemoLists } from "../lib/libraryDemo";
import { listMatches, listOrder } from "../lib/librarySearch";
import { LISTS_SHOWN, listHitHref, searchLists, type ListHit } from "../lib/listSearch";
import type { FollowKind } from "../lib/follows";

/* Collection Search's decks, cubes and binders (contract/library-search-2026-10-18.md § Collection search): yours
   matched here, then everyone else's you can see from library_search, a section per kind above the cards. */

interface Hit { key: string; title: string; detail: string; value?: number; href: string; whose: "mine" | "following" | "shared" }

const KINDS: { kind: FollowKind; title: string; label: string }[] = [
  { kind: "deck", title: "Decks", label: "Deck" },
  { kind: "cube", title: "Cubes", label: "Cube" },
  { kind: "binder", title: "Binders", label: "Binder" },
];

export function ListHits({ query, userId, demo, go }: {
  query: string; userId: string | null; demo: boolean; go: (path: string) => void;
}) {
  const lists = useLists(userId, demo ? loadDemoLists : undefined);
  const b = useBinders(userId);
  const col = useCollection(userId);
  const totals = useMemo(() => binderTotals(col.items), [col.version, b.version]);
  const [others, setOthers] = useState<{ q: string; items: ListHit[] } | null>(null);
  const [open, setOpen] = useState<Set<FollowKind>>(new Set());
  const searching = normName(query).length >= 2;

  useEffect(() => {
    setOpen(new Set());
    if (!searching) return;
    let live = true;
    const t = setTimeout(() => {
      searchLists(query).then((items) => { if (live) setOthers({ q: query, items }); })
        // Offline or refused: yours still show.
        .catch(() => { if (live) setOthers({ q: query, items: [] }); });
    }, 300);
    return () => { live = false; clearTimeout(t); };
  }, [query, searching]);

  const sections = useMemo(() => {
    if (!searching) return [];
    return KINDS.map(({ kind, title, label }) => {
      const mine: Hit[] = kind === "binder"
        ? listOrder(query, b.binders.filter((x) => listMatches(query, x.name, "")), (x) => x.name).map((x) => ({
            key: x.id, title: x.name, detail: [label, x.for_trade ? "For trade" : null].filter(Boolean).join(" · "),
            value: totals.byBinder.get(x.id), href: `/library/binder/${x.id}`, whose: "mine" as const }))
        : listOrder(query, lists.lists.filter((l) => l.kind === kind && listMatches(query, l.name, l.format)), (l) => l.name).map((l) => ({
            key: l.id, title: l.name, detail: [label, kind === "deck" && l.format ? formatName(l.format) : null].filter(Boolean).join(" · "),
            value: countOf(l, "main"), href: `/library/list/${l.id}`, whose: "mine" as const }));
      const theirs: Hit[] = (others?.q === query ? others.items : []).filter((h) => h.kind === kind).flatMap((h) => {
        const href = listHitHref(h);
        if (!href) return [];
        return [{
          key: h.id, title: h.name,
          detail: [label, kind === "deck" && h.format ? formatName(h.format) : null, kind === "binder" && h.for_trade ? "For trade" : null,
                   h.owner?.display_name].filter(Boolean).join(" · "),
          value: h.cards, href, whose: h.following ? "following" as const : "shared" as const,
        }];
      });
      return { kind, title, hits: [...mine, ...theirs] };
    }).filter((s) => s.hits.length > 0);
  }, [searching, query, lists.lists, b.binders, totals, others]);

  return (
    <>
      {sections.map((s) => {
        const all = open.has(s.kind) || s.hits.length <= LISTS_SHOWN + 1;
        return (
          <div key={s.kind} className="flex flex-col gap-px">
            <Section title={s.title} count={s.hits.length} />
            {(all ? s.hits : s.hits.slice(0, LISTS_SHOWN)).map((h) => (
              <Row key={h.key} title={h.title} detail={h.detail} value={h.value}
                   onClick={() => { capture("search_list_opened", { kind: s.kind, whose: h.whose }); go(h.href); }} />
            ))}
            {!all && <Row title={`Show all ${s.hits.length}`} onClick={() => setOpen(new Set([...open, s.kind]))} />}
          </div>
        );
      })}
      {sections.length > 0 && <Section title="Cards" />}
    </>
  );
}
