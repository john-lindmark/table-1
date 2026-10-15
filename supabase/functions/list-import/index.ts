// list-import: a deck or cube from a link or a pasted list (contract/list-import-2026-10-15.md).
//   POST { url } | { text }   Authorization: Bearer <user JWT>
//   -> { kind: "deck" | "cube", name, format, source_url, entries: [{ qty, board, name, set?, cn?, scryfall_id?, finish? }] }
// Links: Cube Cobra and Archidekt through their JSON (exact printings and finishes), MTGGoldfish through its text
// download, Moxfield is refused with how to paste instead (it blocks other apps), and any other page (ManaBox,
// TappedOut, mtgdecks, melee.gg, ...) is fetched and read by Claude. Pasted text is parsed here: Moxfield, ManaBox,
// Arena and MTGO exports ("4 Lightning Bolt (2X2) 117 *F*", section headers, a blank line before the sideboard).
// The client resolves each line against its catalog: scryfall_id, then set + collector number, then the name.
// Secrets: ANTHROPIC_API_KEY (only for pages without a known format).
import Anthropic from "npm:@anthropic-ai/sdk@0.110.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { parseList, type Line } from "./parse.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const UA = "Mozilla/5.0 (compatible; Table1/1.0; +https://table-1.site)";

class Refusal extends Error {
  constructor(message: string, readonly status = 422) { super(message); }
}

interface Imported {
  kind: "deck" | "cube";
  name: string;
  format: string;
  source_url: string;
  entries: Line[];
}

async function getJson(u: string) {
  const res = await fetch(u, { headers: { Accept: "application/json", "User-Agent": UA }, signal: AbortSignal.timeout(10_000) });
  if (res.status === 404) throw new Refusal("Nothing is at that link. Check that the list is public.", 404);
  if (!res.ok) throw new Refusal(`That site didn't answer (${res.status}). Try again, or paste the list instead.`, 502);
  return res.json();
}

/** cubecobra.com/cube/<page>/<id>, cubecobra.com/c/<id>. */
async function cubeCobra(u: URL): Promise<Imported> {
  const parts = u.pathname.split("/").filter(Boolean);
  const id = parts[0] === "c" ? parts[1] : parts[0] === "cube" ? (parts.length >= 3 ? parts[2] : parts[1]) : null;
  if (!id || !/^[A-Za-z0-9_-]{2,64}$/.test(id)) throw new Refusal("That isn't a Cube Cobra cube link.", 400);
  const cube = await getJson(`https://cubecobra.com/cube/api/cubejson/${encodeURIComponent(id)}`);
  const line = (c: Record<string, any>, board: Line["board"]): Line => ({
    qty: 1, board, name: String(c.details?.name ?? c.name ?? ""),
    scryfall_id: typeof c.cardID === "string" ? c.cardID : c.details?.scryfall_id,
    finish: /foil/i.test(String(c.finish ?? "")) && !/non/i.test(String(c.finish)) ? "foil" : /etched/i.test(String(c.finish ?? "")) ? "etched" : undefined,
  });
  const main = (cube.cards?.mainboard ?? []).map((c: Record<string, any>) => line(c, "main"));
  const maybe = (cube.cards?.maybeboard ?? []).map((c: Record<string, any>) => line(c, "maybe"));
  return {
    kind: "cube", name: String(cube.name ?? "Imported cube"), format: "vintage",
    source_url: `https://cubecobra.com/cube/list/${encodeURIComponent(String(cube.shortId || id))}`,
    entries: [...main, ...maybe].filter((l) => l.name),
  };
}

const ARCHIDEKT_FORMATS: Record<number, string> = { 1: "standard", 2: "modern", 3: "commander", 4: "legacy", 5: "vintage", 6: "pauper", 13: "pioneer", 15: "premodern" };

