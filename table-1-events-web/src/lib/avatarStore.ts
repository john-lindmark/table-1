import { useEffect, useSyncExternalStore } from "react";
import { supabase } from "./supabaseClient";

/**
 * Which accounts have photos, read from `profiles` in batches for the ids on screen and kept for the session
 * (contract/avatars-2026-10-16.md). user id → bucket path; null means "no photo" (asked already).
 */
const paths = new Map<string, string | null>();
const pending = new Set<string>();
const listeners = new Set<() => void>();
let flushing = false;
let version = 0;

function changed() {
  version++;
  listeners.forEach((l) => l());
}

function want(userId: string) {
  if (paths.has(userId) || pending.has(userId)) return;
  pending.add(userId);
  if (flushing) return;
  flushing = true;
  // Let the rest of the list ask first, then one query.
  setTimeout(() => void flush(), 30);
}

async function flush() {
  try {
    while (pending.size > 0) {
      const ids = [...pending].slice(0, 100);
      // people() returns only accounts you have a reason to see (contract/privacy-lockdown-2026-10-18.md); anyone
      // else, across a block, or every id when signed out, comes back missing and draws initials.
      const { data, error } = await supabase.rpc("people", { p_ids: ids });
      ids.forEach((id) => pending.delete(id));
      // Offline: ask again next time it's drawn. Refused (signed out): initials, without asking on every draw.
      if (error && error.code !== "42501") continue;
      ids.forEach((id) => paths.set(id, null));
      for (const r of (data ?? []) as { user_id: string; avatar_url: string | null }[]) paths.set(r.user_id, r.avatar_url);
      changed();
    }
  } finally {
    flushing = false;
  }
}

export function avatarUrl(path: string): string {
  return `${import.meta.env.VITE_SUPABASE_URL}/storage/v1/object/public/avatars/${path}`;
}

/** Your own change, shown at once. */
export function setAvatarPath(userId: string, path: string | null) {
  paths.set(userId, path);
  changed();
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}

/** The account's photo path (null while unknown or when there's none); asks the server once per session. */
export function useAvatarPath(userId: string | null | undefined): string | null {
  useEffect(() => {
    if (userId) want(userId);
  }, [userId]);
  useSyncExternalStore(subscribe, () => version);
  return userId ? paths.get(userId) ?? null : null;
}

/** Centre square, 512 px, JPEG 0.8: well under the bucket's 1 MB limit. */
export async function avatarJpeg(file: File): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const side = Math.min(bitmap.width, bitmap.height);
  if (side <= 0) throw new Error("Couldn't read that photo.");
  const out = Math.min(512, side);
  const canvas = document.createElement("canvas");
  canvas.width = out;
  canvas.height = out;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Couldn't read that photo.");
  ctx.drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, out, out);
  bitmap.close();
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.8));
  if (!blob) throw new Error("Couldn't read that photo.");
  return blob;
}

type AvatarResult = { avatar_url: string | null; previous: string | null };

/** Uploads to <user_id>/<random>.jpg, points the profile at it, then removes the old file. */
export async function setAvatar(userId: string, jpeg: Blob) {
  const uid = userId.toLowerCase();
  const path = `${uid}/${crypto.randomUUID().toLowerCase()}.jpg`;
  const bucket = supabase.storage.from("avatars");
  const up = await bucket.upload(path, jpeg, { contentType: "image/jpeg", upsert: true });
  if (up.error) throw up.error;
  const { data, error } = await supabase.rpc("avatar_set", { p_path: path });
  if (error) throw error;
  setAvatarPath(uid, path);
  const old = (data as AvatarResult | null)?.previous;
  if (old && old !== path) await bucket.remove([old]).catch(() => undefined);
}

export async function clearAvatar(userId: string) {
  const uid = userId.toLowerCase();
  const { data, error } = await supabase.rpc("avatar_clear");
  if (error) throw error;
  setAvatarPath(uid, null);
  const old = (data as AvatarResult | null)?.previous;
  if (old) await supabase.storage.from("avatars").remove([old]).catch(() => undefined);
}
