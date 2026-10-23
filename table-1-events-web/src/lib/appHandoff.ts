/**
 * Get the app, after joining on the web (contract/qr-sign-up-2026-10-23.md § Get the app). The event rides along on the
 * account: signed in the same way, the app already lists it. Android's store link also carries it through the install
 * (Play's `referrer`, read once by the app on first launch).
 */
export type Phone = "ios" | "android";

/** The phone a user agent names; null on a computer. */
export function phonePlatform(ua: string): Phone | null {
  if (/iPhone|iPad|iPod/.test(ua)) return "ios";
  if (/Android/.test(ua)) return "android";
  return null;
}

/** The store link for that phone, or null when none is set (the panel stays hidden). */
export function storeLink(phone: Phone, base: string | undefined, eventId: string): string | null {
  if (!base) return null;
  if (phone === "ios") return base;
  const referrer = encodeURIComponent(`t1=${encodeURIComponent(`/p/${eventId}`)}`);
  return `${base}${base.includes("?") ? "&" : "?"}referrer=${referrer}`;
}

/** Which sign-in to use in the app, from the account's provider. */
export function signInHint(provider: string | null | undefined, email: string | null | undefined): string | null {
  if (provider === "apple") return "Continue with Apple";
  if (provider === "google") return "Continue with Google";
  if (provider === "email") return email ? `Continue with email: ${email}` : "Continue with email";
  return null;
}
