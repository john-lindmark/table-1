// Shoots the feature spots (marketing/bundle/spots/spots.json): each spot's screen on the web dev server at phone
// size (390×844 at 2x) into marketing/bundle/spots/shots/<key>.png, then the store images laid out by /dev/spots
// into marketing/store/<size>/. Needs Playwright's Chromium (run.sh installs it). `--url http://host:port` uses a
// running dev server instead of starting one; `--only key` shoots one spot; `--tiles` skips the screens.
import { chromium } from "playwright";
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { screenshotOrder } from "./storeCopy.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const file = JSON.parse(readFileSync(`${ROOT}/marketing/bundle/spots/spots.json`, "utf8"));
const args = process.argv.slice(2);
const arg = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const only = arg("--only");
const tilesOnly = args.includes("--tiles");
const PORT = 5277;

/** The store image sizes, in CSS pixels at device scale 2: App Store 6.9" (1320×2868), Play phone (1080×1920),
 *  Open Graph (1200×630), Play feature graphic (1024×500). /dev/spots draws each `[data-spot]` at these sizes. */
const SIZES = { appstore: [660, 1434], play: [540, 960], og: [600, 315], feature: [512, 250] };

let server = null;
let url = arg("--url");
if (!url) {
  url = `http://localhost:${PORT}`;
  server = spawn("npm", ["--prefix", `${ROOT}/table-1-events-web`, "run", "dev", "--", "--port", String(PORT), "--strictPort"],
    { stdio: ["ignore", "ignore", "inherit"] });
  const started = Date.now();
  for (;;) {
    try { await fetch(url + "/"); break; } catch { /* not up yet */ }
    if (Date.now() - started > 60_000) throw new Error("the dev server didn't start");
    await new Promise((r) => setTimeout(r, 300));
  }
}

const browser = await chromium.launch();
try {
  if (!tilesOnly) {
    // One context for every spot: the catalog pack (9 MB) is downloaded once and the ?demo flag stays set.
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, colorScheme: "dark", isMobile: true, hasTouch: true });
    mkdirSync(`${ROOT}/marketing/bundle/spots/shots`, { recursive: true });
    for (const s of file.spots) {
      if (only && s.key !== only) continue;
      const page = await ctx.newPage();
      const t0 = Date.now();
      await page.goto(url + s.shot.route, { waitUntil: "load" });
      if (s.shot.file) await page.locator('input[type="file"]').first().setInputFiles(`${ROOT}/${s.shot.file}`);
      await page.getByText(s.shot.ready, { exact: false }).first().waitFor({ state: "visible", timeout: 180_000 });
      // `scrollTo` puts that text at the top of its scrolling list, so the shot leads with it under the screen's bar.
      if (s.shot.scrollTo) await page.getByText(s.shot.scrollTo, { exact: true }).first().evaluate((el) => el.scrollIntoView({ block: "start" }));
      // Card art and set icons arrive after the data; give them a moment, then stop blinking cursors and spinners.
      await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => {});
      await page.waitForTimeout(800);
      await page.addStyleTag({ content: "*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }" });
      await page.screenshot({ path: `${ROOT}/marketing/bundle/spots/shots/${s.key}.png`, animations: "disabled" });
      console.log(`shot ${s.key} (${Math.round((Date.now() - t0) / 100) / 10} s)`);
      await page.close();
    }
    await ctx.close();
  }

  // The store images: /dev/spots lays every store spot out at the asked size; each tile is captured on its own.
  for (const [size, [w, h]] of Object.entries(SIZES)) {
    const ctx = await browser.newContext({ viewport: { width: w + 40, height: h + 40 }, deviceScaleFactor: 2, colorScheme: "dark" });
    const page = await ctx.newPage();
    await page.goto(`${url}/dev/spots?size=${size}`, { waitUntil: "networkidle" });
    await page.waitForSelector("[data-spot]");
    await page.waitForTimeout(500);
    mkdirSync(`${ROOT}/marketing/store/${size}`, { recursive: true });
    const order = new Map(screenshotOrder(file).map((o) => [o.key, o.n]));
    for (const tile of await page.locator("[data-spot]").all()) {
      const key = await tile.getAttribute("data-spot");
      if (only && key !== only && key !== "feature") continue;
      const name = key === "feature" ? "feature" : `${order.get(key)}-${key}`;
      await tile.screenshot({ path: `${ROOT}/marketing/store/${size}/${name}.png`, animations: "disabled" });
    }
    console.log(`tiles ${size} (${w * 2}×${h * 2})`);
    await ctx.close();
  }
} finally {
  await browser.close();
  if (server) server.kill();
}
