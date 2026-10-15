// cube-lookup: a Cube Cobra link (or cube id) → the cube's name, for the Create event form.
//   POST { url }  -> { cube_id, name, card_count, url }   (signed-in users; 404 when Cube Cobra has no such cube)
// Runs server-side so browsers don't hit CORS and every client parses links the same way.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

/** cubecobra.com/cube/<page>/<id>, cubecobra.com/c/<id>, or a bare id. */
export function cubeIdFrom(input: string): string | null {
  const text = input.trim();
  if (/^[A-Za-z0-9_-]{2,64}$/.test(text)) return text;
  let u: URL;
  try {
    u = new URL(text);
  } catch {
    return null;
  }
  if (!/(^|\.)cubecobra\.com$/i.test(u.hostname)) return null;
  const parts = u.pathname.split("/").filter(Boolean);
  if (parts[0] === "c" && parts[1]) return parts[1];
  if (parts[0] === "cube" && parts.length >= 3) return parts[2];
  if (parts[0] === "cube" && parts[1]) return parts[1];
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const body = await req.json().catch(() => ({}));
  const id = cubeIdFrom(String(body.url ?? ""));
  if (!id || !/^[A-Za-z0-9_-]{2,64}$/.test(id)) return json({ error: "That isn't a Cube Cobra link" }, 400);
  try {
    const res = await fetch(`https://cubecobra.com/cube/api/cubejson/${encodeURIComponent(id)}`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(8000),
    });
    if (res.status === 404) return json({ error: "Cube Cobra has no cube at that link" }, 404);
    if (!res.ok) return json({ error: "Cube Cobra didn't answer. Type the name instead." }, 502);
    const cube = await res.json();
    const shortId = String(cube.shortId || cube.id || id);
    const mainboard = cube.cards?.mainboard;
    return json({
      cube_id: shortId,
      name: String(cube.name ?? "").trim().slice(0, 80) || shortId,
      card_count: typeof cube.cardCount === "number" ? cube.cardCount : Array.isArray(mainboard) ? mainboard.length : null,
      url: `https://cubecobra.com/cube/overview/${encodeURIComponent(shortId)}`,
    });
  } catch {
    return json({ error: "Cube Cobra didn't answer. Type the name instead." }, 502);
  }
});
