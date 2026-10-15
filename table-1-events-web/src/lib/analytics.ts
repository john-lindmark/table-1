declare global {
  interface Window {
    gtag?: (...args: unknown[]) => void;
  }
}

/**
 * A join code is the credential for joining an event — anyone holding it can
 * add themselves as a player — and event ids identify a specific night of
 * someone's tournament. Neither belongs in a third-party analytics property, so
 * the identifying segment is replaced before any page view is sent.
 *
 *   /join/ABCD       →  /join/:id
 *   /j/ABCD?s=…      →  /j/:id        (the QR secret is dropped from the query too)
 *   /e/8f3c…         →  /e/:id
 */
export function redactPath(pathname: string): string {
  return pathname.replace(/^\/(join|j|e|p|s)\/[^/]+/, "/$1/:id");
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

export function trackPageView(pathname: string, search = ""): void {
  if (typeof window === "undefined" || !window.gtag) return;
  const path = redactPath(pathname);
  window.gtag("event", "page_view", {
    page_path: path,
    page_location: `${window.location.origin}${path}${redactSearch(search)}`,
    page_title: document.title,
  });
}