/** archidekt.com/decks/<id>/<slug>. */
async function archidekt(u: URL): Promise<Imported> {
  const id = u.pathname.match(/\/decks\/(\d+)/)?.[1];
  if (!id) throw new Refusal("That isn't an Archidekt deck link.", 400);
  const d = await getJson(`https://archidekt.com/api/decks/${id}/`);
  const entries: Line[] = [];
  for (const c of d.cards ?? []) {
    const cats: string[] = (c.categories ?? []).map((x: unknown) => String(x).toLowerCase());
    const board: Line["board"] = cats.includes("maybeboard") ? "maybe" : cats.includes("sideboard") ? "side" : cats.includes("commander") ? "commander" : "main";
    const mod = String(c.modifier ?? "").toLowerCase();
    entries.push({
      qty: Number(c.quantity) || 1, board, name: String(c.card?.oracleCard?.name ?? c.card?.name ?? ""),
      scryfall_id: c.card?.uid, set: c.card?.edition?.editioncode, cn: c.card?.collectorNumber,
      finish: mod === "foil" ? "foil" : mod === "etched" ? "etched" : undefined,
    });
  }
  return { kind: "deck", name: String(d.name ?? "Imported deck"), format: ARCHIDEKT_FORMATS[Number(d.deckFormat)] ?? "other",
           source_url: `https://archidekt.com/decks/${id}`, entries: entries.filter((l) => l.name) };
}

/** mtggoldfish.com/deck/<id> or /archetype/... pages have a text download for decks. */
async function goldfish(u: URL): Promise<Imported> {
  const id = u.pathname.match(/\/deck\/(?:download\/)?(\d+)/)?.[1];
  if (!id) return await anyPage(u);
  const res = await fetch(`https://www.mtggoldfish.com/deck/download/${id}`, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(10_000) });
  if (!res.ok) throw new Refusal("MTGGoldfish didn't answer. Try again, or paste the list instead.", 502);
  const parsed = parseList(await res.text());
  return { kind: "deck", name: parsed.name ?? "MTGGoldfish deck", format: "other", source_url: u.toString(), entries: parsed.entries };
}

/** Pages without a known format: fetch, strip to text, and have Claude read the list out. */
async function anyPage(u: URL): Promise<Imported> {
  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) throw new Refusal("Paste the list instead: this site isn't supported yet.");
  const res = await fetch(u, { headers: { "User-Agent": UA, Accept: "text/html" }, signal: AbortSignal.timeout(12_000), redirect: "follow" });
  if (res.status === 403 || res.status === 401) throw new Refusal("That site doesn't let other apps read it. Export or copy the list there and paste it here.");
  if (!res.ok) throw new Refusal(`That page didn't load (${res.status}). Check that the list is public, or paste it instead.`, 502);
  const html = (await res.text()).slice(0, 1_500_000);
  const text = html
    .replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<svg[\s\S]*?<\/svg>/gi, " ")
    .replace(/<(br|\/p|\/div|\/li|\/tr|\/h\d)[^>]*>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&").replace(/&#39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/&nbsp;/g, " ")
    .replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim()
    .slice(0, 120_000);
  if (text.length < 40) throw new Refusal("That page has no list to read. Paste the list instead.");
  const client = new Anthropic({ apiKey });
  const msg = await client.messages.create({
    model: "claude-opus-5-5",
    max_tokens: 16_000,
    output_config: { effort: "low" },
    system: "You read Magic: The Gathering deck and cube lists out of web page text. Copy exactly what the page lists: every card with its count and section. Don't add, guess or correct cards. If the page has no list, report an empty one.",
    tools: [{
      name: "report_list",
      description: "Report the list on the page.",
      strict: true,
      input_schema: {
        type: "object", additionalProperties: false, required: ["kind", "name", "format", "entries"],
        properties: {
          kind: { type: "string", enum: ["deck", "cube"] },
          name: { type: "string", description: "The list's title on the page" },
          format: { type: "string", description: "standard, pioneer, modern, legacy, vintage, pauper, commander, premodern, or other" },
          entries: {
            type: "array",
            items: {
              type: "object", additionalProperties: false, required: ["qty", "board", "name", "set", "cn", "foil"],
              properties: {
                qty: { type: "integer" },
                board: { type: "string", enum: ["main", "side", "maybe", "commander"] },
                name: { type: "string" },
                set: { type: "string", description: "Set code if the page shows it, else empty" },
                cn: { type: "string", description: "Collector number if the page shows it, else empty" },
                foil: { type: "boolean" },
              },
            },
          },
        },
      },
    }],
    tool_choice: { type: "auto" },
    messages: [{ role: "user", content: `Page: ${u}\n\nCall report_list with the list on this page.\n\n${text}` }],
  } as unknown as Anthropic.MessageCreateParamsNonStreaming);
  const use = msg.content.find((b) => b.type === "tool_use") as Anthropic.ToolUseBlock | undefined;
  const r = (use?.input ?? {}) as { kind?: string; name?: string; format?: string; entries?: Record<string, any>[] };
  const entries: Line[] = (r.entries ?? []).map((e) => ({
    qty: Number(e.qty) || 1, board: e.board, name: String(e.name ?? ""),
    set: e.set || undefined, cn: e.cn || undefined, finish: e.foil ? "foil" : undefined,
  }));
  if (!entries.length) throw new Refusal("No list turned up on that page. Paste the list instead.");
  return { kind: r.kind === "cube" ? "cube" : "deck", name: r.name || "Imported list", format: r.format || "other",
           source_url: u.toString(), entries };
}

