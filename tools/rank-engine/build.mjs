#!/usr/bin/env node
// Builds the cube ranking engine the apps download (contract/cube-rankings-2026-10-21.md § The engine as a file).
//
//   node tools/rank-engine/build.mjs            # writes the self-test case, builds, checks every shared case
//
// 1. Writes table-1-events-web/src/lib/rankEngineSelfTest.json (run D of testdata/cube-ranking/cases.json): the file
//    replays it on the phone before it's used.
// 2. Bundles table-1-events-web/src/lib/rankEngine.ts (and cubeRanking.ts) into one script that sets globalThis.T1Rank,
//    ES2019 so JavaScriptCore and QuickJS both run it, named by its content: rank-<sha256 first 12>.js.
// 3. Runs the built file in a bare VM context (no Node globals, like the phones) and replays every run of cases.json
//    through T1Rank (open, append, session, expected): each step's next screen and every summary must match.
// 4. Writes dist-engine/manifest.json {api, rules, version, file, sha256, bytes}, and the file again as
//    testdata/cube-ranking/rank-engine.js for the apps' runner tests. tools/rank-engine/publish.sh uploads the two.
import { build } from "../../table-1-events-web/node_modules/esbuild/lib/main.js";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const web = join(root, "table-1-events-web");
const out = join(root, "tools", "rank-engine", "dist-engine");
const cases = JSON.parse(readFileSync(join(root, "testdata", "cube-ranking", "cases.json"), "utf8"));

// 1. The self-test case.
const d = cases.runs.find((r) => r.id.endsWith("000d"));
const self = { id: d.id, depth: d.depth, top: d.top, cards: cases.cube.category,
               steps: d.steps.map((s) => ({ s: s.s, question: s.question, answer: s.answer })), final: d.summary.F.top };
writeFileSync(join(web, "src", "lib", "rankEngineSelfTest.json"), JSON.stringify(self) + "\n");

// 2. Bundle twice: the content hash names the version, which the file then carries.
async function bundle(version) {
  const r = await build({
    entryPoints: [join(web, "src", "lib", "rankEngine.ts")], bundle: true, write: false, format: "iife", globalName: "__t1rank",
    target: "es2019", minify: true, legalComments: "none", define: { __RANK_ENGINE_VERSION__: JSON.stringify(version) },
    footer: { js: "globalThis.T1Rank=__t1rank.T1Rank;" }, logLevel: "warning",
  });
  return r.outputFiles[0].text;
}
const probe = await bundle("v");
const version = "rank-" + createHash("sha256").update(probe).digest("hex").slice(0, 12);
const code = await bundle(version);

// 3. Every shared case through the built file, in a context with nothing but the language.
const ctx = vm.createContext({});
vm.runInContext(code, ctx, { filename: `${version}.js` });
const E = ctx.T1Rank;
const fail = (m) => { console.error(`rank-engine: ${m}`); process.exit(1); };
if (!E || E.version !== version) fail("the file didn't set T1Rank with its version");
if (E.rules !== cases.rules) fail(`rules ${E.rules} but cases.json says ${cases.rules}`);
if (!E.selfTest()) fail("selfTest failed");
const jobs = ["W", "U", "B", "R", "G", "M", "C", "L", "F"];
let checked = 0;
for (const run of cases.runs) {
  let h = E.open(JSON.stringify({ id: run.id, cards: cases.cube.category, log: [], depth: run.depth, top: run.top }));
  for (const [i, step] of run.steps.entries()) {
    if (step.s === "P") { h = E.append(h, JSON.stringify({ s: "P", o: step.answer })); continue; }
    const s = JSON.parse(E.session(h, step.s));
    if ((s.question ?? []).join() !== step.question.join()) fail(`run ${run.id.slice(-2)} step ${i}: question differs`);
    if (s.check !== step.check) fail(`run ${run.id.slice(-2)} step ${i}: check differs`);
    const next = E.append(h, JSON.stringify({ s: step.s, o: step.answer }));
    E.free(h); h = next; checked++;
  }
  for (const job of jobs) {
    const want = run.summary[job]; if (!want) continue;
    const s = JSON.parse(E.session(h, job));
    if (s.top.join() !== want.top.join() || s.done !== want.done || s.checked !== want.checked || s.check !== want.check)
      fail(`run ${run.id.slice(-2)} summary ${job} differs`);
  }
}

// 4. The file and its manifest.
mkdirSync(out, { recursive: true });
const sha256 = createHash("sha256").update(code).digest("hex");
writeFileSync(join(out, `${version}.js`), code);
const manifest = { api: E.api, rules: E.rules, version, file: `${version}.js`, sha256, bytes: Buffer.byteLength(code) };
writeFileSync(join(out, "manifest.json"), JSON.stringify(manifest, null, 1) + "\n");
// The apps' tests run this exact file through their runners (RankEngineTests, RankEngineTest).
writeFileSync(join(root, "testdata", "cube-ranking", "rank-engine.js"), code);
console.log(`rank-engine: ${version}.js, ${manifest.bytes} bytes, ${checked} steps of ${cases.runs.length} runs match`);
