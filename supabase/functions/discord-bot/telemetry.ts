// Telemetry for the bot (contract/discord-2026-10-29.md §8, contract/telemetry-2026-10-15.md): PostHog's batch
// endpoint, sent after the interaction is answered. The distinct id is the Table 1 user id once linked (the same id
// the apps use), else a salted hash of the Discord user id. No Discord, guild, channel, event or message ids and no
// names ever go in a property.

export interface Captured {
  event: string;
  distinct_id: string;
  properties: Record<string, unknown>;
  timestamp: string;
}

const FORBIDDEN = /^(guild|channel|message|event|discord|user|participant|list)_id$|^(name|display_name|email|token|username)$/;

export async function hashId(discordId: string, salt: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${salt}:${discordId}`));
  return "discord:" + [...new Uint8Array(d)].slice(0, 8).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Properties are checked for anything that looks like an identity; such a key fails loudly in tests. */
export function cleanProperties(props: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(props)) {
    if (FORBIDDEN.test(k)) throw new Error(`telemetry property ${k} is not allowed`);
    if (v === undefined) continue;
    if (typeof v === "string" && /^\d{15,25}$/.test(v)) throw new Error(`telemetry property ${k} looks like a Discord id`);
    out[k] = v;
  }
  return out;
}

export class Telemetry {
  private batch: Captured[] = [];
  constructor(
    private readonly key: string,
    private readonly host: string,
    private readonly base: Record<string, unknown>,
  ) {}

  get enabled() {
    return Boolean(this.key);
  }

  capture(distinctId: string, event: string, properties: Record<string, unknown> = {}) {
    this.batch.push({
      event,
      distinct_id: distinctId,
      properties: { ...this.base, ...cleanProperties(properties) },
      timestamp: new Date().toISOString(),
    });
  }

  /** What would be sent (tests). */
  pending(): Captured[] {
    return this.batch;
  }

  async flush(): Promise<void> {
    if (!this.enabled || !this.batch.length) return;
    const batch = this.batch;
    this.batch = [];
    try {
      const r = await fetch(`${this.host.replace(/\/$/, "")}/batch/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ api_key: this.key, batch }),
        signal: AbortSignal.timeout(2500),
      });
      if (!r.ok) console.error(`discord-bot: posthog ${r.status}`);
    } catch (e) {
      console.error("discord-bot: posthog failed", e instanceof Error ? e.message : e);
    }
  }
}
