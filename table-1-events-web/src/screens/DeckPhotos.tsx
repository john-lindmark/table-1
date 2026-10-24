import { useEffect, useMemo, useRef, useState } from "react";
import { errorMessage } from "../lib/api";
import { capture } from "../lib/telemetry";
import { useEvent } from "../lib/useEvent";
import { useSession } from "../lib/useSession";
import {
  addDeckPhoto,
  deckJpeg,
  deckPhotoUrls,
  deleteDeckPhoto,
  loadDeckPhotos,
  setDeckPhotoNote,
  type DeckPhoto,
  type DeckPhotos,
} from "../lib/deckPhotos";
import type { Participant } from "../lib/types";
import { Bar, Dialog, Menu, type MenuItem, Notice, Screen } from "../components/kit";

/**
 * Deck photos for one event, with notes (iOS DeckPhotosView). Players add their own; the organizer can add for
 * anyone, guests too. Until the event is over each player sees only their own (the organizer sees all); after,
 * everyone in it does. The server decides who sees and edits what; `organizer` only picks whose deck to ask about.
 */
export function DeckPhotosScreen({ eventId, organizer, onBack }: { eventId: string; organizer: boolean; onBack: () => void }) {
  const { bundle } = useEvent(eventId);
  const { userId } = useSession();
  const [photos, setPhotos] = useState<DeckPhotos>({ shared: false, photos: [] });
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  /** Adding: whose deck, the picked file and how it was picked; then the note. */
  const [adding, setAdding] = useState<{ player: Participant; file: File; preview: string; source: "camera" | "library" } | null>(null);
  const [editing, setEditing] = useState<DeckPhoto | null>(null);
  const [note, setNote] = useState("");
  const pickingFor = useRef<Participant | null>(null);
  const cameraInput = useRef<HTMLInputElement>(null);
  const libraryInput = useRef<HTMLInputElement>(null);

  const me = useMemo(() => (userId ? bundle?.participants.find((p) => p.userId === userId) ?? null : null), [bundle, userId]);
  const event = bundle?.event;
  const canAdd = !!event && event.status !== "cancelled" && (!!me || organizer);

  async function show(next: DeckPhotos) {
    setPhotos(next);
    const missing = next.photos.map((p) => p.path).filter((p) => !urls[p]);
    if (missing.length) {
      const fresh = await deckPhotoUrls(missing);
      setUrls((prev) => ({ ...prev, ...fresh }));
    }
  }

  useEffect(() => {
    let live = true;
    loadDeckPhotos(eventId)
      .then(async (p) => { if (live) await show(p); })
      .then(() => { if (live) setError(null); })
      .catch((e) => { if (live) setError(errorMessage(e)); })
      .finally(() => { if (live) setLoaded(true); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [eventId]);

  useEffect(() => () => { if (adding) URL.revokeObjectURL(adding.preview); }, [adding]);

  /** Whose deck: yourself, or (organizer) any player. Then camera or library, then a note. */
  function add() {
    if (busy || !bundle) return;
    if (organizer) {
      const players = [...bundle.participants].sort((a, b) =>
        Number(b.id === me?.id) - Number(a.id === me?.id) || a.displayName.localeCompare(b.displayName));
      setMenu({
        title: "Whose deck?",
        items: players.map((p) => ({ title: p.id === me?.id ? `${p.displayName} (you)` : p.displayName, onClick: () => pickSource(p) })),
      });
    } else if (me) {
      pickSource(me);
    }
  }

  function pickSource(player: Participant) {
    pickingFor.current = player;
    setMenu({
      title: player.displayName,
      items: [
        { title: "Take a photo", onClick: () => cameraInput.current?.click() },
        { title: "Choose from photos", onClick: () => libraryInput.current?.click() },
      ],
    });
  }

  function picked(file: File | undefined, source: "camera" | "library") {
    const player = pickingFor.current;
    if (!file || !player) return;
    setNote("");
    setAdding({ player, file, preview: URL.createObjectURL(file), source });
  }

  async function upload() {
    if (!adding || !event) return;
    const { player, file, source } = adding;
    const text = note.trim();
    setBusy(true);
    try {
      await show(await addDeckPhoto(eventId, player.id, await deckJpeg(file), text));
      setAdding(null);
      setError(null);
      capture("deck_photo_added", { source, own: player.id === me?.id, has_note: text.length > 0,
                                    event_over: event.status === "completed" || event.status === "archived" });
    } catch (e) {
      setError(errorMessage(e));
      setAdding(null);
    } finally {
      setBusy(false);
    }
  }

  function edit(photo: DeckPhoto) {
    if (!photo.editable) return;
    setMenu({
      title: photo.player,
      items: [
        { title: photo.note ? "Edit note" : "Add a note", onClick: () => { setNote(photo.note); setEditing(photo); } },
        { title: "Remove photo", onClick: () => void remove(photo) },
      ],
    });
  }

  async function saveNote() {
    if (!editing) return;
    const text = note.trim();
    setBusy(true);
    try {
      await show(await setDeckPhotoNote(editing.id, text));
      setEditing(null);
      setError(null);
      capture("deck_photo_note_saved", { has_note: text.length > 0 });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  async function remove(photo: DeckPhoto) {
    try {
      await show(await deleteDeckPhoto(photo));
      setError(null);
      capture("deck_photo_removed");
    } catch (e) {
      setError(errorMessage(e));
    }
  }

  const noteField = (
    <textarea
      value={note}
      onChange={(e) => setNote(e.target.value)}
      maxLength={2000}
      rows={4}
      autoFocus
      placeholder="Archetype, key cards, how it played…"
      className="bg-t1-surface px-3 py-3 outline-0 border-0 text-[14px] resize-none placeholder:text-t1-muted/60"
    />
  );

  return (
    <Screen>
      <Bar title="Deck photos" subtitle={event?.name} onBack={onBack} />
      {canAdd && (
        <div className="flex gap-px">
          <button
            type="button"
            onClick={add}
            disabled={busy}
            className={`flex-1 px-4 py-4 text-[12px] uppercase tracking-[1px] ${busy ? "bg-t1-disabled text-t1-ink" : "bg-t1-accent text-t1-ink"}`}
          >
            {busy ? "Uploading…" : "Add a deck photo"}
          </button>
        </div>
      )}
      {error && <Notice tone="error">{error}</Notice>}
      {loaded && !error && !photos.shared && (
        <Notice tone="info">
          {organizer
            ? "Players see only their own photos until the event is over. Then everyone in it sees all of them."
            : "Only you and the organizer see your photos until the event is over. Then everyone in it sees all of them."}
        </Notice>
      )}
      {!loaded ? (
        <Notice tone="info">Loading…</Notice>
      ) : photos.photos.length === 0 && !error ? (
        <Notice tone="info">No deck photos yet.</Notice>
      ) : null}
      {photos.photos.map((photo) => (
        <button
          key={photo.id}
          type="button"
          onClick={() => edit(photo)}
          disabled={!photo.editable}
          className="bg-t1-surface flex flex-col text-left"
        >
          <div className="w-full aspect-[4/3] bg-t1-bg overflow-hidden flex items-center justify-center">
            {urls[photo.path] ? (
              <img src={urls[photo.path]} alt={`${photo.player}'s deck`} className="w-full h-full object-cover" />
            ) : (
              <span className="t1-label">Loading…</span>
            )}
          </div>
          <div className="px-4 py-3 flex flex-col gap-1.5 w-full">
            <div className="flex items-center gap-3">
              <span className="t1-label !text-t1-text flex-1 truncate">{photo.mine ? `${photo.player} · you` : photo.player}</span>
              {photo.editable && <span className="t1-label">Edit</span>}
            </div>
            {photo.note && <p className="text-[13px] whitespace-pre-wrap">{photo.note}</p>}
          </div>
        </button>
      ))}

      <input ref={cameraInput} type="file" accept="image/*" capture="environment" hidden
             onChange={(e) => { picked(e.target.files?.[0], "camera"); e.target.value = ""; }} />
      <input ref={libraryInput} type="file" accept="image/*" hidden
             onChange={(e) => { picked(e.target.files?.[0], "library"); e.target.value = ""; }} />

      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
      {adding && (
        <Dialog
          title={adding.player.displayName}
          cancelLabel="Cancel"
          confirmLabel="Save photo"
          busyLabel="Uploading…"
          busy={busy}
          onCancel={() => setAdding(null)}
          onConfirm={() => void upload()}
        >
          <img src={adding.preview} alt="" className="w-full h-[180px] object-cover" />
          {noteField}
        </Dialog>
      )}
      {editing && (
        <Dialog
          title={editing.player}
          message="Deck photo"
          cancelLabel="Cancel"
          confirmLabel="Save note"
          busyLabel="Saving…"
          busy={busy}
          onCancel={() => setEditing(null)}
          onConfirm={() => void saveNote()}
        >
          {noteField}
        </Dialog>
      )}
    </Screen>
  );
}
