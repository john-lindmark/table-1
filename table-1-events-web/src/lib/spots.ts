import spotsJson from "../../../marketing/bundle/spots/spots.json";

/**
 * Feature spots (contract/feature-spots-2026-11-01.md): the pieces of Table 1 worth showing, with copy and a phone
 * shot of the real screen, from one file the apps bundle too. The landing page draws them; /dev/spots lays them out
 * as store images for tools/spots/shoot.mjs to capture.
 */
export interface Spot {
  key: string;
  title: string;
  headline: string;
  body: string;
  shot: { route: string; ready: string; scrollTo?: string; file?: string };
  /** In the apps' sign-in carousel and the landing page's spots. */
  onboarding: boolean;
  /** Gets an App Store / Play screenshot. */
  store: boolean;
}

export interface SpotsFile {
  updated: string;
  product: { name: string; tagline: string; line: string; fan_content: string };
  limits: { title: number; headline: number; body: number };
  spots: Spot[];
  store: { subtitle: string; promotional_text: string; keywords: string; short_description: string };
}

export const SPOTS: SpotsFile = spotsJson as SpotsFile;

/** The phone shots, by spot key, bundled from marketing/bundle/spots/shots (missing until the first shoot). */
const SHOT_URLS = import.meta.glob("../../../marketing/bundle/spots/shots/*.png", { eager: true, query: "?url", import: "default" }) as Record<string, string>;

export function shotUrl(key: string): string | null {
  // The dev server reads the folder as it is now, so a fresh shoot (tools/spots/shoot.mjs) shows without a restart.
  if (import.meta.env.DEV && typeof __SPOTS_SHOTS_DIR__ === "string") return `/@fs${__SPOTS_SHOTS_DIR__}/${key}.png?v=${SPOTS.updated}`;
  const hit = Object.entries(SHOT_URLS).find(([path]) => path.endsWith(`/${key}.png`));
  return hit ? hit[1] : null;
}

/** The spots in their order, onboarding ones only unless `all`. */
export function spots(all = false): Spot[] {
  return all ? SPOTS.spots : SPOTS.spots.filter((s) => s.onboarding);
}

/** Copy outside its limit: title / headline / body of a spot, as "key.field". */
export function copyProblems(file: SpotsFile = SPOTS): string[] {
  const out: string[] = [];
  for (const s of file.spots) {
    for (const field of ["title", "headline", "body"] as const) {
      if (s[field].length > file.limits[field]) out.push(`${s.key}.${field}`);
      if (s[field].trim() !== s[field] || s[field].length === 0) out.push(`${s.key}.${field}`);
    }
  }
  return out;
}
