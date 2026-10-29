#!/bin/zsh
# Registers the Discord bot's commands with the application id and bot token from the Keychain
# (item "Table 1 Discord": account = the application id, password = the bot token). Pass --guild <id> to register on
# one server at once, --dry-run to print the commands instead. See SETUP.md § Discord.
set -euo pipefail
root=${0:A:h:h:h}
APP=$(security find-generic-password -s 'Table 1 Discord' 2>/dev/null | sed -n 's/.*"acct"<blob>="\(.*\)"/\1/p')
TOKEN=$(security find-generic-password -s 'Table 1 Discord' -w)
DISCORD_APPLICATION_ID=$APP DISCORD_BOT_TOKEN=$TOKEN deno run --allow-net=discord.com --allow-env --allow-read "$root/tools/discord/register.ts" "$@"
