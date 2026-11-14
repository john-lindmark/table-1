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
  drawDeckPhoto,
  loadDeckPhotos,
  loadMyDeckPhotos,
  myDeckPhotoDetail,
  myDeckPhotoGroups,
  myDeckPhotoSummary,
  readDeckPhoto,
  setDeckPhotoNote,
  turnDeckPhoto,
  turnDeckPhotoSaved,
  type DeckPhoto,
  type DeckPhotos,
  type MyDeckPhotos,
  type MyDeckPhoto,
} from "../lib/deckPhotos";
import { deckListRow, type DeckListBrief } from "../lib/deckPhotoList";
import type { Participant } from "../lib/types";
import { isLibraryDemo } from "../lib/libraryDemo";
import { Bar, Dialog, Menu, type MenuItem, Notice, Screen } from "../components/kit";

/**
 * Deck photos for one event, with notes (iOS DeckPhotosView). Players add their own; the organizer can add for
 * anyone, guests too. Until the event is over each player sees only their own (the organizer sees all); after,
 * everyone in it does. The server decides who sees and edits what; `organizer` only picks whose deck to ask about.
 */
export function DeckPhotosScreen({ eventId, organizer, onBack, onOpenList, startAdding = false }: {
  eventId: string; organizer: boolean; onBack: () => void;
  /** The decklist read from a photo (contract/deck-photo-lists-2026-11-13.md). */
  onOpenList: (photoId: string) => void;
  /** From the player screen's Add a deck photo: the camera / library choice for your own deck opens at once. */
  startAdding?: boolean;
}) {
  const { bundle } = useEvent(eventId);
  const { userId } = useSession();
  const [photos, setPhotos] = useState<DeckPhotos>({ shared: false, photos: [] });
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  /** Adding: whose deck, the picked photo, how it was picked and its quarter turns; then the note. */
  const [adding, setAdding] = useState<{ player: Participant; bitmap: ImageBitmap; source: "camera" | "library"; turns: number } | null>(null);
  const [editing, setEditing] = useState<DeckPhoto | null>(null);
  const [note, setNote] = useState("");
  /** Turns tapped but not yet saved, so Rotate answers at once. */
  const [turning, setTurning] = useState<Record<string, number>>({});
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

  // The menu opens on arrival; its Take a photo / Choose from photos tap is the gesture the file input needs.
  const started = useRef(false);
  useEffect(() => {
    if (!startAdding || started.current || !canAdd || !me) return;
    started.current = true;
    pickSource(me);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [startAdding, canAdd, me]);

  const addingBitmap = adding?.bitmap;
  useEffect(() => () => addingBitmap?.close(), [addingBitmap]);

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

  async function picked(file: File | undefined, source: "camera" | "library") {
    const player = pickingFor.current;
    if (!file || !player) return;
    try {
      const bitmap = await readDeckPhoto(file);
      setNote("");
      setAdding({ player, bitmap, source, turns: 0 });
    } catch (e) {
      setError(errorMessage(e));
    }
  }

  async function upload() {
    if (!adding || !event) return;
    const { player, bitmap, source, turns } = adding;
    const text = note.trim();
    setBusy(true);
    try {
      await show(await addDeckPhoto(eventId, player.id, await deckJpeg(bitmap, turns), text));
      setAdding(null);
      setError(null);
      capture("deck_photo_added", { source, own: player.id === me?.id, has_note: text.length > 0, turns,
                                    from: startAdding ? "prompt" : "screen",
                                    event_over: event.status === "completed" || event.status === "archived" });
    } catch (e) {
      setError(errorMessage(e));
      setAdding(null);
    } finally {
      setBusy(false);
    }
  }

  /** Rotate after upload: shown at once, saved as the photo's quarter turns. */
  async function turn(photo: DeckPhoto, by: number) {
    const next = turnDeckPhoto(turning[photo.id] ?? photo.turns, by);
    setTurning((t) => ({ ...t, [photo.id]: next }));
    try {
      await show(await turnDeckPhotoSaved(photo.id, next));
      setError(null);
      capture("deck_photo_turned", { turns: next, from: "event" });
    } catch (e) {
      setError(errorMessage(e));
    }
    setTurning((t) => {
      if (t[photo.id] !== next) return t;
      const rest = { ...t };
      delete rest[photo.id];
      return rest;
    });
  }

  function edit(photo: DeckPhoto) {
    if (!photo.editable) return;
    setMenu({
      title: photo.player,
      items: [
        { title: "Rotate right ↻", onClick: () => void turn(photo, 1) },
        { title: "Rotate left ↺", onClick: () => void turn(photo, -1) },
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
      capture("deck_photo_note_saved", { has_note: text.length > 0, from: "event" });
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
      capture("deck_photo_removed", { from: "event" });
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
        <PhotoCard
          key={photo.id}
          src={urls[photo.path]}
          player={photo.mine ? `${photo.player} · you` : photo.player}
          alt={`${photo.player}'s deck`}
          note={photo.note}
          turns={turning[photo.id] ?? photo.turns}
          onEdit={photo.editable ? () => edit(photo) : undefined}
          list={photo.list}
          onList={() => onOpenList(photo.id)}
        />
      ))}

      <input ref={cameraInput} type="file" accept="image/*" capture="environment" hidden
             onChange={(e) => { void picked(e.target.files?.[0], "camera"); e.target.value = ""; }} />
      <input ref={libraryInput} type="file" accept="image/*" hidden
             onChange={(e) => { void picked(e.target.files?.[0], "library"); e.target.value = ""; }} />

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
          <TurnedPreview bitmap={adding.bitmap} turns={adding.turns} />
          <div className="flex gap-px">
            {([[-1, "↺ Rotate left"], [1, "Rotate right ↻"]] as const).map(([by, label]) => (
              <button
                key={by}
                type="button"
                disabled={busy}
                onClick={() => setAdding((a) => (a ? { ...a, turns: turnDeckPhoto(a.turns, by) } : a))}
                className="flex-1 bg-t1-surface hover:bg-t1-surface-hover py-3 t1-label !text-t1-text"
              >
                {label}
              </button>
            ))}
          </div>
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

/**
 * Account → Deck photos (§ 7 On your account; iOS MyDeckPhotosView): every photo of a deck you played, headed by event,
 * newest first. A photo's menu opens its event or (once it's over) everyone's photos from it, then Rotate, note and
 * Remove as on the event's own screen.
 */
export function MyDeckPhotosScreen({ onBack, onOpenEvent, onOpenEventPhotos, onOpenList }: {
  onBack: () => void; onOpenEvent: (eventId: string) => void; onOpenEventPhotos: (eventId: string) => void;
  onOpenList: (photoId: string) => void;
}) {
  const [mine, setMine] = useState<MyDeckPhotos>({ total: 0, events: 0, photos: [] });
  const [urls, setUrls] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [editing, setEditing] = useState<MyDeckPhoto | null>(null);
  const [note, setNote] = useState("");
  const [turning, setTurning] = useState<Record<string, number>>({});
  const urlsRef = useRef<Record<string, string>>({});

  async function load() {
    if (isLibraryDemo()) {
      setMine(DEMO_MINE);
      setUrls(Object.fromEntries(DEMO_MINE.photos.map((p) => [p.path, DEMO_PHOTO])));
      setLoaded(true);
      return;
    }
    try {
      const next = await loadMyDeckPhotos();
      setMine(next);
      const missing = next.photos.map((p) => p.path).filter((p) => !urlsRef.current[p]);
      if (missing.length) {
        const fresh = await deckPhotoUrls(missing);
        urlsRef.current = { ...urlsRef.current, ...fresh };
        setUrls(urlsRef.current);
      }
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
    setLoaded(true);
  }

  useEffect(() => { void load(); }, []);

  async function act(call: () => Promise<unknown>, event: string, props: Record<string, unknown> = {}) {
    try {
      await call();
      capture(event, { ...props, from: "account" });
      await load();
    } catch (e) {
      setError(errorMessage(e));
    }
  }

  async function turn(photo: MyDeckPhoto, by: number) {
    const next = turnDeckPhoto(turning[photo.id] ?? photo.turns, by);
    setTurning((t) => ({ ...t, [photo.id]: next }));
    await act(() => turnDeckPhotoSaved(photo.id, next), "deck_photo_turned", { turns: next });
    setTurning((t) => {
      if (t[photo.id] !== next) return t;
      const rest = { ...t };
      delete rest[photo.id];
      return rest;
    });
  }

  function edit(photo: MyDeckPhoto) {
    const over = photo.eventStatus === "completed" || photo.eventStatus === "archived";
    setMenu({
      title: photo.eventName || photo.player,
      items: [
        { title: "Open event", onClick: () => { capture("my_deck_photo_opened", { to: "event" }); onOpenEvent(photo.eventId); } },
        ...(over ? [{ title: "Everyone's photos from this event", onClick: () => {
          capture("my_deck_photo_opened", { to: "event_photos" });
          onOpenEventPhotos(photo.eventId);
        } }] : []),
        { title: "Rotate right ↻", onClick: () => void turn(photo, 1) },
        { title: "Rotate left ↺", onClick: () => void turn(photo, -1) },
        { title: photo.note ? "Edit note" : "Add a note", onClick: () => { setNote(photo.note); setEditing(photo); } },
        { title: "Remove photo", onClick: () => void act(() => deleteDeckPhoto(photo), "deck_photo_removed") },
      ],
    });
  }

  async function saveNote() {
    if (!editing) return;
    const text = note.trim();
    setBusy(true);
    await act(() => setDeckPhotoNote(editing.id, text), "deck_photo_note_saved", { has_note: text.length > 0 });
    setEditing(null);
    setBusy(false);
  }

  return (
    <Screen>
      <Bar title="Deck photos" subtitle={loaded ? myDeckPhotoSummary(mine.total, mine.events) : undefined} onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      {!loaded ? (
        <Notice tone="info">Loading…</Notice>
      ) : mine.photos.length === 0 && !error ? (
        <Notice tone="info">No deck photos yet.</Notice>
      ) : null}
      {myDeckPhotoGroups(mine.photos).map((group) => {
        const detail = myDeckPhotoDetail(group.photos[0]);
        return (
          <div key={group.eventId} className="flex flex-col gap-px">
            <div className="bg-t1-surface px-4 py-2 t1-label">{detail ? `${group.title} · ${detail}` : group.title}</div>
            {group.photos.map((photo) => (
              <PhotoCard
                key={photo.id}
                src={urls[photo.path]}
                player={`${photo.player} · you`}
                alt={`${photo.player}'s deck`}
                note={photo.note}
                turns={turning[photo.id] ?? photo.turns}
                onEdit={() => edit(photo)}
                list={photo.list}
                onList={() => onOpenList(photo.id)}
              />
            ))}
          </div>
        );
      })}
      {loaded && mine.total > mine.photos.length && (
        <Notice tone="info">{`Showing the newest ${mine.photos.length} of ${mine.total}.`}</Notice>
      )}
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
      {editing && (
        <Dialog
          title={editing.eventName || editing.player}
          message="Deck photo"
          cancelLabel="Cancel"
          confirmLabel="Save note"
          busyLabel="Saving…"
          busy={busy}
          onCancel={() => setEditing(null)}
          onConfirm={() => void saveNote()}
        >
          <textarea
            value={note}
            onChange={(e) => setNote(e.target.value)}
            maxLength={2000}
            rows={4}
            autoFocus
            placeholder="Archetype, key cards, how it played…"
            className="bg-t1-surface px-3 py-3 outline-0 border-0 text-[14px] resize-none placeholder:text-t1-muted/60"
          />
        </Dialog>
      )}
    </Screen>
  );
}

/** `/me/deck-photos?demo`: three photos over two events, one saved with a quarter turn. */
export const DEMO_PHOTO = "data:image/svg+xml," + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1200"><rect width="1600" height="1200" fill="#282839"/>' +
  '<rect width="1600" height="120" fill="#00ffd9"/><text x="560" y="700" font-family="monospace" font-size="220" fill="#fff">TOP</text></svg>');
const demoRow = (id: string, eventId: string, eventName: string, eventStatus: string, formatLabel: string, eventAt: string,
                 note: string, turns: number, list: DeckListBrief | null = null): MyDeckPhoto => ({
  id, participantId: `p-${eventId}`, player: "Ann Ito", path: `demo/${id}.jpg`, note, createdAt: eventAt, mine: true,
  editable: true, turns, list, eventId, eventName, eventStatus, formatLabel, eventAt,
});
const DEMO_MINE: MyDeckPhotos = {
  total: 3, events: 2, photos: [
    demoRow("dp1", "ev-sealed", "Thursday Sealed", "in_progress", "Sealed", "2026-11-05T18:30:00Z", "Pool before building", 0),
    demoRow("dp2", "ev-draft", "Team Draft", "completed", "Team draft", "2026-10-29T18:00:00Z", "Mono red, 17 lands", 1,
            { status: "done", cards: 23, check: 2, checked: false }),
    demoRow("dp3", "ev-draft", "Team Draft", "completed", "Team draft", "2026-10-29T18:00:00Z", "", 0),
  ],
};

/** A deck photo with its player and note. The picture is a plain image, not inside a button, so a long press on a
    phone or a right-click gets the browser's own image menu (copy, save, share; contract/event-night-2026-10-16.md § 7
    "Long press"); a tap on it or on Edit opens the photo's menu when you may edit it. */
function PhotoCard({ src, player, alt, note, turns, onEdit, list, onList }: {
  src?: string; player: string; alt: string; note: string; turns: number; onEdit?: () => void;
  /** The row under the photo: where its decklist stands; a click opens the decklist. */
  list?: DeckListBrief | null; onList?: () => void;
}) {
  const upright = useUprightPhoto(src, turns);
  return (
    <div className="bg-t1-surface flex flex-col">
      <div className="w-full aspect-[4/3] bg-t1-bg overflow-hidden flex items-center justify-center relative">
        {upright ? (
          <TurnedPhoto src={upright} alt={alt} turns={0} onClick={onEdit} />
        ) : src ? (
          <TurnedPhoto src={src} alt={alt} turns={turns} onClick={onEdit} />
        ) : (
          <span className="t1-label">Loading…</span>
        )}
      </div>
      <button type="button" onClick={onEdit} disabled={!onEdit} className="px-4 py-3 flex flex-col gap-1.5 w-full text-left">
        <div className="flex items-center gap-3 w-full">
          <span className="t1-label !text-t1-text flex-1 truncate">{player}</span>
          {onEdit && <span className="t1-label">Edit</span>}
        </div>
        {note && <p className="text-[13px] whitespace-pre-wrap">{note}</p>}
      </button>
      {onList && (
        <button type="button" onClick={onList}
                className="border-t border-t1-bg hover:bg-t1-surface-hover px-4 py-3 w-full text-left t1-label !text-t1-text truncate">
          {deckListRow(list)}
        </button>
      )}
    </div>
  );
}

/** The photo drawn upright as its player turned it (a blob URL), so the browser's Copy and Save hand over what's on
    screen; the stored file is never turned. Undefined while drawing, with no turns, or if the file can't be read. */
export function useUprightPhoto(src: string | undefined, turns: number): string | undefined {
  const [url, setUrl] = useState<string>();
  useEffect(() => {
    setUrl(undefined);
    if (!src || turns % 4 === 0) return;
    let made: string | undefined;
    let live = true;
    void (async () => {
      try {
        const bitmap = await createImageBitmap(await (await fetch(src)).blob());
        const canvas = document.createElement("canvas");
        if (!drawDeckPhoto(canvas, bitmap, turns)) return;
        const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.9));
        if (!blob || !live) return;
        made = URL.createObjectURL(blob);
        setUrl(made);
      } catch {
        // The CSS-turned file stays on screen.
      }
    })();
    return () => { live = false; if (made) URL.revokeObjectURL(made); };
  }, [src, turns]);
  return url;
}

/** An uploaded photo, whole and turned as its player set it: for a quarter turn it's fitted into the 4:3 box's swapped
    sides (75% of the width, 133% of the height), then rotated into place. */
export function TurnedPhoto({ src, alt, turns, onClick }: { src: string; alt: string; turns: number; onClick?: () => void }) {
  const odd = turns % 2 === 1;
  return (
    <img
      src={src}
      alt={alt}
      onClick={onClick}
      onContextMenu={() => capture("image_menu", { screen: "deck_photo" })}
      className={`absolute top-1/2 left-1/2 object-contain ${onClick ? "cursor-pointer" : ""}`}
      style={{
        width: odd ? "75%" : "100%",
        height: odd ? "133.3333%" : "100%",
        transform: `translate(-50%, -50%) rotate(${turns * 90}deg)`,
        WebkitTouchCallout: "default",
      }}
    />
  );
}

/** The picked photo, whole and turned as it will be saved (drawn small; the full size is drawn once, on save). */
function TurnedPreview({ bitmap, turns }: { bitmap: ImageBitmap; turns: number }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (canvas.current) drawDeckPhoto(canvas.current, bitmap, turns, 900);
  }, [bitmap, turns]);
  return (
    <div className="bg-t1-bg h-[260px] flex items-center justify-center">
      <canvas ref={canvas} className="max-w-full max-h-[260px]" aria-label={`Deck photo, turned ${turns * 90}°`} />
    </div>
  );
}

