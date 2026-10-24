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
      createdAt: p.created_at, mine: !!p.mine, editable: !!p.editable,
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

/** The picked file as a JPEG at quality 0.8, upright (createImageBitmap applies the photo's orientation). */
export async function deckJpeg(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  if (bitmap.width <= 0 || bitmap.height <= 0) throw new Error("Couldn't read that photo.");
  const size = deckPhotoSize(bitmap.width, bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = size.width;
  canvas.height = size.height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Couldn't read that photo.");
  ctx.drawImage(bitmap, 0, 0, size.width, size.height);
  bitmap.close();
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.8));
  if (!blob) throw new Error("Couldn't read that photo.");
  return blob;
}
