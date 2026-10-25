import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { execSync } from "node:child_process";
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
  plugins: [react(), tailwindcss()],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __APP_BUILD__: JSON.stringify(gitBuild()),
  },
  // The dev-only demos (?demo) read the iOS Debug fixture and the Insights packs from the repo.
  server: { port: 5173, fs: { allow: [".", "../apps/ios/Table1/DebugResources", "../testdata/insights"] } },
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
