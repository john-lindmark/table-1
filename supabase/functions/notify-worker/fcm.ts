// Minimal FCM client for Android alert pushes (HTTP v1 API). Credentials: the Firebase project's service account
// JSON in the FCM_SERVICE_ACCOUNT secret (client_email, private_key, project_id), traded for an OAuth token.
import { importPKCS8, SignJWT } from "npm:jose@5";

interface ServiceAccount { client_email: string; private_key: string; project_id: string }

let account: ServiceAccount | null | undefined;
function serviceAccount(): ServiceAccount | null {
  if (account !== undefined) return account;
  try {
    const a = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "");
    account = a?.client_email && a?.private_key && a?.project_id ? a : null;
  } catch {
    account = null;
  }
  return account ?? null;
}

export function fcmConfigured(): boolean {
  return serviceAccount() !== null;
}

let cached: { token: string; until: number } | null = null;

/** OAuth access token for the messaging scope; Google's last an hour, reused for 50 minutes. */
async function accessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now < cached.until) return cached.token;
  const a = serviceAccount();
  if (!a) throw new Error("FCM_SERVICE_ACCOUNT must be set");
  const key = await importPKCS8(a.private_key.replace(/\\n/g, "\n"), "RS256");
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(a.client_email).setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now).setExpirationTime(now + 3600).sign(key);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) throw new Error(`FCM token ${res.status}: ${body.error_description ?? body.error ?? ""}`);
  cached = { token: body.access_token, until: now + 50 * 60 };
  return body.access_token;
}

export interface AndroidAlert {
  token: string;
  title: string;
  body: string;
  priority: 5 | 10;
  /** A newer alert with the same tag replaces the older one in the shade, like apns-collapse-id. */
  tag: string;
  /** Groups alerts in the shade, like APNs' thread-id. */
  group: string;
  /** The keys the app routes a tap by (kind, event_id, ...); nulls are left out. */
  info: Record<string, unknown>;
}

/**
 * The v1 message. Data only: the app draws the notification itself (its channel, group and the screen a tap opens),
 * the same whether it's in the foreground or not. FCM data values must be strings.
 */
export function fcmMessage(a: AndroidAlert) {
  const data: Record<string, string> = {};
  for (const [k, v] of Object.entries(a.info)) if (v !== null && v !== undefined && v !== "") data[k] = String(v);
  Object.assign(data, { title: a.title, body: a.body, tag: a.tag, group: a.group });
  return {
    message: {
      token: a.token,
      data,
      android: { priority: a.priority === 10 ? "HIGH" : "NORMAL", ttl: "3600s" },
    },
  };
}

export interface FcmResult { token: string; status: number; reason?: string }

/** The token no longer reaches an app (uninstalled, or from another Firebase project): forget it. */
export function deadToken(r: FcmResult): boolean {
  return r.status === 404 || r.reason === "UNREGISTERED" || r.reason === "SENDER_ID_MISMATCH";
}

export async function send(a: AndroidAlert): Promise<FcmResult> {
  const project = serviceAccount()!.project_id;
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${project}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${await accessToken()}`, "content-type": "application/json" },
    body: JSON.stringify(fcmMessage(a)),
  });
  let reason: string | undefined;
  if (res.status !== 200) {
    const err = (await res.json().catch(() => ({})))?.error;
    // The FCM error code sits in details (UNREGISTERED, SENDER_ID_MISMATCH, ...); the status is the generic one.
    const detail = (err?.details ?? []).find((d: { errorCode?: string }) => d?.errorCode)?.errorCode;
    reason = detail ?? err?.status;
  } else await res.body?.cancel();
  return { token: a.token, status: res.status, reason };
}

export async function sendAll(alerts: AndroidAlert[], concurrency = 32): Promise<FcmResult[]> {
  const results: FcmResult[] = [];
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
