/**
 * What may leave the browser in a URL. Pure functions, shared by PostHog (`$current_url` and friends) and Sentry
 * (page URLs, breadcrumbs, transaction names). See contract/telemetry-2026-10-15.md.
 *
 * A join code is the credential for joining an event — anyone holding it can add themselves as a player — and
 * event, match, list and trade ids identify someone's own rows. None of them belongs in a third-party tool, so the
 * identifying segment is replaced before anything is sent.
 *
 *   /join/ABCD            →  /join/:id
 *   /j/ABCD?s=…           →  /j/:id        (the QR secret is dropped from the query too)
 *   /e/8f3c…/add          →  /e/:id/add
 *   /life/8f3c…           →  /life/:id
 *   /library/list/8f3c…   →  /library/list/:id   (also card/…, trade/…, match/…; /library/trade/new stays)
 *   /u/8f3c…/deck/2b1d…   →  /u/:id/deck/:id     (profiles and their binders, decks and cubes)
 *   /library/following/deck/2b1d…  →  /library/following/deck/:id
 */
export function redactPath(pathname: string): string {
  return pathname
    .replace(/^\/(join|j|e|p|s|l|life|u)\/[^/]+/, "/$1/:id")
    .replace(/^(\/u\/:id\/(?:binder|deck|cube))\/[^/]+/, "$1/:id")
    .replace(/^\/library\/(card|list|trade|match)\/(?!new(?:\/|$))[^/]+/, "/library/$1/:id")
    .replace(/^(\/library\/following\/(?:binder|deck|cube))\/[^/]+/, "$1/:id");
}

/** Query parameters that are credentials: the QR join secret and OAuth return values. */
const SECRET_PARAMS = ["s", "code", "token", "access_token", "refresh_token", "state"];

export function redactSearch(search: string): string {
  if (!search) return "";
  const params = new URLSearchParams(search);
  for (const key of SECRET_PARAMS) params.delete(key);
  const rest = params.toString();
  return rest ? `?${rest}` : "";
}

/**
 * A full URL made safe to send. On this site: redacted path and query, no hash (OAuth tokens can arrive there).
 * Anywhere else (a referrer): the origin only.
 */
export function redactUrl(url: string, origin: string): string {
  let u: URL;
  try {
    u = new URL(url, origin);
  } catch {
    return "";
  }
  if (u.origin !== origin) return u.protocol.startsWith("http") ? u.origin : "";
  return `${u.origin}${redactPath(u.pathname)}${redactSearch(u.search)}`;
}

