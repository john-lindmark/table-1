// Discord's REST API, the little we use: follow-ups on an interaction, reading the message an interaction made,
// editing a card in a channel, posting a message. Everything runs after the interaction has been answered.

const API = "https://discord.com/api/v10";

export interface Message {
  content?: string;
  embeds?: unknown[];
  components?: unknown[];
  flags?: number;
  allowed_mentions?: { parse: string[] };
}

export class DiscordRest {
  constructor(private readonly applicationId: string, private readonly botToken: string) {}

  private async call(method: string, path: string, body?: unknown, auth = true): Promise<Response> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (auth) headers.Authorization = `Bot ${this.botToken}`;
    const r = await fetch(`${API}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(4000),
    });
    if (!r.ok) {
      // Never log the body: it could carry what someone typed.
      console.error(`discord-bot: ${method} ${path.replace(/\/[0-9]{5,25}/g, "/…").replace(/\/[A-Za-z0-9_-]{40,}/g, "/…")} → ${r.status}`);
    }
    return r;
  }

  /** An extra message on the interaction (ephemeral when flags has 64). Valid for 15 minutes. */
  followUp(interactionToken: string, message: Message) {
    return this.call("POST", `/webhooks/${this.applicationId}/${interactionToken}`, { ...message, allowed_mentions: { parse: [] } }, false);
  }

  /** The id of the message the interaction's first response made. */
  async originalMessageId(interactionToken: string): Promise<string | null> {
    const r = await this.call("GET", `/webhooks/${this.applicationId}/${interactionToken}/messages/@original`, undefined, false);
    if (!r.ok) return null;
    const m = await r.json().catch(() => null) as { id?: string } | null;
    return m?.id ?? null;
  }

  editMessage(channelId: string, messageId: string, message: Message) {
    return this.call("PATCH", `/channels/${channelId}/messages/${messageId}`, { ...message, allowed_mentions: { parse: [] } });
  }

  async postMessage(channelId: string, message: Message): Promise<string | null> {
    const r = await this.call("POST", `/channels/${channelId}/messages`, { ...message, allowed_mentions: { parse: [] } });
    if (!r.ok) return null;
    const m = await r.json().catch(() => null) as { id?: string } | null;
    return m?.id ?? null;
  }
}
