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
 *   /join/ABCD  →  /join/:id
 *   /e/8f3c…    →  /e/:id
 */
export function redactPath(pathname: string): string {
  return pathname.replace(/^\/(join|e|p|s)\/[^/]+/, "/$1/:id");
}

export function trackPageView(pathname: string, search = ""): void {
  if (typeof window === "undefined" || !window.gtag) return;
  const path = redactPath(pathname);
  window.gtag("event", "page_view", {
    page_path: path,
    page_location: `${window.location.origin}${path}${search}`,
    page_title: document.title,
  });
}
