#!/usr/bin/env -S deno run --allow-net=discord.com --allow-env --allow-read
// Registers the bot's slash commands with Discord from supabase/functions/discord-bot/commands.json
// (contract/discord-2026-10-29.md §6). Global commands take up to an hour to appear; --guild <id> registers them on
// one server at once (for trying things out).
//
//   DISCORD_APPLICATION_ID=… DISCORD_BOT_TOKEN=… tools/discord/register.ts [--guild <guild id>] [--clear] [--dry-run]
// A server that has both the global commands and its own copy shows each command twice: once the global ones have
// arrived, `--guild <id> --clear` removes that server's copy.
//
// The token is read from the environment only (or the Keychain item "Table 1 Discord" via tools/discord/register.sh).
import commands from "../../supabase/functions/discord-bot/commands.json" with { type: "json" };

const args = [...Deno.args];
const dry = args.includes("--dry-run");
const clear = args.includes("--clear");
const gi = args.indexOf("--guild");
const guild = gi >= 0 ? args[gi + 1] : null;
const appId = Deno.env.get("DISCORD_APPLICATION_ID") ?? "";
const token = Deno.env.get("DISCORD_BOT_TOKEN") ?? "";
if (!/^[0-9]{5,25}$/.test(appId)) throw new Error("DISCORD_APPLICATION_ID is missing");
if (guild && !/^[0-9]{5,25}$/.test(guild)) throw new Error("--guild needs a server id");

const path = guild ? `/applications/${appId}/guilds/${guild}/commands` : `/applications/${appId}/commands`;
const body = clear ? [] : commands.commands;
if (clear && !guild) throw new Error("--clear is for one server (--guild <id>): the global commands stay");
console.log(`${dry ? "would register" : clear ? "clearing" : "registering"} ${body.length} commands at ${path}`);
if (dry) {
  console.log(JSON.stringify(body, null, 1));
  Deno.exit(0);
}
if (!token) throw new Error("DISCORD_BOT_TOKEN is missing");
const r = await fetch(`https://discord.com/api/v10${path}`, {
  method: "PUT",
  headers: { Authorization: `Bot ${token}`, "Content-Type": "application/json" },
  body: JSON.stringify(body),
});
if (!r.ok) {
  console.error(`Discord answered ${r.status}`);
  console.error(await r.text());
  Deno.exit(1);
}
const out = await r.json() as { name: string; id: string }[];
console.log(out.map((c) => `  /${c.name}`).join("\n"));
console.log(clear ? "done (this server's own copy removed; the global commands remain)" : guild ? "done (this server, at once)" : "done (every server, within an hour)");
