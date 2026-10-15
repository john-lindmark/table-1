// delete-account: in-app account deletion (App Store guideline 5.1.1(v)).
//   POST { apple_authorization_code?: string }   Authorization: Bearer <user JWT>
// 1. Scrubs the profile via the delete_account() RPC (match history stays as "Deleted player").
// 2. If an Apple authorization code is sent (iOS re-confirms with Sign in with Apple), exchanges it
//    and revokes the token with Apple, as Apple requires for apps that offer Sign in with Apple.
// 3. Deletes the auth identity.
// Secrets (Edge Functions → Secrets): APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY (.p8 contents),
// APPLE_BUNDLE_ID (default site.table1.events). Without them, deletion still works; revocation is skipped.
import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

/** Apple's client secret: an ES256 JWT signed with the .p8 key, valid for 5 minutes. */
async function appleClientSecret(clientId: string): Promise<string | null> {
  const teamId = Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APPLE_KEY_ID");
  const pem = Deno.env.get("APPLE_PRIVATE_KEY")?.replace(/\\n/g, "\n");
  if (!teamId || !keyId || !pem) return null;
  const key = await importPKCS8(pem, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .setExpirationTime("5m")
    .setAudience("https://appleid.apple.com")
    .setSubject(clientId)
    .sign(key);
}

/** Exchange the fresh authorization code for a refresh token, then revoke it. */
async function revokeApple(code: string): Promise<{ revoked: boolean; reason?: string }> {
  const clientId = Deno.env.get("APPLE_BUNDLE_ID") ?? "site.table1.events";
  const secret = await appleClientSecret(clientId);
  if (!secret) return { revoked: false, reason: "Apple signing key secrets are not set" };

  const tokenRes = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: clientId, client_secret: secret, code, grant_type: "authorization_code" }),
  });
  const tokens = await tokenRes.json().catch(() => ({}));
  const token = tokens.refresh_token ?? tokens.access_token;
  if (!tokenRes.ok || !token) return { revoked: false, reason: `token exchange failed: ${tokens.error ?? tokenRes.status}` };

  const revokeRes = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: secret,
      token,
      token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
    }),
  });
  return revokeRes.ok ? { revoked: true } : { revoked: false, reason: `revoke failed: ${revokeRes.status}` };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Sign in required" }, 401);

  try {
    // Who is asking? Resolved from their own token, never from the request body.
    const asCaller = createClient(url, anonKey, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    });
    const { data: userData, error: userError } = await asCaller.auth.getUser(auth.slice(7));
    if (userError || !userData.user) return json({ error: "Sign in required" }, 401);
    const user = userData.user;

    const body = await req.json().catch(() => ({}));
    const code = typeof body.apple_authorization_code === "string" ? body.apple_authorization_code : null;

    // Apple first: if revocation is required and fails, nothing has been deleted yet.
    let apple: { revoked: boolean; reason?: string } = { revoked: false, reason: "not an Apple sign-in" };
    if (code) apple = await revokeApple(code);

    const { error: scrubError } = await asCaller.rpc("delete_account");
    if (scrubError) throw scrubError;

    // Live Activity / widget push tokens go with the account.
    await admin.from("live_activity_tokens").delete().eq("user_id", user.id);

    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) throw deleteError;

    console.log(JSON.stringify({ event: "account.deleted", user: user.id, apple }));
    return json({ ok: true, apple_revoked: apple.revoked, apple_note: apple.reason ?? null });
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
