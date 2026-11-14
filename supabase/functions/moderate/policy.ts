// The moderation policy the classifier applies (contract/moderation-2026-10-18.md), its output schema, and the parsing
// that turns a model answer into verdicts the database accepts. No network here: index.ts calls the API, policy.test.ts
// tests the parsing, eval.ts runs testdata/moderation/cases.json against the live model.

export const MODEL = "claude-opus-5-5";

export const VERDICTS = ["allow", "review", "block"] as const;
export const CATEGORIES = [
  "none", "hate", "harassment", "sexual", "child_safety", "violence", "self_harm", "spam", "personal_info",
  "impersonation", "other",
] as const;
export type Verdict = typeof VERDICTS[number];
export type Category = typeof CATEGORIES[number];

/** What each subject is, in words the model reads. */
export const KIND_WORDS: Record<string, string> = {
  display_name: "a player's display name",
  handle: "a player's @handle",
  list_name: "the name of a Magic deck or cube",
  binder_name: "the name of a binder of Magic cards",
  event_name: "the name of a Magic tournament",
  event_description: "an organizer's description of a Magic tournament (format, rules, prizes, where and when)",
  league_name: "the name of a league of Magic tournaments",
  league_description: "an organizer's description of a league of Magic tournaments",
  guest_name: "a guest player's name in a tournament",
  deck_photo_note: "a note on a photo of a player's deck",
  avatar: "a player's profile photo",
  deck_photo: "a photo of a player's Magic deck, taken at a tournament",
};

export const SYSTEM = `You review short pieces of user content for Table 1, an app where Magic: The Gathering players run
tournaments, track their card collections and trade with each other. Other players see this content: display names,
handles, deck/cube/binder names, tournament names, guest names, notes on deck photos, profile photos and deck photos.
Players include teenagers.

For each item decide:
- allow: fine to show. This is the answer for almost everything.
- review: unclear, a person should look (possibly offensive, context-dependent, or you can't tell).
- block: a clear violation of the rules below.

Rules (block when clearly broken):
- hate: slurs or attacks on people for race, ethnicity, nationality, religion, sex, gender identity, sexual
  orientation, disability or similar; hate symbols or slogans.
- harassment: insults or threats aimed at a real, identifiable person; names built to mock another player.
- sexual: explicit sexual content, sexual slang used as a name, nudity in photos.
- child_safety: any sexual content involving minors. Always block.
- violence: real-world threats, glorifying real attacks or terrorism.
- self_harm: encouraging suicide or self-harm.
- spam: advertising, links, "DM me for cheap cards", scam offers, crypto.
- personal_info: phone numbers, street addresses, email addresses or other contact details (in names or notes).
- impersonation: claiming to be Table 1 staff, an admin, a moderator, Wizards of the Coast, a judge program, or a
  specific well-known person ("the real Bruce Lee", "Official LSV"). Merely having the same or a similar name as a
  famous person is allow: many people share names, in every language.
- other: anything else clearly unacceptable for a general audience app.

Magic context (do NOT flag these): card names and game words are often dark or violent and are fine in every field:
Murder, Thoughtseize, Necropotence, Slaughter Pact, Hymn to Tourach, Doomsday, Death's Shadow, Bitterblossom, Kill
Shot, Terminate, Dismember, Grief, Sorin, Liliana, Phyrexian, Demonic Tutor, Torment of Hailfire, Lich, Bloodghast.
Archetype and deck names are fine: Burn, Death and Taxes, Goblins, Elves, Storm, Dredge, Reanimator, Sneak and Show,
Mono-Black Aggro, Rakdos Midrange, Hate Bears, "Kill them all", "Pain train". Mild profanity in a joking deck or
binder name ("Jank as hell", "Shitty draft chaff") is allow. Ordinary personal names, nicknames, gamer tags and
store names are allow. Deck photos show cards, sleeves, playmats, tables and hands: allow unless the photo itself
breaks a rule. A profile photo of a person, pet, card art, logo or anything ordinary is allow.

Use review rather than block when a word could be innocent in a Magic context, when you only suspect a hidden
meaning, or when text is in a language you can't judge confidently. Keep each reason under 15 words and never quote
slurs in it.`;

/** JSON schema for structured output: one result per item, by its index. */
export const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["results"],
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["i", "verdict", "category", "reason"],
        properties: {
          i: { type: "integer" },
          verdict: { type: "string", enum: [...VERDICTS] },
          category: { type: "string", enum: [...CATEGORIES] },
          reason: { type: "string" },
        },
      },
    },
  },
} as const;

export interface TextItem { id: number; kind: string; text: string }
export interface Result { id: number; verdict: Verdict; category: Category; reason: string; model: string }

/** The user message for a batch of text items: an anonymous numbered list (no ids, owners or emails). */
export function textPrompt(items: TextItem[]): string {
  const lines = items.map((it, i) => JSON.stringify({ i, kind: KIND_WORDS[it.kind] ?? it.kind, text: it.text.slice(0, 2000) }));
  return `Review these ${items.length} items. Answer with one result per item, using its i.\n\n${lines.join("\n")}`;
}

export function imagePrompt(kind: string): string {
  return `Review this image: ${KIND_WORDS[kind] ?? kind}. Answer with one result, i = 0.`;
}

/**
 * Turns the model's JSON into verdicts for `items` (in order). Anything missing, malformed or contradictory becomes
 * review: a person looks rather than the content passing or being taken down by mistake. child_safety is always block;
 * a block or review with category none becomes other.
 */
export function parseResults(raw: unknown, items: { id: number }[], model: string): Result[] {
  const list = (raw && typeof raw === "object" && Array.isArray((raw as { results?: unknown }).results))
    ? (raw as { results: unknown[] }).results
    : [];
  const byIndex = new Map<number, Record<string, unknown>>();
  for (const r of list) {
    if (r && typeof r === "object" && Number.isInteger((r as { i?: unknown }).i)) {
      const i = (r as { i: number }).i;
      if (!byIndex.has(i)) byIndex.set(i, r as Record<string, unknown>);
    }
  }
  return items.map((it, i) => {
    const r = byIndex.get(i);
    const verdict = VERDICTS.includes(r?.verdict as Verdict) ? r!.verdict as Verdict : null;
    let category = CATEGORIES.includes(r?.category as Category) ? r!.category as Category : "other";
    const reason = typeof r?.reason === "string" ? r.reason.trim().slice(0, 300) : "";
    if (!verdict) return { id: it.id, verdict: "review", category: "other", reason: "No clear answer from the check", model };
    if (category === "child_safety") return { id: it.id, verdict: "block", category, reason, model };
    if (verdict === "allow") category = "none";
    else if (category === "none") category = "other";
    return { id: it.id, verdict, category, reason, model };
  });
}

/** Every item goes to a person: used for refusals and API errors. */
export function allReview(items: { id: number }[], reason: string, model: string): Result[] {
  return items.map((it) => ({ id: it.id, verdict: "review", category: "other", reason, model }));
}

/** JPEG / PNG / WebP / GIF from the first bytes (uploads are JPEG; anything else is still sent correctly). */
export function mediaType(b: Uint8Array): "image/jpeg" | "image/png" | "image/webp" | "image/gif" | null {
  if (b[0] === 0xff && b[1] === 0xd8) return "image/jpeg";
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "image/png";
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return "image/gif";
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45) return "image/webp";
  return null;
}
