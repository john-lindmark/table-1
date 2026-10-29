// Discord signs every interaction with the application's Ed25519 key: X-Signature-Ed25519 over
// X-Signature-Timestamp + the raw body. Anything that doesn't verify is refused before it is parsed, and a
// timestamp more than five minutes off is refused too, so a captured request can't be replayed later.

const keys = new Map<string, Promise<CryptoKey>>();

export function hexToBytes(hex: string): Uint8Array<ArrayBuffer> {
  if (!/^[0-9a-fA-F]*$/.test(hex) || hex.length % 2) throw new Error("not hex");
  const out = new Uint8Array(new ArrayBuffer(hex.length / 2));
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function keyFor(publicKeyHex: string): Promise<CryptoKey> {
  let k = keys.get(publicKeyHex);
  if (!k) {
    k = crypto.subtle.importKey("raw", hexToBytes(publicKeyHex), { name: "Ed25519" }, false, ["verify"]);
    keys.set(publicKeyHex, k);
  }
  return k;
}

export const MAX_SKEW_SECONDS = 5 * 60;

/** True only for a well-formed, fresh, correctly signed request. Never throws. */
export async function verifyInteraction(
  publicKeyHex: string,
  signatureHex: string | null,
  timestamp: string | null,
  body: string,
  nowMs = Date.now(),
): Promise<boolean> {
  try {
    if (!publicKeyHex || !signatureHex || !timestamp) return false;
    if (!/^\d{1,12}$/.test(timestamp)) return false;
    if (Math.abs(nowMs / 1000 - Number(timestamp)) > MAX_SKEW_SECONDS) return false;
    const sig = hexToBytes(signatureHex);
    if (sig.length !== 64) return false;
    const key = await keyFor(publicKeyHex);
    const data = new TextEncoder().encode(timestamp + body);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, data);
  } catch {
    return false;
  }
}
