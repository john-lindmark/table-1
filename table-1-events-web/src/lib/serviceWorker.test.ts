import { describe, expect, it, vi } from "vitest";
import { registerServiceWorker } from "./serviceWorker";

function page() {
  let onLoad: (() => void) | undefined;
  return { win: { addEventListener: (_: "load", l: () => void) => { onLoad = l; } }, load: () => onLoad?.() };
}

describe("registerServiceWorker", () => {
  it("registers /sw.js at the root once the page has loaded", () => {
    const register = vi.fn(() => Promise.resolve({}));
    const p = page();
    registerServiceWorker({ serviceWorker: { register } }, p.win);
    expect(register).not.toHaveBeenCalled();
    p.load();
    expect(register).toHaveBeenCalledWith("/sw.js", { scope: "/" });
  });

  it("leaves no unhandled rejection when registration is refused (bug #31)", async () => {
    const unhandled = vi.fn();
    process.on("unhandledRejection", unhandled);
    try {
      const p = page();
      registerServiceWorker({ serviceWorker: { register: () => Promise.reject(new Error("Rejected")) } }, p.win);
      p.load();
      await new Promise((r) => setTimeout(r, 10));
      expect(unhandled).not.toHaveBeenCalled();
    } finally {
      process.off("unhandledRejection", unhandled);
    }
  });

  it("survives a register that throws, and browsers without service workers", () => {
    const p = page();
    registerServiceWorker({ serviceWorker: { register: () => { throw new Error("SecurityError"); } } }, p.win);
    expect(() => p.load()).not.toThrow();
    registerServiceWorker({}, page().win);
  });
});

describe("the build", () => {
  it("doesn't inject vite-plugin-pwa's registerSW.js, which had no catch", async () => {
    const { readFileSync } = await import("node:fs");
    const config = readFileSync(new URL("../../vite.config.ts", import.meta.url), "utf8");
    expect(config).toMatch(/injectRegister:\s*null/);
    const main = readFileSync(new URL("../main.tsx", import.meta.url), "utf8");
    expect(main).toContain("registerServiceWorker(navigator, window)");
  });
});
