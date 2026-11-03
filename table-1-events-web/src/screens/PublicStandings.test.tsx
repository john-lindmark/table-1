import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { PublicStandings, SignUpPage } from "./PublicStandings";
import { toPublicEvent } from "../lib/api";
import pub from "../../../testdata/event-bundle/public.json";

// /s/<event> is the link organizers, the sign-up link and the Discord card share. People land on it from outside
// the app, so it must always offer a way back (home when nothing came before); it had none on phones.
const html = (node: JSX.Element) => renderToStaticMarkup(<MemoryRouter>{node}</MemoryRouter>);
const back = () => {};

describe("public event page", () => {
  it("leads with Back while loading", () => {
    expect(html(<PublicStandings eventId="E1" onBack={back} />)).toContain('aria-label="Back"');
  });

  it("leads with Back on the sign-up page", () => {
    const event = { ...toPublicEvent(pub), signUp: "open" as const, currentRound: 0 };
    // The page reads ?signup from the address; tests run without a DOM.
    Object.assign(globalThis, { window: { location: { search: "" } } });
    expect(html(<SignUpPage event={event} reload={async () => {}} onBack={back} />)).toContain('aria-label="Back"');
  });
});
