import { toDeckListBrief, type DeckListBrief } from "./deckPhotoList";
import { supabase } from "./supabaseClient";

/* Deck photos (contract/event-night-2026-10-16.md § 7): players add their own, the organizer adds for anyone (guests
   too). Each player sees their own until the event is over, the organizer sees all; then everyone in it does. Files
   live in the private `deck-photos` bucket at <event_id>/<photo_id>.jpg; the rows behind the deck_photo* RPCs. */

export interface DeckPhoto {
  id: string;
  participantId: string;
  player: string;
  path: string;
  note: string;
  createdAt: string;
  mine: boolean;
  editable: boolean;
  /** Quarter turns clockwise to draw it upright, set after upload (0 from servers before 2026-10-30). */
  turns: number;
  /** Where its decklist stands (contract/deck-photo-lists-2026-11-13.md); null when never queued. */
  list: DeckListBrief | null;
}

export interface DeckPhotos {
  shared: boolean;
  photos: DeckPhoto[];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function toPhotos(raw: any): DeckPhotos {
  return {
    shared: !!raw?.shared,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    photos: (raw?.photos ?? []).map((p: any) => ({
      id: p.id, participantId: p.participant_id, player: p.player ?? "", path: p.path, note: p.note ?? "",
      createdAt: p.created_at, mine: !!p.mine, editable: !!p.editable, turns: Number(p.turns ?? 0) || 0,
      list: toDeckListBrief(p.list),
    })),
  };
}

export async function loadDeckPhotos(eventId: string): Promise<DeckPhotos> {
  const { data, error } = await supabase.rpc("deck_photos", { p_event_id: eventId });
  if (error) throw error;
  return toPhotos(data);
}

/** Uploads the JPEG to <event_id>/<photo_id>.jpg, then records it for the player. */
export async function addDeckPhoto(eventId: string, participantId: string, jpeg: Blob, note: string): Promise<DeckPhotos> {
  const id = crypto.randomUUID().toLowerCase();
  const up = await supabase.storage.from("deck-photos")
    .upload(`${eventId}/${id}.jpg`, jpeg, { contentType: "image/jpeg", upsert: true });
  if (up.error) throw up.error;
  const { data, error } = await supabase.rpc("deck_photo_add", {
    p_id: id, p_event_id: eventId, p_participant_id: participantId, p_note: note,
  });
  if (error) throw error;
  return toPhotos(data);
}

export async function setDeckPhotoNote(id: string, note: string): Promise<DeckPhotos> {
  const { data, error } = await supabase.rpc("deck_photo_note", { p_id: id, p_note: note });
  if (error) throw error;
  return toPhotos(data);
}

/** Turns an uploaded photo upright: the row keeps the quarter turns, the file never changes. */
export async function turnDeckPhotoSaved(id: string, turns: number): Promise<DeckPhotos> {
  const { data, error } = await supabase.rpc("deck_photo_turn", { p_id: id, p_turns: turns });
  if (error) throw error;
  return toPhotos(data);
}

export async function deleteDeckPhoto(photo: DeckPhoto): Promise<DeckPhotos> {
  const { data, error } = await supabase.rpc("deck_photo_delete", { p_id: photo.id });
  if (error) throw error;
  // The file: only its uploader may remove it (storage policy); otherwise it stays, unreadable without its row.
  await supabase.storage.from("deck-photos").remove([photo.path]).catch(() => undefined);
  return toPhotos(data);
}

/** Signed links for photos (private bucket), valid an hour. */
export async function deckPhotoUrls(paths: string[]): Promise<Record<string, string>> {
  if (paths.length === 0) return {};
  const { data } = await supabase.storage.from("deck-photos").createSignedUrls(paths, 3600);
  const out: Record<string, string> = {};
  for (const r of data ?? []) if (r.path && r.signedUrl) out[r.path] = r.signedUrl;
  return out;
}

/** Longest side 2048 px, never upscaled (same as the apps). */
export function deckPhotoSize(width: number, height: number, longest = 2048): { width: number; height: number } {
  const scale = Math.min(1, longest / Math.max(width, height, 1));
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

/** Quarter turns clockwise, 0–3, after turning `by` more (−1 Rotate left, +1 Rotate right). */
export function turnDeckPhoto(turns: number, by: number): number {
  return (((turns + by) % 4) + 4) % 4;
}

/** The drawn size after `turns` quarter turns: odd turns swap the sides. */
export function turnedSize(width: number, height: number, turns: number): { width: number; height: number } {
  return turns % 2 === 0 ? { width, height } : { width: height, height: width };
}

/** The picked file, upright (createImageBitmap applies the photo's own orientation). Close it when done. */
export async function readDeckPhoto(file: File): Promise<ImageBitmap> {
  const bitmap = await createImageBitmap(file).catch(() => null);
  if (!bitmap || bitmap.width <= 0 || bitmap.height <= 0) throw new Error("Couldn't read that photo.");
  return bitmap;
}

/** Draws the photo into `canvas` turned `turns` quarter turns clockwise, longest side at most `longest`. */
export function drawDeckPhoto(canvas: HTMLCanvasElement, bitmap: ImageBitmap, turns: number, longest = 2048): boolean {
  const size = deckPhotoSize(bitmap.width, bitmap.height, longest);
  const out = turnedSize(size.width, size.height, turns);
  canvas.width = out.width;
  canvas.height = out.height;
  const ctx = canvas.getContext("2d");
  if (!ctx) return false;
  ctx.translate(out.width / 2, out.height / 2);
  ctx.rotate((turns * Math.PI) / 2);
  ctx.drawImage(bitmap, -size.width / 2, -size.height / 2, size.width, size.height);
  return true;
}

/** The photo as a JPEG at quality 0.8, at most 2048 px on the long side, turned as the player set it. */
export async function deckJpeg(bitmap: ImageBitmap, turns = 0): Promise<Blob> {
  const canvas = document.createElement("canvas");
  if (!drawDeckPhoto(canvas, bitmap, turns)) throw new Error("Couldn't read that photo.");
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.8));
  if (!blob) throw new Error("Couldn't read that photo.");
  return blob;
}

