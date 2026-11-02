import { useEffect, useMemo, useState } from "react";
import { Row, Section } from "../components/kit";
import { capture } from "../lib/telemetry";
import { normName } from "../lib/catalog";
import { binderTotals, useBinders } from "../lib/binders";
import { countOf, useLists } from "../lib/lists";
import { useCollection } from "../lib/collection";
import { loadDemoLists } from "../lib/libraryDemo";
import { hitDetail, listMatches, listOrder } from "../lib/librarySearch";
import { LISTS_SHOWN, listHitHref, searchLists, type HitKind, type ListHit } from "../lib/listSearch";

/* Collection Search's decks, cubes, binders, archetypes and rankings (contract/library-search-2026-10-18.md
   § Collection search): your own lists matched here by name, then what library_search finds, a section per kind
   above the cards. */

interface Hit { key: string; title: string; detail: string; value?: number; href: string; whose: "mine" | "following" | "shared"; by: "name" | "card" }

const KINDS: { kind: HitKind; title: string }[] = [
  { kind: "deck", title: "Decks" },
  { kind: "cube", title: "Cubes" },
  { kind: "binder", title: "Binders" },
  { kind: "archetype", title: "Archetypes" },
  { kind: "ranking", title: "Rankings" },
];

export function ListHits({ query, userId, demo, go }: {
  query: string; userId: string | null; demo: boolean; go: (path: string) => void;
}) {
  const lists = useLists(userId, demo ? loadDemoLists : undefined);
  const b = useBinders(userId);
  const col = useCollection(userId);
  const totals = useMemo(() => binderTotals(col.items), [col.version, b.version]);
  const [others, setOthers] = useState<{ q: string; items: ListHit[] } | null>(null);
  const [open, setOpen] = useState<Set<HitKind>>(new Set());
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
    return KINDS.map(({ kind, title }) => {
      const mine: Hit[] = kind === "binder"
        ? listOrder(query, b.binders.filter((x) => listMatches(query, x.name, "")), (x) => x.name).map((x) => ({
            key: x.id, title: x.name, detail: hitDetail({ kind, for_trade: x.for_trade }),
            value: totals.byBinder.get(x.id), href: `/library/binder/${x.id}`, whose: "mine" as const, by: "name" as const }))
        : kind === "deck" || kind === "cube"
        ? listOrder(query, lists.lists.filter((l) => l.kind === kind && listMatches(query, l.name, l.format)), (l) => l.name).map((l) => ({
            key: l.id, title: l.name, detail: hitDetail({ kind, format: l.format }),
            value: countOf(l, "main"), href: `/library/list/${l.id}`, whose: "mine" as const, by: "name" as const }))
        : [];
      const seen = new Set(mine.map((h) => h.key));
      const found: Hit[] = (others?.q === query ? others.items : []).filter((h) => h.kind === kind && !seen.has(h.id)).flatMap((h) => {
        const href = listHitHref(h);
        if (!href) return [];
        return [{
          key: `${h.kind}|${h.id}`, title: h.name,
          detail: hitDetail({ kind: h.kind, format: h.format, for_trade: h.for_trade, owner: h.mine ? undefined : h.owner?.display_name,
                              has: h.has, decks: h.decks, label: h.label }),
          value: h.kind === "archetype" || h.kind === "ranking" ? undefined : h.cards, href,
          whose: h.mine ? "mine" as const : h.following ? "following" as const : "shared" as const,
          by: h.has ? "card" as const : "name" as const,
        }];
      });
      return { kind, title, hits: [...mine, ...found] };
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
                   onClick={() => { capture("search_list_opened", { kind: s.kind, whose: h.whose, by: h.by }); go(h.href); }} />
            ))}
            {!all && <Row title={`Show all ${s.hits.length}`} onClick={() => setOpen(new Set([...open, s.kind]))} />}
          </div>
        );
      })}
      {sections.length > 0 && <Section title="Cards" />}
    </>
  );
}
