// discord-community: is the signed-in account in the Table 1 Discord server? (contract/discord-2026-10-29.md §7)
//   POST {}   Authorization: Bearer <user JWT>   → { linked, member }
// The caller's Discord id comes from their own token (discord_my_id), never the body; the bot token asks Discord's
// Get Guild Member, which needs no privileged intent. Nothing is stored or logged about the answer.
// Secrets: DISCORD_BOT_TOKEN (shared with discord-bot), DISCORD_COMMUNITY_GUILD_ID (default: the Table 1 server).
import { createClient } from "npm:@supabase/supabase-js@2";
import { isSnowflake, type Membership, memberFrom } from "./member.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const BOT_TOKEN = Deno.env.get("DISCORD_BOT_TOKEN") ?? "";
const GUILD = Deno.env.get("DISCORD_COMMUNITY_GUILD_ID") || "1565392011295465522";

async function member(discordId: string): Promise<boolean | null> {
  if (!BOT_TOKEN) return null;
  try {
    const r = await fetch(`https://discord.com/api/v10/guilds/${GUILD}/members/${discordId}`, {
      headers: { Authorization: `Bot ${BOT_TOKEN}` },
      signal: AbortSignal.timeout(4000),
    });
    const body = await r.json().catch(() => null) as { code?: number } | null;
    const m = memberFrom(r.status, body);
    if (m === null) console.error(`discord-community: guild member → ${r.status} ${body?.code ?? ""}`);
    return m;
  } catch (e) {
    console.error("discord-community:", e instanceof Error ? e.message : e);
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Sign in required" }, 401);

  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data, error } = await asCaller.rpc("discord_my_id");
  if (error) return json({ error: error.code === "28000" ? "Sign in required" : "Try again" }, error.code === "28000" ? 401 : 500);

  const out: Membership = isSnowflake(data) ? { linked: true, member: await member(data) } : { linked: false, member: null };
  return json(out);
});