async function fromUrl(raw: string): Promise<Imported> {
  let u: URL;
  try {
    u = new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`);
  } catch {
    throw new Refusal("That isn't a link.", 400);
  }
  if (!/^https?:$/.test(u.protocol)) throw new Refusal("That isn't a web link.", 400);
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  // Public sites only: no local or private addresses.
  if (/^(localhost|.*\.local|.*\.internal)$/.test(host) || /^\d+\.\d+\.\d+\.\d+$/.test(host) || host.includes(":")) {
    throw new Refusal("That isn't a public deck site.", 400);
  }
  if (host.endsWith("cubecobra.com")) return cubeCobra(u);
  if (host.endsWith("archidekt.com")) return archidekt(u);
  if (host.endsWith("mtggoldfish.com")) return goldfish(u);
  if (host.endsWith("moxfield.com")) {
    throw new Refusal("Moxfield doesn't let other apps read its decks. In Moxfield open the deck, choose Export, copy the list as text and paste it here.");
  }
  return anyPage(u);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Sign in to import lists" }, 401);
  const asCaller = createClient(url, anonKey, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: userData, error: userError } = await asCaller.auth.getUser(auth.slice(7));
  if (userError || !userData.user) return json({ error: "Sign in to import lists" }, 401);

  const body = await req.json().catch(() => ({}));
  try {
    let out: Imported;
    if (typeof body.text === "string" && body.text.trim()) {
      const parsed = parseList(body.text.slice(0, 200_000));
      if (!parsed.entries.length) throw new Refusal("No cards in that list. Each line should start with a count, like \"4 Lightning Bolt\".", 400);
      out = { kind: "deck", name: parsed.name ?? "", format: "other", source_url: "", entries: parsed.entries };
    } else if (typeof body.url === "string" && body.url.trim()) {
      out = await fromUrl(body.url.trim().slice(0, 500));
    } else {
      return json({ error: "Paste a link or a list" }, 400);
    }
    out.entries = out.entries.filter((e) => e.qty > 0 && e.name).slice(0, 2000).map((e) => ({ ...e, qty: Math.min(999, Math.round(e.qty)) }));
    return json(out);
  } catch (e) {
    if (e instanceof Refusal) return json({ error: e.message }, e.status);
    console.error("list-import", e);
    return json({ error: "That list couldn't be read. Try again, or paste it instead." }, 502);
  }
});
