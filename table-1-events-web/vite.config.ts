import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { VitePWA } from "vite-plugin-pwa";
import { execSync } from "node:child_process";
import { resolve } from "node:path";
import pkg from "./package.json";

/** The commit a build came from: telemetry's `build` and the Sentry release (site.table1.events@<version>+<build>). */
function gitBuild(): string {
  if (process.env.VITE_APP_BUILD) return process.env.VITE_APP_BUILD;
  try {
    return execSync("git rev-parse --short HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim();
  } catch {
    return "local";
  }
}

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    // The app shell works offline (contract/offline-2026-10-31.md § 5): Workbox precaches index.html and every chunk,
    // a new deploy takes over on the next load, and every route falls back to index.html. The .well-known files and
    // the Supabase functions are never served from the worker; Supabase calls aren't cached by it (the stores keep
    // what the screens need). The manifest's icons come from Figma's "App icons" board (R9h660jfTHZEcnFZ2DJtLA 19726:2756).
    VitePWA({
      registerType: "autoUpdate",
      injectRegister: "auto",
      manifest: {
        name: "Table 1",
        short_name: "Table 1",
        start_url: "/",
        display: "standalone",
        background_color: "#171725",
        theme_color: "#171725",
        icons: [
          { src: "/icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "/icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        globPatterns: ["**/*.{js,css,html,woff2}"],
        navigateFallback: "/index.html",
        navigateFallbackDenylist: [/^\/\.well-known\//, /^\/functions\//],
        skipWaiting: true,
        clientsClaim: true,
        cleanupOutdatedCaches: true,
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
      },
      devOptions: { enabled: false },
    }),
  ],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __APP_BUILD__: JSON.stringify(gitBuild()),
    // The feature-spot shots' folder: the dev server serves it as /@fs/… so a fresh shoot shows without a restart.
    __SPOTS_SHOTS_DIR__: JSON.stringify(resolve(__dirname, "../marketing/bundle/spots/shots")),
  },
  // The dev-only demos (?demo) read the iOS Debug fixture and the Insights packs from the repo.
  server: { port: 5173, fs: { allow: [".", "../apps/ios/Table1/DebugResources", "../testdata/insights", "../marketing"] } },
  // Libraries change far less often than the app, so they get their own long-cached chunks.
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes("node_modules/@supabase/")) return "supabase";
          if (id.includes("node_modules/@sentry")) return "sentry";
          if (/node_modules\/(posthog-js|@posthog)\//.test(id)) return "posthog";
          if (/node_modules\/(react|react-dom|react-router|react-router-dom|scheduler)\//.test(id)) return "react";
        },
      },
    },
  },
});
