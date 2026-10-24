/* Google sign-in on the web (contract/web-google-sign-in-2026-10-23.md). Our own button sends the browser straight
   to Google, which returns an ID token to table-1.site/auth/google; Supabase gets the token, as the apps do. Through
   Supabase's OAuth hop Google showed "to continue to aaozhfcbvqrgkkrihkrd.supabase.co" instead of Table 1. */

/** The web OAuth client (Google Cloud), the one Supabase Auth > Google lists first. Empty = Supabase's OAuth hop. */
export const GOOGLE_WEB_CLIENT_ID: string = import.meta.env.VITE_GOOGLE_WEB_CLIENT_ID ?? "";

export const GOOGLE_RETURN_PATH = "/auth/google";

/** The request in flight, kept for the tab that comes back: Supabase checks the raw nonce, we check the state. */
export interface GoogleRequest {
  nonce: string;
  state: string;
  returnTo: string;
}

export const GOOGLE_REQUEST_KEY = "t1.signin.google";

export function randomString(bytes = 32): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/** Hex SHA-256: Google puts this in the token's nonce claim, Supabase hashes the raw value to compare. */
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest), (x) => x.toString(16).padStart(2, "0")).join("");
}

export function googleAuthUrl(p: { clientId: string; origin: string; state: string; hashedNonce: string }): string {
  const q = new URLSearchParams({
    client_id: p.clientId,
    redirect_uri: p.origin + GOOGLE_RETURN_PATH,
    response_type: "id_token",
    scope: "openid email profile",
    nonce: p.hashedNonce,
    state: p.state,
    prompt: "select_account",
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${q}`;
}

export type GoogleReturn =
  | { kind: "token"; idToken: string; returnTo: string; nonce: string }
  | { kind: "cancelled"; returnTo: string }
  | { kind: "error"; message: string; returnTo: string };

/** Same-origin paths only. */
export function safeReturn(to: string | undefined): string {
  return to && to.startsWith("/") && !to.startsWith("//") ? to : "/";
}

/** What Google put in the fragment, checked against the request this tab sent. */
export function readGoogleReturn(hash: string, request: GoogleRequest | null): GoogleReturn {
  const q = new URLSearchParams(hash.replace(/^#/, ""));
  const returnTo = safeReturn(request?.returnTo);
  if (!request || q.get("state") !== request.state) {
    return { kind: "error", message: "This sign-in didn't start here. Try again.", returnTo };
  }
  const error = q.get("error");
  if (error === "access_denied") return { kind: "cancelled", returnTo };
  const idToken = q.get("id_token");
  if (error || !idToken) return { kind: "error", message: "Google didn't sign you in. Try again.", returnTo };
  return { kind: "token", idToken, returnTo, nonce: request.nonce };
}
