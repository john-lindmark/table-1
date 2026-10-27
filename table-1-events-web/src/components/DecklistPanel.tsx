import { useEffect, useState } from "react";
import { errorMessage, fetchDecklist, removeDecklist, submitDecklist } from "../lib/api";
import { countOf, current, useLists } from "../lib/lists";
import { exportLines, renderList } from "../lib/listExport";
import { countsText, deckFormat, decklistCounts } from "../lib/scheduledEvents";
import type { Table1Event } from "../lib/types";
import { useSession } from "../lib/useSession";
import { useCatalog } from "../screens/Library";
import { beforeRound1 } from "./EventExtras";
import { GhostAction, Modal, Notice, Row, Segmented } from "./kit";

// Loaded on first open (EventExtras' lazy DecklistPanel): it needs the Library's lists and card data.

/**
 * A player's decklist for a constructed event (or, for the organizer, anyone's): from your decks in the event's format,
 * or pasted text, with the counts as you type. Players change theirs until round 1; organizers any time.
 */
export function DecklistPanel({ event, participantId, playerName, byOrganizer, onClose }: {
  event: Table1Event; participantId: string; playerName: string; byOrganizer: boolean; onClose: (changed: boolean) => void;
}) {
  const { userId } = useSession();
  const { lists } = useLists(byOrganizer ? null : userId);
  const { catalog } = useCatalog();
  const [source, setSource] = useState<"deck" | "text">(byOrganizer ? "text" : "deck");
  const [text, setText] = useState("");
  const [listId, setListId] = useState<string | null>(null);
  const [existing, setExisting] = useState<{ main: number; side: number; listName: string | null } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const locked = !byOrganizer && !beforeRound1(event);
  const want = deckFormat(event.formatName);
  const decks = lists.filter((l) => l.kind === "deck" && (want == null || l.format === want));
  const counts = decklistCounts(text);

  useEffect(() => {
    void fetchDecklist(participantId).then((d) => {
      if (!d) return;
      setExisting({ main: d.mainCount, side: d.sideCount, listName: d.listName });
      setText(d.body);
      setListId(d.listId);
      if (!d.listId) setSource("text");
    }, () => {});
  }, [participantId]);

  const pick = (id: string) => {
    const l = decks.find((d) => d.id === id);
    if (!l || !catalog) {
      setError("The card data is still loading. Try again in a moment, or paste the list.");
      return;
    }
    const { lines, left } = exportLines(catalog, (current(l)?.entries ?? []).filter((e) => e.board !== "maybe"));
    setText(renderList(lines, "deck", "text"));
    setListId(l.id);
    setError(left > 0 ? `${left} card${left === 1 ? "" : "s"} in that deck aren't in the card data yet and were left out.` : null);
  };

  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      onClose(true);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal title="Decklist" onClose={() => onClose(false)}>
      <div className="flex flex-col gap-px max-h-[75vh] overflow-y-auto -mx-6 -my-2">
        <Row title="Decklist" detail={`${playerName} · ${event.formatLabel}`} />
        {existing && <Row title="Sent" detail={countsText(existing.main, existing.side) + (existing.listName ? ` · from ${existing.listName}` : "")} />}
        {locked ? (
          <>
            <Notice tone="info">Decklists lock when round 1 is paired. Ask the organizer to change yours.</Notice>
            {text && <pre className="bg-t1-surface px-4 py-3 text-[12px] whitespace-pre-wrap">{text}</pre>}
          </>
        ) : (
          <>
            {!byOrganizer && (
              <Segmented value={source} onChange={(v) => setSource(v)}
                         options={[{ value: "deck", label: "From my decks" }, { value: "text", label: "Paste text" }]} />
            )}
            {source === "deck" && !byOrganizer && (
              decks.length === 0
                ? <Notice tone="info">No decks in this format in your Library yet. Paste the list instead.</Notice>
                : decks.map((d) => (
                    <Row key={d.id} title={d.name} detail={`${countOf(d, "main")} main · ${countOf(d, "side")} sideboard`}
                         value={listId === d.id ? "Picked" : undefined} accentValue onClick={() => pick(d.id)} />
                  ))
            )}
            {(source === "text" || byOrganizer || listId) && (
              <>
                <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
                  <span className="t1-label">{listId ? "From your deck" : "The list"}</span>
                  <textarea
                    value={text}
                    readOnly={!!listId && source === "deck"}
                    onChange={(e) => { setText(e.target.value); if (source === "text") setListId(null); }}
                    rows={10}
                    spellCheck={false}
                    placeholder={"4 Lightning Bolt\n4 Ragavan, Nimble Pilferer\n…\n\nSideboard\n2 Pyroblast"}
                    className="bg-transparent border-0 outline-0 text-[13px] text-t1-text font-mono resize-y"
                  />
                </label>
                <Row title={countsText(counts.main, counts.side)} detail="One card a line: 4 Lightning Bolt. Sideboard after a Sideboard line or a blank line." />
              </>
            )}
            {error && <Notice tone="error">{error}</Notice>}
            <div className="flex gap-px">
              {existing && <GhostAction label="Remove" disabled={busy} onClick={() => run(() => removeDecklist(participantId))} />}
              <GhostAction label={busy ? "Sending…" : existing ? "Send again" : "Send"} disabled={busy || counts.main === 0}
                           onClick={() => run(() => submitDecklist(participantId, text, listId, byOrganizer))} />
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}

