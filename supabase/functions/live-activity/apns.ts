// Minimal APNs client for Live Activity pushes (token auth, HTTP/2 via fetch).
import { importPKCS8, SignJWT } from "npm:jose@5";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "site.table1.events";
export const TOPIC = `${BUNDLE_ID}.push-type.liveactivity`;

let cached: { jwt: string; at: number } | null = null;

/** Provider token; Apple wants it reused for 20–60 minutes, not minted per request. */
async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.at < 45 * 60) return cached.jwt;
  const teamId = Deno.env.get("APNS_TEAM_ID") ?? Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APNS_KEY_ID");
  const pem = Deno.env.get("APNS_PRIVATE_KEY")?.replace(/\\n/g, "\n");
  if (!teamId || !keyId || !pem) throw new Error("APNS_TEAM_ID, APNS_KEY_ID and APNS_PRIVATE_KEY must be set");
  const key = await importPKCS8(pem, "ES256");
  const jwt = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: keyId }).setIssuer(teamId).setIssuedAt(now).sign(key);
  cached = { jwt, at: now };
  return jwt;
}

export function apnsConfigured(): boolean {
  return !!(Deno.env.get("APNS_KEY_ID") && Deno.env.get("APNS_PRIVATE_KEY"));
}

export interface Push { token: string; env: "development" | "production"; priority: 5 | 10; payload: unknown }
export interface PushResult { token: string; status: number; reason?: string }

export async function send(push: Push): Promise<PushResult> {
  const host = push.env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const res = await fetch(`https://${host}/3/device/${push.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken()}`,
      "apns-topic": TOPIC,
      "apns-push-type": "liveactivity",
      "apns-priority": String(push.priority),
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
      "content-type": "application/json",
    },
    body: JSON.stringify(push.payload),
  });
  let reason: string | undefined;
  if (res.status !== 200) reason = (await res.json().catch(() => ({})))?.reason;
  else await res.body?.cancel();
  return { token: push.token, status: res.status, reason };
}

/** Sends with bounded concurrency so a 500-player round start stays smooth. */
export async function sendAll(pushes: Push[], concurrency = 32): Promise<PushResult[]> {
  const results: PushResult[] = [];
  let i = 0;
  const worker = async () => {
    while (i < pushes.length) {
      const p = pushes[i++];
      try { results.push(await send(p)); } catch (e) { results.push({ token: p.token, status: 0, reason: String(e) }); }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, pushes.length) }, worker));
  return results;
}
