// Deck photos under a final /event results post (contract/discord-2026-10-29.md § Results "Deck photos"): every
// player's deck photo, in standings order, as files on follow-up messages (Discord hosts them; the photos stay in
// Table 1's private bucket). Only once the event is over, when the apps share them with everyone in the event.
import { ACCENT, clean } from "./embeds.ts";
import type { ResultRow } from "./standings.ts";

export interface PhotoRow {
  participant_id: string;
  path: string;
  note: string | null;
  turns: number | null;
  created_at: string;
}

/** Discord: at most 10 files and embeds a message, 25 MiB of files a message (kept well under). */
export const PER_MESSAGE = 10;
export const MAX_MESSAGE_BYTES = 20 * 1024 * 1024;
/** A post never carries more than this many photos (4 messages). */
export const MAX_PHOTOS = 40;

export interface PhotoPick {
  photo: PhotoRow;
  row: ResultRow | null;
}

/** The photos to post: players in standings order (best first), each player's photos oldest first, players no longer
 *  in the standings last; at most MAX_PHOTOS. */
export function pickPhotos(photos: PhotoRow[], rows: ResultRow[]): PhotoPick[] {
  const place = new Map(rows.map((r, i) => [r.participantId, i]));
  const rowOf = new Map(rows.map((r) => [r.participantId, r]));
  return [...photos]
    .sort((a, b) =>
      (place.get(a.participant_id) ?? 1e9) - (place.get(b.participant_id) ?? 1e9) ||
      a.participant_id.localeCompare(b.participant_id) || a.created_at.localeCompare(b.created_at))
    .slice(0, MAX_PHOTOS)
    .map((photo) => ({ photo, row: rowOf.get(photo.participant_id) ?? null }));
}

/** Files into messages: ≤ PER_MESSAGE each and ≤ MAX_MESSAGE_BYTES (a single larger file still gets its own). */
export function batches<T extends { size: number }>(items: T[], perMessage = PER_MESSAGE, maxBytes = MAX_MESSAGE_BYTES): T[][] {
  const out: T[][] = [];
  let cur: T[] = [];
  let bytes = 0;
  for (const it of items) {
    if (cur.length && (cur.length >= perMessage || bytes + it.size > maxBytes)) {
      out.push(cur);
      cur = [];
      bytes = 0;
    }
    cur.push(it);
    bytes += it.size;
  }
  if (cur.length) out.push(cur);
  return out;
}

const record = (w: number, l: number, d: number) => `${w}-${l}${d ? `-${d}` : ""}`;

/** One photo's embed: the player with their place and record, the note under it, the file as the picture. */
export function photoEmbed(p: PhotoPick, file: string, name: string | null) {
  const r = p.row;
  const who = clean(r?.name ?? name ?? "Player");
  const title = r ? `${r.rank}. ${who}${r.pod ? ` · ${r.pod}` : ""} · ${record(r.wins, r.losses, r.draws)}` : who;
  const note = p.photo.note?.trim();
  return {
    title: title.slice(0, 256),
    ...(note ? { description: clean(note).slice(0, 500) } : {}),
    color: ACCENT,
    image: { url: `attachment://${file}` },
  };
}

export const photoFile = (i: number) => `deck-photo-${i + 1}.jpg`;

/** The first message's line above the photos. */
export function photosHeader(eventName: string, photos: number, players: number): string {
  return `**Deck photos** · ${clean(eventName)} · ${players} player${players === 1 ? "" : "s"}${photos > players ? `, ${photos} photos` : ""}`.slice(0, 2000);
}

/** The JPEG as the apps draw it: any Exif segment dropped (nothing about the phone leaves Table 1) and, for a photo
 *  saved with quarter turns, an Exif orientation in its place (turns 1/2/3 clockwise → orientation 6/3/8), so it shows
 *  upright without decoding a pixel. Not a JPEG Table 1 can read: handed back as it is. */
export function uprightJpeg(bytes: Uint8Array, turns: number | null): Uint8Array<ArrayBuffer> {
  const copy = () => new Uint8Array(bytes) as Uint8Array<ArrayBuffer>;
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return copy();
  const keep: Uint8Array[] = [];
  let i = 2;
  for (;;) {
    if (i + 4 > bytes.length || bytes[i] !== 0xff) return copy();
    const marker = bytes[i + 1];
    if (marker === 0xda) break; // start of scan: the rest is image data
    const len = (bytes[i + 2] << 8) | bytes[i + 3];
    if (len < 2 || i + 2 + len > bytes.length) return copy();
    const seg = bytes.subarray(i, i + 2 + len);
    const exif = marker === 0xe1 && len >= 8 && seg[4] === 0x45 && seg[5] === 0x78 && seg[6] === 0x69 && seg[7] === 0x66 && seg[8] === 0 && seg[9] === 0;
    if (!exif) keep.push(seg);
    i += 2 + len;
  }
  const orientation = [1, 6, 3, 8][(((turns ?? 0) % 4) + 4) % 4];
  const app1 = orientation === 1 ? null : exifOrientation(orientation);
  const rest = bytes.subarray(i);
  const parts: Uint8Array[] = [bytes.subarray(0, 2), ...(app1 ? [app1] : []), ...keep, rest];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** An APP1 segment holding only Exif IFD0 Orientation (big-endian TIFF). */
function exifOrientation(value: number): Uint8Array {
  return new Uint8Array([
    0xff, 0xe1, 0x00, 0x22, // APP1, length 34
    0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
    0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, // "MM", 42, IFD0 at 8
    0x00, 0x01, // one entry
    0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, value, 0x00, 0x00, // Orientation, SHORT, 1, value
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ]);
}
