import { useEffect, useMemo, useRef, useState } from "react";
import { Navigate } from "react-router-dom";
import { errorMessage } from "../lib/api";
import { coverPrinting, loadCatalog, printingsByName, searchCatalog, type Catalog } from "../lib/catalog";
import {
  addDeckListCard, confirmDeckListLine, deckListCounts, deckListDeckEntries, deckListDeckFormat, deckListDeckName,
  deckListReading, deckListSizeLine, deckListSkippedNote, deckListTarget, deckListToCheck, loadDeckPhotoList,
  moveDeckListLine, replaceDeckListCard, saveDeckPhotoList, setDeckListQty, startDeckPhotoRead, toDeckPhotoList,
  type DeckListBoard, type DeckListCard, type DeckListEntry, type DeckPhotoListData,
} from "../lib/deckPhotoList";
import { deckPhotoUrls } from "../lib/deckPhotos";
import { loadDemoLists } from "../lib/libraryDemo";
import { createList, entry, useLists } from "../lib/lists";
import { capture } from "../lib/telemetry";
import { Bar, BigAction, Dialog, Field, Menu, type MenuItem, Notice, PodHeader, Row } from "../components/kit";
import { ZoomImage } from "../components/ZoomImage";
import { DEMO_PHOTO, TurnedPhoto, useUprightPhoto } from "./DeckPhotos";
import { CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";

const ROW_H = 58;
const BOARDS: [DeckListBoard, string][] = [["main", "Move to main deck"], ["side", "Move to sideboard"], ["out", "Leave out of the deck"]];

/**
 * The decklist read from a deck photo (contract/deck-photo-lists-2026-11-13.md; iOS DeckPhotoListView): the photo, the
 * size line, the list by board. Whoever may edit the photo corrects the list (saved 0.8 s after the last change);
 * everyone who sees it can change it here and add it to their own decks.
 */
export function DeckPhotoListScreen({ photoId, from, onBack, onOpenDeck }: {
  photoId: string; from: string; onBack: () => void; onOpenDeck: (listId: string) => void;
}) {
  const { session, ready, userId, demo } = useLibrarySession();
  useLists(userId, demo ? loadDemoLists : undefined);
  const { catalog } = useCatalog();
  const [data, setData] = useState<DeckPhotoListData | null>(null);
  const [entries, setEntries] = useState<DeckListEntry[]>([]);
  const [url, setUrl] = useState<string>();
  const [error, setError] = useState<string | null>(null);
  /** Changes not yet sent (editors): saved 0.8 s after the last one. */
  const [dirty, setDirty] = useState(0);
  const [saved, setSaved] = useState(false);
  const [outOpen, setOutOpen] = useState(false);
  const [added, setAdded] = useState<{ listId: string; skipped: number } | null>(null);
  const [adding, setAdding] = useState(false);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [picking, setPicking] = useState<{ title: string; query: string; onPick: (card: DeckListCard) => void } | null>(null);
  const [asking, setAsking] = useState(false);
  const [zoomed, setZoomed] = useState(false);
  const entriesRef = useRef(entries);
  entriesRef.current = entries;
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;

  const editable = data?.editable === true;
  const reading = deckListReading(data);
  const counts = useMemo(() => deckListCounts(entries), [entries]);
  const target = deckListTarget(data?.event.eventType, data?.event.format);
  const upright = useUprightPhoto(url, data?.turns ?? 0);

  useEffect(() => {
    if (!ready || !session) return;
    let live = true;
    void (async () => {
      try {
        if (demo) {
          const c = await loadCatalog();
          if (!live) return;
          const d = demoList(photoId, c);
          setData(d);
          setEntries(d.entries);
          setUrl(DEMO_PHOTO);
          capture("deck_list_opened", { status: d.status, mine: d.mine, editable: d.editable, from });
          return;
        }
        const d = await loadDeckPhotoList(photoId);
        if (!live) return;
        setData(d);
        setEntries(d.entries);
        setError(null);
        capture("deck_list_opened", { status: d.status, mine: d.mine, editable: d.editable, from });
        if (d.path) {
          const urls = await deckPhotoUrls([d.path]);
          if (live) setUrl(urls[d.path]);
        }
      } catch (e) {
        if (live) setError(errorMessage(e));
      }
    })();
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [photoId, ready, !!session]);

  // A phone never waits on the read: ask again every 3 s while it's queued or under way.
  useEffect(() => {
    if (!reading || demo) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout>;
    const tick = async () => {
      const d = await loadDeckPhotoList(photoId).catch(() => null);
      if (!live) return;
      if (d) {
        setData(d);
        if (!deckListReading(d)) {
          setEntries(d.entries);
          setDirty(0);
          return;
        }
      }
      timer = setTimeout(() => void tick(), 3000);
    };
    timer = setTimeout(() => void tick(), 3000);
    return () => { live = false; clearTimeout(timer); };
  }, [reading, photoId, demo]);

  useEffect(() => {
    if (dirty <= 0 || !editable) return;
    const mark = dirty;
    const timer = setTimeout(() => {
      const sent = entriesRef.current;
      if (demo) { setDirty(0); setSaved(true); return; }
      saveDeckPhotoList(photoId, sent).then((d) => {
        const c = deckListCounts(sent);
        capture("deck_list_saved", { lines: sent.length, cards: c.main + c.side, check: c.check });
        if (dirtyRef.current === mark) {
          setDirty(0);
          setData(d);
          setSaved(true);
          setError(null);
        }
      }, (e) => setError(errorMessage(e)));
    }, 800);
    return () => clearTimeout(timer);
  }, [dirty, editable, photoId, demo]);

  function read(again: boolean) {
    capture("deck_list_read_asked", { again });
    if (demo) return;
    startDeckPhotoRead(photoId).then((d) => {
      setDirty(0);
      setData(d);
      if (!again) setEntries(d.entries);
      setSaved(false);
      setError(null);
    }, (e) => setError(errorMessage(e)));
  }

  function change(op: string, edit: (es: DeckListEntry[]) => DeckListEntry[]) {
    setEntries(edit(entriesRef.current));
    setAdded(null);
    setSaved(false);
    capture("deck_list_edited", { op, editable });
    if (editable) setDirty((n) => n + 1);
  }

  function openMenu(i: number, e: DeckListEntry) {
    const items: MenuItem[] = [{
      title: "Change card",
      onClick: () => setPicking({ title: e.name, query: e.cardId ? "" : e.name, onPick: (card) => change("replace", (es) => replaceDeckListCard(es, i, card)) }),
    }];
    if (e.cardId && !e.sure && e.board !== "out") {
      items.push({ title: "Looks right", onClick: () => change("confirm", (es) => confirmDeckListLine(es, i)) });
    }
    for (const [board, title] of BOARDS) {
      if (board !== e.board) items.push({ title, onClick: () => change("move", (es) => moveDeckListLine(es, i, board)) });
    }
    items.push({ title: "Remove", onClick: () => change("remove", (es) => setDeckListQty(es, i, 0)) });
    setMenu({ title: e.read ? `${e.name} · ${e.read}` : e.name, items });
  }

  async function toDeck() {
    if (!data || adding) return;
    const out = deckListDeckEntries(entries);
    setAdding(true);
    try {
      const listId = await createList(
        "deck", deckListDeckName(data.event.name, data.player, data.mine), deckListDeckFormat(data.event.eventType, data.event.format),
        out.entries.map(([cardId, board, qty]) => entry(cardId, board, qty)),
        data.mine ? "From your deck photo" : `From ${data.player || "a player"}'s deck photo`.slice(0, 120), "deck_photo");
      capture("deck_list_to_deck", { cards: counts.main + counts.side, skipped: out.skipped, mine: data.mine, checked: data.checked });
      setAdded({ listId, skipped: out.skipped });
      setError(null);
    } catch (e) {
      setError(`Couldn't add it: ${errorMessage(e)}`);
    } finally {
      setAdding(false);
    }
  }

  function detail(d: DeckPhotoListData): string {
    const parts: string[] = [];
    if (counts.side > 0) parts.push(`${counts.side} sideboard`);
    if (counts.check > 0) parts.push(`${counts.check} to check`);
    else if (d.checked) parts.push("Checked");
    if (d.pool.label && d.pool.size > 0) parts.push(d.pool.label);
    return parts.length ? parts.join(" · ") : d.event.formatLabel || "Read from the photo";
  }

  const lines = (board: DeckListBoard) => entries.map((e, i) => ({ e, i })).filter((x) => x.e.board === board).map(({ e, i }) => (
    <Line key={`${board}-${i}`} c={catalog} e={e}
          onMenu={() => openMenu(i, e)}
          onFewer={() => change("qty", (es) => setDeckListQty(es, i, (es[i]?.qty ?? 0) - 1))}
          onMore={() => change("qty", (es) => setDeckListQty(es, i, (es[i]?.qty ?? 0) + 1))} />
  ));

  // Signed in only, like the photo itself.
  if (ready && !session) return <Navigate to="/" replace />;

  const shown = upright ?? (url && (data?.turns ?? 0) % 4 === 0 ? url : undefined);
  const alt = data?.player ? `${data.player}'s deck` : "Deck photo";
  const empty = !!data && (data.status === "none" || (data.status === "failed" && entries.length === 0));

  return (
    <LibScreen>
      <Bar title="Decklist" subtitle={data ? [data.player, data.event.name].filter(Boolean).join(" · ") : undefined} onBack={onBack}
           right={saved ? <span className="t1-label !text-t1-accent">Saved</span> : undefined} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="shrink-0 w-full aspect-[4/3] bg-t1-bg overflow-hidden flex items-center justify-center relative">
          {upright ? (
            <TurnedPhoto src={upright} alt={alt} turns={0} onClick={() => { setZoomed(true); capture("image_zoomed", { screen: "deck_photo_list" }); }} />
          ) : url ? (
            <TurnedPhoto src={url} alt={alt} turns={data?.turns ?? 0}
                         onClick={shown ? () => { setZoomed(true); capture("image_zoomed", { screen: "deck_photo_list" }); } : undefined} />
          ) : (
            <span className="t1-label">{data || error ? "" : "Loading…"}</span>
          )}
        </div>
        {error && <Notice tone="error">{error}</Notice>}
        {!data ? (
          !error && <Notice tone="info">Loading…</Notice>
        ) : reading && entries.length === 0 ? (
          <>
            <PodHeader title="Reading the photo" />
            {(data.steps.length ? data.steps : ["Waiting to start"]).map((s, i) => <Row key={i} title={s} />)}
          </>
        ) : empty ? (
          <>
            {data.message && <Notice tone="info">{data.message}</Notice>}
            <BigAction label="Read decklist" onClick={() => read(false)} />
          </>
        ) : (
          <>
            <div className="shrink-0 bg-t1-surface px-4 py-4 flex flex-col gap-1.5">
              <p className="text-[18px] leading-snug font-bold uppercase tracking-[2px]">{deckListSizeLine(counts.main, target)}</p>
              <p className="t1-label">{detail(data)}</p>
            </div>
            {reading && <Notice tone="info">Reading the photo again…</Notice>}
            {data.message && <Notice tone="info">{data.message}</Notice>}
            <PodHeader title="Main deck" right={counts.main} />
            {lines("main")}
            {counts.side > 0 && (
              <>
                <PodHeader title="Sideboard" right={counts.side} />
                {lines("side")}
              </>
            )}
            <Row title="Add a card" onClick={() => setPicking({ title: "Add a card", query: "", onPick: (card) => change("add", (es) => addDeckListCard(es, card, "main")) })} />
            {counts.out > 0 && (
              <>
                <button type="button" className="text-left w-full" aria-expanded={outOpen} onClick={() => setOutOpen((o) => !o)}>
                  <PodHeader title={`Left out · ${counts.out}`} right={outOpen ? "Hide" : "Show"} />
                </button>
                {outOpen && (
                  <>
                    <Notice tone="info">In the photo but not in the deck: lying sideways, off the mat or cut off.</Notice>
                    {lines("out")}
                  </>
                )}
              </>
            )}
            {editable && !reading && data.readsLeft > 0 && (
              <div className="shrink-0 pt-4">
                <Row title="Read the photo again" onClick={() => setAsking(true)} />
              </div>
            )}
          </>
        )}
      </div>
      {added ? (
        <div className="shrink-0 flex flex-col gap-px">
          {added.skipped > 0 && <Notice tone="info">{deckListSkippedNote(added.skipped)}</Notice>}
          <BigAction label="Open deck" tone="accent" onClick={() => onOpenDeck(added.listId)} />
        </div>
      ) : data && !empty && counts.main + counts.side > 0 ? (
        <div className="shrink-0">
          <BigAction label="Add to my decks" busy={adding} onClick={() => void toDeck()} />
        </div>
      ) : null}

      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
      {asking && (
        <Dialog title="Read the photo again?" message="Reading again replaces this list." cancelLabel="Cancel" confirmLabel="Read again"
                onCancel={() => setAsking(false)} onConfirm={() => { setAsking(false); read(true); }} />
      )}
      {picking && (
        <PickPanel c={catalog} title={picking.title} query={picking.query} onClose={() => setPicking(null)}
                   onPick={(card) => { const pick = picking.onPick; setPicking(null); pick(card); }} />
      )}
      {zoomed && shown && (
        <ZoomImage src={shown} alt={alt} title="Deck photo" subtitle={data?.player || undefined} screen="deck_photo_list" onClose={() => setZoomed(false)} />
      )}
    </LibScreen>
  );
}

/** One line: the card (a click opens its menu), then − count +. A line to check says why on a second line. */
function Line({ c, e, onMenu, onFewer, onMore }: {
  c: Catalog | null; e: DeckListEntry; onMenu: () => void; onFewer: () => void; onMore: () => void;
}) {
  const check = deckListToCheck(e);
  const note = !e.cardId ? "No card by this name · pick the card" : check ? e.read || "Not sure" : undefined;
  const tag = check ? <span className="t1-label !text-t1-text">Check</span> : undefined;
  const step = "w-11 shrink-0 bg-t1-surface-hover text-[20px] disabled:text-t1-disabled";
  return (
    <div className="shrink-0 flex items-stretch gap-px" style={{ height: ROW_H }}>
      <div className="flex-1 min-w-0">
        {c ? (
          <CardRow c={c} p={e.cardId ? c.printingIndex.get(e.cardId) ?? null : null} title={e.name} detail={note} value={tag} onClick={onMenu} />
        ) : (
          <button type="button" onClick={onMenu} className="bg-t1-surface hover:bg-t1-surface-hover px-4 h-full flex items-center gap-3 text-left w-full">
            <span className="flex-1 min-w-0 flex flex-col gap-0.5">
              <span className="text-[13px] truncate">{e.name}</span>
              {note && <span className="t1-label truncate">{note}</span>}
            </span>
            {tag}
          </button>
        )}
      </div>
      <button type="button" aria-label={`One fewer ${e.name}`} className={step} onClick={onFewer}>−</button>
      <span className="min-w-[34px] px-1 shrink-0 bg-t1-surface flex items-center justify-center text-[16px] tabular-nums" aria-label={`${e.qty} ${e.name}`}>{e.qty}</span>
      <button type="button" aria-label={`One more ${e.name}`} className={step} disabled={e.qty >= 99} onClick={onMore}>+</button>
    </div>
  );
}

/** Pick the card a line really is, or a card to add: a search of every card; the pick is the card's usual printing. */
function PickPanel({ c, title, query, onPick, onClose }: {
  c: Catalog | null; title: string; query: string; onPick: (card: DeckListCard) => void; onClose: () => void;
}) {
  const [q, setQ] = useState(query);
  const hits = useMemo(() => (c ? searchCatalog(c, q, 40) : []), [c, q]);
  return (
    <div className="fixed inset-0 z-50 bg-t1-bg flex flex-col gap-px" role="dialog" aria-modal="true" aria-label={title}>
      <Bar title={title} onBack={onClose} />
      <Field label="Card name" value={q} onChange={setQ} autoFocus />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!c && <div className="bg-t1-surface px-4 py-4 t1-label">Loading cards…</div>}
        {c && q.trim().length >= 2 && hits.length === 0 && <div className="bg-t1-surface px-4 py-4 t1-label">No card by that name</div>}
        {c && hits.map((i) => {
          const p = coverPrinting(c, i);
          return (
            <div key={i} className="shrink-0" style={{ height: ROW_H }}>
              <CardRow c={c} p={p} title={c.oName[i]} detail={c.oType[i]} value="Pick" onClick={() => onPick({ cardId: c.pId[p], name: c.oName[i] })} />
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** Dev server `?demo`: a draft deck read from a photo, with a pile to check, a title with no card and a card left out. */
function demoList(photoId: string, c: Catalog): DeckPhotoListData {
  if (!import.meta.env.DEV) return toDeckPhotoList({ photo_id: photoId });
  const rows: [string, number, DeckListBoard, boolean, string?][] = [
    ["Lightning Bolt", 2, "main", true], ["Counterspell", 2, "main", true], ["Ragavan, Nimble Pilferer", 1, "main", true],
    ["Island", 8, "main", false, "pile of about 8, no die"], ["Mountain", 8, "main", true], ["Room of", 1, "main", false],
    ["Mana Drain", 1, "side", true], ["Brainstorm", 1, "out", true],
  ];
  const byName = printingsByName(c, rows.map((r) => r[0]));
  return toDeckPhotoList({
    photo_id: photoId, event_id: "ev-draft", player: "Ann Ito", path: "demo/photo.jpg", turns: 0, status: "done",
    steps: ["Looking at the photo", "Read 23 cards: 2 to check"],
    entries: rows.map(([name, qty, board, sure, read]) => {
      const p = byName.get(name);
      return { card_id: p === undefined ? null : c.pId[p], name, qty, board, sure, read };
    }),
    pool: { kind: "set", label: "Reality Fracture · 285 cards", size: 285 }, checked: false, editable: true, mine: true, reads_left: 4,
    event: { name: "Team Draft", format: "draft", event_type: "limited", format_label: "Draft" },
  });
}
