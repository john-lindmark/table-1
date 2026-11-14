#!/usr/bin/env node
// Uploads a release bundle to Google Play through the Play Developer API (androidpublisher v3),
// so a build doesn't have to be uploaded by hand in Play Console. No dependencies: Node 18+.
//
//   node apps/android/tools/play-upload.mjs --check
//       signs in and lists each track's current release (nothing changes)
//   node apps/android/tools/play-upload.mjs <bundle.aab> [--track internal] [--notes <file>]
//       [--name <release name>] [--status completed|draft] [--dry-run]
//
// --notes: a file with Play's "What's new" blocks (<en-US>…</en-US>, one per language, as in
//   table-1-context/docs/android-release-*.md), or plain text taken as en-US. 500 characters each.
// --dry-run: uploads into an edit, sets the track and validates, then throws the edit away.
//
// The key is a Google Cloud service account JSON key with release rights in Play Console
// (SETUP.md § 4 "Uploads from the command line"). Default path ~/.playconsole/table1-play.json,
// or T1_PLAY_KEY. Never print or copy its contents.

import { readFileSync, existsSync } from 'node:fs';
import { createHash, createSign } from 'node:crypto';
import { homedir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';

const PACKAGE = 'site.table1.events';
const API = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE}`;
const UPLOAD = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${PACKAGE}`;
const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

function die(msg) { console.error(msg); process.exit(1); }

function parseArgs(argv) {
  const o = { track: 'internal', status: 'completed', check: false, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => argv[++i] ?? die(`${a} needs a value`);
    if (a === '--check') o.check = true;
    else if (a === '--dry-run') o.dryRun = true;
    else if (a === '--track') o.track = val();
    else if (a === '--notes') o.notes = val();
    else if (a === '--name') o.name = val();
    else if (a === '--status') o.status = val();
    else if (a.startsWith('--')) die(`Unknown option ${a}`);
    else o.aab = a;
  }
  if (!o.check && !o.aab) die('Give a bundle (.aab) or --check. See the top of this file.');
  if (!['completed', 'draft'].includes(o.status)) die('--status is completed or draft');
  return o;
}

// "What's new": <en-US>…</en-US> blocks, else the whole file as en-US.
export function parseNotes(text) {
  const blocks = [...text.matchAll(/<([a-z]{2,3}(?:-[A-Z0-9]{2,3})?)>\s*([\s\S]*?)\s*<\/\1>/g)];
  const notes = blocks.length
    ? blocks.map(([, language, t]) => ({ language, text: t.trim() }))
    : [{ language: 'en-US', text: text.trim() }];
  for (const n of notes) {
    if (!n.text) die(`Release notes for ${n.language} are empty`);
    if ([...n.text].length > 500) die(`Release notes for ${n.language} are ${[...n.text].length} characters; Play takes 500`);
  }
  return notes;
}

const b64url = (buf) => Buffer.from(buf).toString('base64url');

async function accessToken(keyPath) {
  if (!existsSync(keyPath)) die(`No Play key at ${keyPath}. See SETUP.md § 4 "Uploads from the command line".`);
  const key = JSON.parse(readFileSync(keyPath, 'utf8'));
  if (key.type !== 'service_account' || !key.private_key || !key.client_email) die(`${keyPath} isn't a service account key`);
  const tokenUri = key.token_uri || 'https://oauth2.googleapis.com/token';
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({ iss: key.client_email, scope: SCOPE, aud: tokenUri, iat: now, exp: now + 3600 }));
  const signer = createSign('RSA-SHA256');
  signer.update(`${head}.${claims}`);
  const jwt = `${head}.${claims}.${b64url(signer.sign(key.private_key))}`;
  const res = await fetch(tokenUri, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.access_token) die(`Google refused the key (${res.status}): ${body.error_description || body.error || 'no token'}`);
  return { token: body.access_token, account: key.client_email };
}

class PlayError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function client(token) {
  return async function call(method, url, { json, body, headers = {} } = {}) {
    const res = await fetch(url, {
      method,
      headers: { authorization: `Bearer ${token}`, ...(json ? { 'content-type': 'application/json' } : {}), ...headers },
      body: json ? JSON.stringify(json) : body,
    });
    const text = await res.text();
    const data = text ? (() => { try { return JSON.parse(text); } catch { return { raw: text }; } })() : {};
    if (!res.ok) throw new PlayError(res.status, data.error?.message || data.raw || res.statusText);
    return data;
  };
}

