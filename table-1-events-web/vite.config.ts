import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // The dev-only Library demo (?demo) reads the iOS Debug fixture from the repo.
  server: { port: 5173, fs: { allow: [".", "../apps/ios/Table1/DebugResources"] } },
});
