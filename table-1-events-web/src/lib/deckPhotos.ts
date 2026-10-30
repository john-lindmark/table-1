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
