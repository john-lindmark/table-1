/**
 * Registers the offline shell's service worker (contract/offline-2026-10-31.md § 5) once the page has loaded.
 *
 * vite-plugin-pwa's own registerSW.js called `register` without a catch, so any refused registration (private
 * windows, storage switched off, an in-app browser or extension that wraps `register`) became an unhandled
 * rejection in Sentry (bug #31). The site works without the worker, so a refusal is ignored.
 */
type Nav = { serviceWorker?: { register(url: string, options?: { scope?: string }): Promise<unknown> } };
type Win = { addEventListener(type: "load", listener: () => void): void };

export function registerServiceWorker(nav: Nav, win: Win, url = "/sw.js"): void {
  const sw = nav.serviceWorker;
  if (!sw) return;
  win.addEventListener("load", () => {
    try {
      Promise.resolve(sw.register(url, { scope: "/" })).catch(() => { /* no offline shell this time */ });
    } catch {
      /* register threw outright: same */
    }
  });
}
