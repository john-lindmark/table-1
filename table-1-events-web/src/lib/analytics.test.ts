import { describe, expect, it } from "vitest";
import { redactPath } from "./analytics";

describe("redactPath", () => {
  it("strips the join code so it never reaches analytics", () => {
    expect(redactPath("/join/ABCD")).toBe("/join/:id");
  });

  it("strips event ids from every event-scoped route", () => {
    expect(redactPath("/e/8f3c1d2e-0000-4000-8000-000000000000")).toBe("/e/:id");
    expect(redactPath("/p/8f3c1d2e-0000-4000-8000-000000000000")).toBe("/p/:id");
    expect(redactPath("/s/8f3c1d2e-0000-4000-8000-000000000000")).toBe("/s/:id");
  });

  it("leaves paths without an identifier alone", () => {
    expect(redactPath("/")).toBe("/");
    expect(redactPath("/join")).toBe("/join");
  });

  it("does not redact a path that merely starts with the same letters", () => {
    expect(redactPath("/events/list")).toBe("/events/list");
  });
});
