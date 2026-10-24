import { describe, expect, it } from "vitest";
import { googleAuthUrl, readGoogleReturn, safeReturn, sha256Hex, type GoogleRequest } from "./googleSignIn";

/* Google sign-in straight to Google (contract/web-google-sign-in-2026-10-23.md). */

const request: GoogleRequest = { nonce: "raw-nonce", state: "s1", returnTo: "/library?x=1" };

describe("google sign-in", () => {
  it("asks Google for an ID token returned to this origin, with the hashed nonce", () => {
    const u = new URL(googleAuthUrl({ clientId: "c.apps", origin: "https://table-1.site", state: "s1", hashedNonce: "h" }));
    expect(u.origin + u.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(Object.fromEntries(u.searchParams)).toEqual({
      client_id: "c.apps",
      redirect_uri: "https://table-1.site/auth/google",
      response_type: "id_token",
      scope: "openid email profile",
      nonce: "h",
      state: "s1",
      prompt: "select_account",
    });
  });

  it("hashes the nonce the way Supabase checks it (hex SHA-256)", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });

  it("hands the token and the raw nonce on, back to the page that asked", () => {
    expect(readGoogleReturn("#state=s1&id_token=tok&authuser=0", request)).toEqual({
      kind: "token",
      idToken: "tok",
      nonce: "raw-nonce",
      returnTo: "/library?x=1",
    });
  });

  it("treats a declined consent as cancelled", () => {
    expect(readGoogleReturn("#error=access_denied&state=s1", request)).toEqual({ kind: "cancelled", returnTo: "/library?x=1" });
  });

  it("refuses a return this tab didn't ask for", () => {
    expect(readGoogleReturn("#state=other&id_token=tok", request).kind).toBe("error");
    expect(readGoogleReturn("#state=s1&id_token=tok", null).kind).toBe("error");
    expect(readGoogleReturn("#state=s1", request).kind).toBe("error");
    expect(readGoogleReturn("#state=s1&error=invalid_request", request).kind).toBe("error");
  });

  it("returns to same-origin paths only", () => {
    expect(safeReturn("/p/E1")).toBe("/p/E1");
    expect(safeReturn("//evil.example/x")).toBe("/");
    expect(safeReturn("https://evil.example")).toBe("/");
    expect(safeReturn(undefined)).toBe("/");
  });
});
