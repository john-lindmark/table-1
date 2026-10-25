// Reads one 17Lands file the way limited-sync does (range slices, resumable inflate, checkpoints round-tripped
// through base64 as the database stores them) and writes the run's sums as SQL for the demo database, timing
// each slice. Checks the worker's slicing on real files without deploying.
//   deno run --allow-net --allow-write tools/insights/limited_local.ts <SET> <event> <game|draft> <released yyyy-mm-dd> <out.sql>
import { inflateMembers, startAt } from "../../supabase/functions/limited-sync/members.ts";
import { headerColumns, Lines, Rows, type Acc } from "../../supabase/functions/limited-sync/parse.ts";

const [set, event, kind, released, out] = Deno.args as [string, string, "game" | "draft", string, string];
const uri = `https://17lands-public.s3.amazonaws.com/analysis_data/${kind}_data/${kind}_data_public.${set}.${event}.csv.gz`;
const SLICE = 5_000_000, OUT = 240 * 1024 * 1024, RESERVE = 256 * 1024;
const b64 = (b: Uint8Array) => { let s = ""; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

let bit: number | null = null, win = "", carry = "", header: string[] | null = null, step = 0, totalRows = 0;
const total: Acc = new Map();
let worst = 0;
for (;;) {
  const base = bit == null ? 0 : Math.floor(bit / 8);
  const res = await fetch(uri, { headers: { Range: `bytes=${base}-${base + SLICE - 1}` } });
  const size = Number(res.headers.get("content-range")?.split("/")[1]);
  const data = new Uint8Array(await res.arrayBuffer());
  const t0 = performance.now();
  const from = startAt(data, base, bit, unb64(win));
  let rows: Rows | null = header ? new Rows({ kind, cols: header }, Date.parse(released)) : null;
  const lines = new Lines(unb64(carry), (b) => {
    if (!rows) { header = headerColumns(new TextDecoder().decode(b)); rows = new Rows({ kind, cols: header }, Date.parse(released)); }
    else rows.line(b);
  });
  const { checkpoint: cp, done } = inflateMembers(data, base, size, from, RESERVE, OUT, (o) => lines.push(o));
  if (done) lines.end();
  const r = rows as Rows | null;
  const acc = r?.acc ?? new Map();
  const ms = performance.now() - t0;
  worst = Math.max(worst, ms);
  for (const [k, [g, w]] of acc) { const v = total.get(k); if (v) { v[0] += g; v[1] += w; } else total.set(k, [g, w]); }
  totalRows += r?.rows ?? 0;
  console.log(`step ${step}: ${Math.round(cp.bit / 8 / size * 100)}% rows ${r?.rows ?? 0} keys ${acc.size} ${ms.toFixed(0)} ms`);
  bit = cp.bit; win = b64(cp.window); carry = b64(lines.carry); step++;
  if (done) break;
}
const q = (s: string) => `'${s.replace(/'/g, "''")}'`;
const runSql = `insert into t1_private.limited_runs (set_code, event_type, kind, uri, last_modified, total_bytes, status, step, rows, finished_at)
values (${q(set)}, ${q(event)}, ${q(kind)}, ${q(uri)}, now(), 0, 'done', ${step}, ${totalRows}, now()) returning id \\gset
`;
const rowsSql = [...total].map(([k, [g, w]]) => `(:id, ${q(k)}, ${g}, ${w})`);
let body = runSql;
for (let i = 0; i < rowsSql.length; i += 2000) body += `insert into t1_private.limited_acc (run_id, k, g, w) values ${rowsSql.slice(i, i + 2000).join(",")};\n`;
await Deno.writeTextFile(out, body);
console.log(`${step} steps, ${totalRows} rows, ${total.size} keys, slowest ${worst.toFixed(0)} ms`);