// versionName from app/build.gradle.kts, for release names like "29907012 (0.1.0)".
function versionName() {
  try {
    const gradle = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'app', 'build.gradle.kts'), 'utf8');
    return gradle.match(/versionName\s*=\s*"([^"]+)"/)?.[1];
  } catch { return undefined; }
}

function describe(track) {
  const rs = track.releases || [];
  if (!rs.length) return `${track.track}: no release`;
  return rs.map((r) => `${track.track}: ${r.name || '(no name)'} · ${r.status} · versionCode ${(r.versionCodes || []).join(', ') || '-'}`).join('\n');
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const keyPath = process.env.T1_PLAY_KEY || join(homedir(), '.playconsole', 'table1-play.json');
  const notes = o.notes ? parseNotes(readFileSync(o.notes, 'utf8')) : null;
  let bundle, sha256;
  if (!o.check) {
    if (!existsSync(o.aab)) die(`No bundle at ${o.aab}`);
    bundle = readFileSync(o.aab);
    sha256 = createHash('sha256').update(bundle).digest('hex');
  }

  const { token, account } = await accessToken(keyPath);
  const call = client(token);
  console.log(`Signed in as ${account}`);

  let edit;
  try {
    edit = await call('POST', `${API}/edits`, { json: {} });
  } catch (e) {
    if (e.status === 401 || e.status === 403) die(`Play refused (${e.status}): ${e.message}\nInvite ${account} in Play Console → Users and permissions with release rights for Table 1.`);
    throw e;
  }
  const E = `${API}/edits/${edit.id}`;
  const discard = () => call('DELETE', E).catch(() => {});

  try {
    if (o.check) {
      const { tracks = [] } = await call('GET', `${E}/tracks`);
      for (const t of tracks) console.log(describe(t));
      await discard();
      console.log('Play API works; nothing changed.');
      return;
    }

    console.log(`Uploading ${o.aab} (${(bundle.length / 1048576).toFixed(1)} MB)…`);
    const up = await call('POST', `${UPLOAD}/edits/${edit.id}/bundles?uploadType=media`, {
      body: bundle, headers: { 'content-type': 'application/octet-stream' },
    });
    if (up.sha256 && up.sha256 !== sha256) throw new Error(`Play's sha256 ${up.sha256} doesn't match the file's ${sha256}`);
    const versionCode = String(up.versionCode);
    console.log(`Uploaded versionCode ${versionCode}`);

    const release = (status) => ({
      track: o.track,
      releases: [{
        name: o.name || (versionName() ? `${versionCode} (${versionName()})` : versionCode),
        versionCodes: [versionCode],
        status,
        ...(notes ? { releaseNotes: notes } : {}),
      }],
    });
    let status = o.status;
    await call('PUT', `${E}/tracks/${o.track}`, { json: release(status) });
    await call('POST', `${E}:validate`);

    if (o.dryRun) {
      await discard();
      console.log(`Dry run: versionCode ${versionCode} validated on ${o.track} (${status}); the edit was thrown away.`);
      return;
    }

    let query = '';
    for (let attempt = 0; ; attempt++) {
      try {
        await call('POST', `${E}:commit${query}`);
        break;
      } catch (e) {
        if (attempt < 2 && /draft app/i.test(e.message) && status !== 'draft') {
          // An app that has never been published takes draft releases only.
          status = 'draft';
          await call('PUT', `${E}/tracks/${o.track}`, { json: release(status) });
          continue;
        }
        if (attempt < 2 && /changesNotSentForReview/.test(e.message) && !query) {
          query = '?changesNotSentForReview=true';
          continue;
        }
        throw e;
      }
    }
    console.log(`Committed: versionCode ${versionCode} on ${o.track} as ${status}.`);
    if (status === 'draft') console.log('It is a draft: roll it out in Play Console → Testing → ' + o.track + ' (the app takes draft releases only until it is published).');
    if (query) console.log('Play held the changes for review: send them in Play Console → Publishing overview.');
  } catch (e) {
    await discard();
    die(`Play API failed${e.status ? ` (${e.status})` : ''}: ${e.message}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch((e) => die(e.stack || String(e)));
}
