import { useEffect } from "react";

/**
 * Keeps the screen on while the page is visible (Screen Wake Lock; ignored where unsupported). The browser drops
 * the lock whenever the tab is hidden, so it's asked for again each time the page comes back.
 */
export function useWakeLock() {
  useEffect(() => {
    type Sentinel = { release: () => Promise<void> };
    const nav = navigator as Navigator & { wakeLock?: { request: (type: "screen") => Promise<Sentinel> } };
    if (!nav.wakeLock) return;
    let sentinel: Sentinel | null = null;
    let live = true;
    const request = async () => {
      if (document.visibilityState !== "visible") return;
      try {
        const s = await nav.wakeLock!.request("screen");
        if (live) sentinel = s;
        else void s.release().catch(() => {});
      } catch {
        /* denied (battery saver, an insecure page): the screen may sleep */
      }
    };
    void request();
    const onVisibility = () => {
      if (document.visibilityState === "visible") void request();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      live = false;
      document.removeEventListener("visibilitychange", onVisibility);
      void sentinel?.release().catch(() => {});
    };
  }, []);
}
