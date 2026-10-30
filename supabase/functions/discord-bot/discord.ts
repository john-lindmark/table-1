// Discord's REST API, the little we use: follow-ups on an interaction, reading the message an interaction made,
// editing a card in a channel, posting a message. Everything runs after the interaction has been answered (or, for a
// card edit, when Table 1 asks).

const API = "https://discord.com/api/v10";

export interface Message {
  content?: string;
  embeds?: unknown[];
  components?: unknown[];
  flags?: number;
  allowed_mentions?: { parse: string[] };
}

/** Never logs the body: it could carry what someone typed. Discord's numeric error code is safe and says why. */
async function logFailure(method: string, path: string, r: Response): Promise<Response> {
  if (r.ok) return r;
  const code = await r.clone().json().then((j) => (j as { code?: number })?.code).catch(() => undefined);
  console.error(`discord-bot: ${method} ${path.replace(/\/[0-9]{5,25}/g, "/…").replace(/\/[A-Za-z0-9_-]{40,}/g, "/…")} → ${r.status}${code ? ` (${code})` : ""}`);
  return r;
}

/** The interaction a webhook call belongs to. Its application id comes from Discord's signed payload, never from a
 *  secret: a DISCORD_APPLICATION_ID secret holding its own name made every follow-up and card id read fail (50035). */
export interface InteractionRef {
  application_id: string;
  token: string;
}

export class DiscordRest {
  constructor(private readonly botToken: string, private readonly answerWaits = [250, 750, 1500, 3000]) {}

  private async call(method: string, path: string, body?: unknown, auth = true, log = true): Promise<Response> {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (auth) headers.Authorization = `Bot ${this.botToken}`;
    const r = await fetch(`${API}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(4000),
    });
    if (log) await logFailure(method, path, r);
    return r;
  }

  /** A call on the interaction's own webhook. Side work starts while our answer is still on its way to Discord, and
   *  until Discord has it, it refuses these (400 / 404), so try again for a few seconds. */
  private async afterAnswer(method: string, path: string, body?: unknown): Promise<Response> {
    const waits = [0, ...this.answerWaits];
    let r: Response | null = null;
    for (let i = 0; i < waits.length; i++) {
      if (waits[i]) await new Promise((ok) => setTimeout(ok, waits[i]));
      r = await this.call(method, path, body, false, false);
      if (r.ok || i === waits.length - 1 || (r.status !== 400 && r.status !== 404)) break;
      await r.body?.cancel();
    }
    return await logFailure(method, path, r!);
  }

  /** A channel message edit; one wait when Discord asks us to slow down (a burst of sign-ups). */
  async editMessage(channelId: string, messageId: string, message: Message): Promise<Response> {
    const path = `/channels/${channelId}/messages/${messageId}`;
    const body = { ...message, allowed_mentions: { parse: [] } };
    const r = await this.call("PATCH", path, body, true, false);
    if (r.status !== 429) return await logFailure("PATCH", path, r);
    const wait = await r.clone().json().then((j) => Number((j as { retry_after?: number })?.retry_after)).catch(() => NaN);
    if (!(wait >= 0 && wait <= 5)) return await logFailure("PATCH", path, r);
    await new Promise((ok) => setTimeout(ok, Math.ceil(wait * 1000)));
    return await this.call("PATCH", path, body);
  }

  /** An extra message on the interaction (ephemeral when flags has 64). Valid for 15 minutes. */
  followUp(ix: InteractionRef, message: Message) {
    return this.afterAnswer("POST", `/webhooks/${ix.application_id}/${ix.token}`, { ...message, allowed_mentions: { parse: [] } });
  }

  /** The id of the message the interaction's first response made. */
  async originalMessageId(ix: InteractionRef): Promise<string | null> {
    const r = await this.afterAnswer("GET", `/webhooks/${ix.application_id}/${ix.token}/messages/@original`);
    if (!r.ok) return null;
    const m = await r.json().catch(() => null) as { id?: string } | null;
    return m?.id ?? null;
  }

  async postMessage(channelId: string, message: Message): Promise<string | null> {
    const r = await this.call("POST", `/channels/${channelId}/messages`, { ...message, allowed_mentions: { parse: [] } });
    if (!r.ok) return null;
    const m = await r.json().catch(() => null) as { id?: string } | null;
    return m?.id ?? null;
  }
}