/* Your deck photos on your account (§ 7 On your account, 2026-11-06): every photo of a deck you played, across
   events, newest event first (`my_deck_photos`). Same rules as iOS MyDeckPhotoRules and Android MyDeckPhotoRules,
   testdata/deck-photos/cases.json `summary` and `groups`. */

export interface MyDeckPhoto extends DeckPhoto {
  eventId: string;
  eventName: string;
  eventStatus: string;
  formatLabel: string;
  eventAt: string;
}

export interface MyDeckPhotos {
  total: number;
  events: number;
  photos: MyDeckPhoto[];
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function toMyPhotos(raw: any): MyDeckPhotos {
  const base = toPhotos(raw).photos;
  return {
    total: Number(raw?.total ?? 0) || 0,
    events: Number(raw?.events ?? 0) || 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    photos: (raw?.photos ?? []).map((p: any, i: number) => ({
      ...base[i],
      eventId: p.event_id ?? "", eventName: p.event_name ?? "", eventStatus: p.event_status ?? "",
      formatLabel: p.format_label ?? "", eventAt: p.event_at ?? "",
    })),
  };
}

export async function loadMyDeckPhotos(limit = 200): Promise<MyDeckPhotos> {
  const { data, error } = await supabase.rpc("my_deck_photos", { p_limit: limit });
  if (error) throw error;
  return toMyPhotos(data);
}

/** The Account row: "12 photos · 5 events", or "None yet". */
export function myDeckPhotoSummary(total: number, events: number): string {
  if (total === 0) return "None yet";
  return `${total} photo${total === 1 ? "" : "s"} · ${events} event${events === 1 ? "" : "s"}`;
}

/** The server's order kept; consecutive photos of one event under one heading (its name, "Event" when blank). */
export function myDeckPhotoGroups<T extends { eventId: string; eventName: string }>(photos: T[]): { eventId: string; title: string; photos: T[] }[] {
  const out: { eventId: string; title: string; photos: T[] }[] = [];
  for (const p of photos) {
    const last = out[out.length - 1];
    if (last && last.eventId === p.eventId) last.photos.push(p);
    else out.push({ eventId: p.eventId, title: p.eventName.trim() || "Event", photos: [p] });
  }
  return out;
}

/** "29 Nov 2026 · Draft": the event's local date, then its format unless the name already says it. */
export function myDeckPhotoDetail(p: { eventAt: string; formatLabel: string; eventName: string }): string {
  const parts: string[] = [];
  const at = p.eventAt ? new Date(p.eventAt) : null;
  if (at && !Number.isNaN(at.getTime())) {
    parts.push(at.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" }));
  }
  if (p.formatLabel && !p.eventName.toLowerCase().includes(p.formatLabel.toLowerCase())) parts.push(p.formatLabel);
  return parts.join(" · ");
}

/* Once a player's last match is in (or the event is over, or they dropped), the player screen leads with Add a deck
   photo (contract/event-night-2026-10-16.md § 7 "Once your last match is in"). Same rule as iOS DeckPhotoPrompt and
   Android DeckPhotoPrompt, checked against testdata/deck-photos/prompt.json. */

export type DeckPhotoWhy = "last" | "over" | "dropped";
export interface PromptMine { bye: boolean; status: string; my: number; their: number }
export interface PromptRound { number: number; stage?: string | null; mine: PromptMine | null }

/** Why the player is finished playing, or null. */
export function deckPhotoDone(
  event: { status: string; rounds: number; topCut: number },
  me: { status: string; droppedInRound: number | null } | null,
  rounds: PromptRound[],
): DeckPhotoWhy | null {
  if (!me || event.status === "cancelled") return null;
  if (event.status === "completed" || event.status === "archived") return "over";
  if (me.status === "dropped" || me.droppedInRound != null) return "dropped";
  let last: PromptRound | null = null;
  for (const r of rounds) if (r.mine && (!last || r.number > last.number)) last = r;
  const m = last?.mine;
  if (!last || !m || !(m.bye || m.status === "reported" || m.status === "confirmed")) return null;
  const stage = last.stage ?? "swiss";
  if (stage !== "swiss") return stage === "final" || m.my < m.their ? "last" : null;
  if (last.number < event.rounds) return null;
  if (event.topCut === 0) return "last";
  return rounds.some((r) => (r.stage ?? "swiss") !== "swiss") ? "last" : null;
}

/** The bundle's rounds as the rule reads them: your match in each, your side's game wins as `my`. */
export function promptRounds(
  rounds: { number: number; stage?: string | null; matches: { isBye: boolean; status: string; sides: { participantId: string | null; gameWins: number }[] }[] }[],
  participantId: string,
): PromptRound[] {
  return rounds.map((r) => {
    const m = r.matches.find((x) => x.sides.some((s) => s.participantId === participantId));
    return {
      number: r.number,
      stage: r.stage ?? null,
      mine: m ? {
        bye: m.isBye, status: m.status,
        my: m.sides.find((s) => s.participantId === participantId)?.gameWins ?? 0,
        their: m.sides.find((s) => s.participantId !== participantId)?.gameWins ?? 0,
      } : null,
    };
  });
}

/** "add" before you have a photo of your deck in the event, "added" once you do. */
export function deckPhotoPrompt(why: DeckPhotoWhy | null, photos: number): "add" | "added" | null {
  return why ? (photos > 0 ? "added" : "add") : null;
}

export function deckPhotoWhyLabel(why: DeckPhotoWhy): string {
  return why === "over" ? "Event over" : why === "dropped" ? "Dropped" : "Last match in";
}
