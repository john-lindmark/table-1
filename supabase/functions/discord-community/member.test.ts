import { assertEquals } from "jsr:@std/assert@1";
import { isSnowflake, memberFrom } from "./member.ts";

Deno.test("membership: only a member answer or an unknown member/user decides", () => {
  assertEquals(memberFrom(200, { }), true);
  assertEquals(memberFrom(404, { code: 10007 }), false, "Unknown Member");
  assertEquals(memberFrom(404, { code: 10013 }), false, "Unknown User");
  assertEquals(memberFrom(404, { code: 10004 }), null, "Unknown Guild: the bot isn't in the server, so we don't know");
  assertEquals(memberFrom(404, null), null);
  assertEquals(memberFrom(403, { code: 50001 }), null, "Missing Access");
  assertEquals(memberFrom(429, null), null, "rate limited");
  assertEquals(memberFrom(500, null), null);
});

Deno.test("ids: only Discord snowflakes are asked about", () => {
  assertEquals(isSnowflake("1565392011295465522"), true);
  assertEquals(isSnowflake(null), false);
  assertEquals(isSnowflake(""), false);
  assertEquals(isSnowflake("12/34"), false);
  assertEquals(isSnowflake(1565392011295465522), false);
});