/** A URL with its query and hash removed (Sentry: PostgREST filters put row ids in query strings). */
export function stripQuery(url: string): string {
  const i = url.search(/[?#]/);
  return i < 0 ? url : url.slice(0, i);
}

const URL_KEY = /(^|[_$])(url|referrer)$/i;
const PATH_KEY = /pathname$/i;

/**
 * Applies the URL rules to a PostHog property bag: the SDK adds `$current_url`, `$pathname`, `$referrer`,
 * `$initial_*`, `$session_entry_*` and `$initial_person_info` ({ u, r }) on its own.
 */
export function scrubProperties(props: Record<string, unknown> | undefined, origin: string) {
  if (!props) return props;
  for (const [key, value] of Object.entries(props)) {
    if (typeof value === "string") {
      if (URL_KEY.test(key)) props[key] = value && value !== "$direct" ? redactUrl(value, origin) : value;
      else if (PATH_KEY.test(key)) props[key] = redactPath(value);
    } else if (key === "$initial_person_info" && value && typeof value === "object") {
      const info = value as { u?: unknown; r?: unknown };
      if (typeof info.u === "string") info.u = redactUrl(info.u, origin);
      if (typeof info.r === "string" && info.r !== "$direct") info.r = redactUrl(info.r, origin);
    }
  }
  return props;
}

/**
 * The contract's screen name for a route, so web page views line up with the apps' `$screen` events.
 * `listKind` answers deck or cube for /library/list/:id (unknown until the lists have loaded).
 */
export function screenName(pathname: string, listKind?: (id: string) => "deck" | "cube" | undefined): string | undefined {
  const p = pathname.replace(/\/+$/, "") || "/";
  if (p === "/") return "events_home";
  if (p === "/me") return "account";
  if (p === "/me/deck-photos") return "my_deck_photos";
  if (p === "/support") return "support";
  if (p === "/support/guide") return "support_guides";
  const support = p.match(/^\/support\/(topic|faq|guide)\/[^/]+$/);
  if (support) return `support_${support[1]}`;
  if (/^\/(e|p|s|join|j)\/[^/]+$/.test(p)) return "event";
  if (/^\/e\/[^/]+\/add$/.test(p)) return "add_players";
  if (/^\/(e|p)\/[^/]+\/photos$/.test(p)) return "deck_photos";
  if (/^\/life(\/[^/]+)?$/.test(p)) return "life_tracker";
  const fixed: Record<string, string> = {
    "/library": "library_home",
    "/library/cards": "all_cards",
    "/library/add": "add_cards",
    "/library/import": "collection_import",
    "/library/decks": "decks",
    "/library/cubes": "cubes",
    "/library/find": "deck_finder",
    "/library/trades": "trades",
    "/library/binders": "binders",
    "/library/wants": "wants",
    "/library/matches": "trade_matches",
    "/library/following": "following",
    "/friends": "friends",
    "/friends/add": "friend_add",
    "/sharing": "sharing",
    "/library/rankings": "rankings",
  };
  if (fixed[p]) return fixed[p];
  if (/^\/library\/card\/[^/]+$/.test(p)) return "card_detail";
  if (/^\/library\/import\/[^/]+$/.test(p)) return "list_import";
  if (/^\/library\/trade\/[^/]+$/.test(p)) return "trade";
  if (/^\/library\/binder\/[^/]+$/.test(p)) return "binder";
  if (/^\/library\/match\/[^/]+$/.test(p)) return "trade_match";
  if (/^\/library\/following\/[^/]+\/[^/]+$/.test(p)) return "follow_changes";
  if (/^\/l\/[^/]+$/.test(p)) return "shared_link";
  const insight = insightsScreen(p);
  if (insight) return insight;
  if (/^\/u\/[^/]+$/.test(p)) return "profile";
  if (/^\/u\/[^/]+\/[^/]+(\/[^/]+)?$/.test(p)) return "profile_cards";
  const ranking = p.match(/^\/library\/ranking\/[^/]+(\/[^/]+)?/);
  if (ranking) {
    return ({ "": "ranking", "/screen": "ranking_screen", "/lists": "ranking_lists", "/card": "ranking_card", "/compare": "ranking_compare",
              "/pack": "ranking_pack", "/changes": "ranking_changes" } as Record<string, string>)[ranking[1] ?? ""];
  }
  const list = p.match(/^\/library\/list\/([^/]+)(\/.*)?$/);
  if (list) {
    const rest = list[2] ?? "";
    if (rest === "") return listKind?.(list[1]);
    if (rest === "/add") return "list_add";
    if (rest === "/printing") return "list_printing";
    if (rest === "/versions" || rest.startsWith("/v/")) return "list_versions";
    if (rest === "/stats") {
      const kind = listKind?.(list[1]);
      return kind ? `${kind}_stats` : undefined;
    }
    if (rest === "/stats/hand") return "sample_hand";
    if (rest === "/stats/odds") return "draw_odds";
    if (rest === "/stats/pack") return "sample_pack";
    if (rest === "/rankings") return "rankings";
  }
  return undefined;
}

/** Insights screens (contract/insights-2026-10-24.md § Telemetry). */
function insightsScreen(p: string): string | undefined {
  if (p === "/insights") return "insights_constructed";
  if (p === "/insights/limited") return "insights_limited";
  if (p === "/insights/review") return "insights_review";
  if (/^\/insights\/limited\/[^/]+\/[^/]+\/[^/]+\/pair\/[^/]+$/.test(p)) return "insights_pair";
  if (/^\/insights\/limited\/[^/]+\/[^/]+\/[^/]+\/card\/[^/]+$/.test(p)) return "insights_limited_card";
  if (/^\/insights\/[^/]+\/archetype\/[^/]+\/finish\/[^/]+$/.test(p)) return "insights_finish";
  if (/^\/insights\/[^/]+\/archetype\/[^/]+$/.test(p)) return "insights_archetype";
  if (/^\/insights\/[^/]+\/card\/[^/]+$/.test(p)) return "insights_card";
  if (/^\/insights\/[^/]+\/ban\/[^/]+$/.test(p)) return "insights_ban";
  if (/^\/insights\/[^/]+\/matchups$/.test(p)) return "insights_matchups";
  if (/^\/insights\/[^/]+\/part\/[^/]+$/.test(p)) return "insights_part";
  return undefined;
}
