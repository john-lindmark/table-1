// Minimal APNs client for alert pushes (token auth, HTTP/2 via fetch). Same key as live-activity/apns.ts.
import { importPKCS8, SignJWT } from "npm:jose@5";

const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "site.table1.events";

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

export interface Alert {
  token: string;
  env: "development" | "production";
  priority: 5 | 10;
  collapseId?: string;
  payload: unknown;
}
export interface AlertResult { token: string; status: number; reason?: string }

export async function send(a: Alert): Promise<AlertResult> {
  const host = a.env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken()}`,
    "apns-topic": BUNDLE_ID,
    "apns-push-type": "alert",
    "apns-priority": String(a.priority),
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
    "content-type": "application/json",
  };
  if (a.collapseId) headers["apns-collapse-id"] = a.collapseId;
  const res = await fetch(`https://${host}/3/device/${a.token}`, { method: "POST", headers, body: JSON.stringify(a.payload) });
  let reason: string | undefined;
  if (res.status !== 200) reason = (await res.json().catch(() => ({})))?.reason;
  else await res.body?.cancel();
  return { token: a.token, status: res.status, reason };
}

export async function sendAll(alerts: Alert[], concurrency = 32): Promise<AlertResult[]> {
  const results: AlertResult[] = [];
  let i = 0;
  const worker = async () => {
    while (i < alerts.length) {
      const a = alerts[i++];
      try { results.push(await send(a)); } catch (e) { results.push({ token: a.token, status: 0, reason: String(e) }); }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, alerts.length) }, worker));
  return results;
}
