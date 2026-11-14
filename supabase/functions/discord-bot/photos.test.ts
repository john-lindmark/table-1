import { assert, assertEquals } from "jsr:@std/assert@1";
import { batches, MAX_PHOTOS, photoEmbed, photosHeader, pickPhotos, uprightJpeg } from "./photos.ts";
import type { ResultRow } from "./standings.ts";

const row = (id: string, rank: number, name: string, extra: Partial<ResultRow> = {}): ResultRow =>
  ({ participantId: id, rank, name, wins: 3 - rank, losses: rank - 1, draws: 0, points: 3 * (3 - rank), dropped: false, ...extra });
const photo = (id: string, at: string, note: string | null = null, turns = 0) =>
  ({ participant_id: id, path: `e/${id}/${at}.jpg`, note, turns, created_at: at });

Deno.test("deck photos: standings order, each player's photos oldest first, players without a place last", () => {
  const rows = [row("a", 1, "Bea"), row("b", 2, "Ann"), row("c", 3, "Cal")];
  const picks = pickPhotos([photo("c", "2"), photo("x", "1"), photo("a", "3"), photo("a", "1"), photo("b", "5")], rows);
  assertEquals(picks.map((p) => `${p.photo.participant_id}${p.photo.created_at}`), ["a1", "a3", "b5", "c2", "x1"]);
  assertEquals(picks.at(-1)!.row, null);
  // players with no photo aren't posted
  assertEquals(pickPhotos([], rows), []);
  const many = Array.from({ length: 60 }, (_, i) => photo("a", String(i).padStart(2, "0")));
  assertEquals(pickPhotos(many, rows).length, MAX_PHOTOS);
});

Deno.test("deck photos: ≤ 10 files and ≤ the byte budget a message", () => {
  const items = (sizes: number[]) => sizes.map((size) => ({ size }));
  assertEquals(batches(items(Array(23).fill(1))).map((b) => b.length), [10, 10, 3]);
  assertEquals(batches(items([6, 6, 6, 6]), 10, 12).map((b) => b.length), [2, 2]);
  assertEquals(batches(items([30, 1]), 10, 12).map((b) => b.length), [1, 1]); // a big file still goes, alone
  assertEquals(batches([]), []);
});

Deno.test("deck photos: the embed names the player, place, pod and record, the note under it, the file as the picture", () => {
  const e = photoEmbed({ photo: photo("a", "1", "  Mono *red*  "), row: row("a", 1, "Bea", { pod: "P2" }) }, "deck-photo-1.jpg", null);
  assertEquals(e.title, "1. Bea · P2 · 2-0");
  assertEquals(e.description, "Mono \\*red\\*");
  assertEquals(e.image.url, "attachment://deck-photo-1.jpg");
  const bare = photoEmbed({ photo: photo("x", "1"), row: null }, "deck-photo-2.jpg", "Gus");
  assertEquals(bare.title, "Gus");
  assert(!("description" in bare));
  assertEquals(photosHeader("Friday Draft", 3, 3), "**Deck photos** · Friday Draft · 3 players");
  assertEquals(photosHeader("Friday Draft", 4, 3), "**Deck photos** · Friday Draft · 3 players, 4 photos");
});

// A minimal JPEG's segments: SOI, an APP0, an Exif APP1 (would carry the phone's data), a DQT, then SOS + data.
const seg = (marker: number, body: number[]) => [0xff, marker, (body.length + 2) >> 8, (body.length + 2) & 0xff, ...body];
const jpeg = (exif: boolean) => new Uint8Array([
  0xff, 0xd8,
  ...seg(0xe0, [0x4a, 0x46, 0x49, 0x46, 0x00, 1, 1]),
  ...(exif ? seg(0xe1, [0x45, 0x78, 0x69, 0x66, 0, 0, 9, 9, 9, 9]) : []),
  ...seg(0xdb, [0, 1, 2, 3]),
  0xff, 0xda, 0, 4, 7, 7, 0x11, 0x22, 0xff, 0xd9,
]);
const hasExif = (b: Uint8Array) => b.some((v, i) => v === 0x45 && b[i + 1] === 0x78 && b[i + 2] === 0x69 && b[i + 3] === 0x66);

Deno.test("deck photos: Exif dropped; quarter turns become an orientation so the photo shows upright", () => {
  const plain = uprightJpeg(jpeg(true), 0);
  assertEquals([...plain], [...jpeg(false)]);
  assert(!hasExif(plain));
  for (const [turns, o] of [[1, 6], [2, 3], [3, 8], [5, 6], [-1, 8]] as const) {
    const out = uprightJpeg(jpeg(true), turns);
    assertEquals([...out.subarray(0, 4)], [0xff, 0xd8, 0xff, 0xe1]);
    assertEquals(out[2 + 29], o); // SOI, then the orientation SHORT's low byte
    assertEquals(out.length, jpeg(false).length + 36);
    assertEquals([...out.subarray(out.length - 10)], [...jpeg(false).subarray(jpeg(false).length - 10)]);
  }
  // not a JPEG we can read: as it is
  assertEquals([...uprightJpeg(new Uint8Array([1, 2, 3]), 1)], [1, 2, 3]);
  const cut = jpeg(true).subarray(0, 12);
  assertEquals([...uprightJpeg(cut, 1)], [...cut]);
});