/** /dev/events → Photos: the add preview with Rotate on a sample landscape picture marked TOP, then the same picture as
    uploaded photos saved with 0 and 1 turns (design QA without signing in). */
export function DeckPhotoDemo() {
  const [sample, setSample] = useState<{ bitmap: ImageBitmap; url: string } | null>(null);
  const [turns, setTurns] = useState(0);
  useEffect(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 1600;
    canvas.height = 1200;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.fillStyle = "#282839";
    ctx.fillRect(0, 0, 1600, 1200);
    ctx.fillStyle = "#00ffd9";
    ctx.fillRect(0, 0, 1600, 120);
    ctx.fillStyle = "#ffffff";
    ctx.font = "bold 220px monospace";
    ctx.fillText("TOP", 560, 640);
    let live = true;
    void createImageBitmap(canvas).then((bitmap) => { if (live) setSample({ bitmap, url: canvas.toDataURL("image/jpeg") }); });
    return () => { live = false; };
  }, []);
  if (!sample) return <Notice tone="info">Loading…</Notice>;
  return (
    <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
      <TurnedPreview bitmap={sample.bitmap} turns={turns} />
      <div className="flex gap-px">
        {([[-1, "↺ Rotate left"], [1, "Rotate right ↻"]] as const).map(([by, label]) => (
          <button key={by} type="button" onClick={() => setTurns((t) => turnDeckPhoto(t, by))}
                  className="flex-1 bg-t1-surface hover:bg-t1-surface-hover py-3 t1-label !text-t1-text">
            {label}
          </button>
        ))}
      </div>
      {[0, 1].map((saved) => (
        <div key={saved} className="bg-t1-surface flex flex-col">
          <div className="w-full aspect-[4/3] bg-t1-bg overflow-hidden flex items-center justify-center relative">
            <TurnedPhoto src={sample.url} alt="Sample deck" turns={saved} />
          </div>
          <p className="px-4 py-3 text-[13px]">Saved with {saved} turn{saved === 1 ? "" : "s"}</p>
        </div>
      ))}
    </div>
  );
}
