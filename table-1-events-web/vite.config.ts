import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // The dev-only Library demo (?demo) reads the iOS Debug fixture from the repo.
  server: { port: 5173, fs: { allow: [".", "../apps/ios/Table1/DebugResources"] } },
  // Libraries change far less often than the app, so they get their own long-cached chunks.
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes("node_modules/@supabase/")) return "supabase";
          if (/node_modules\/(react|react-dom|react-router|react-router-dom|scheduler)\//.test(id)) return "react";
        },
      },
    },
  },
});
