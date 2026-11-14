// Alert text for leagues (contract/public-events-leagues-2026-11-13.md § Notifications). The league's name is the
// title; the app opens the league (league.event opens the event). No dates in the text: the worker doesn't know the
// reader's time zone, and the app shows the day.
const text = (v: unknown, fallback = ""): string => (typeof v === "string" && v.trim() ? v.trim() : fallback);

function title(d: Record<string, unknown>): string {
  const league = text(d.league_name, "A league you follow");
  const season = text(d.season_name);
  // "MMS 2026", but not "Friday Night 2026 2026" when the league's name already ends with the season.
  return season && !league.endsWith(season) ? `${league} · ${season}` : league;
}

export function leagueCopy(kind: string, d: Record<string, unknown>): { title: string; body: string } {
  const event = text(d.event_name, "An event");
  switch (kind) {
    case "league.event": {
      const parts = [event, text(d.format_label), text(d.venue_name)].filter((p, i, all) => p && all.indexOf(p) === i);
      return { title: title(d), body: `${d.final === true ? "The final is set" : "New event"}: ${parts.join(" · ")}` };
    }
    case "league.results": {
      const winner = text(d.winner);
      return { title: title(d), body: winner ? `${winner} won ${event}. Standings are updated.` : `${event} is in. Standings are updated.` };
    }
    case "league.qualified":
      return {
        title: title(d),
        body: d.how === "points" ? "You qualified for the final on points." : `You qualified for the final by winning ${event}.`,
      };
    default: {  // league.season
      const first = text(d.first);
      return { title: title(d), body: first ? `The season is over. ${first} finished first.` : "The season is over. Final standings are up." };
    }
  }
}

/** A new public event that fits your alert (contract/teams-finals-alerts-2026-11-13.md § Alerts); the app opens it. */
export function publicNewCopy(d: Record<string, unknown>): { title: string; body: string } {
  const format = text(d.format_label).split(" · ")[0];
  const parts = [text(d.event_name, "A new event"), text(d.venue_name)].filter(Boolean);
  return { title: `New ${format ? `${format} ` : ""}event${d.near === true ? " near you" : ""}`, body: parts.join(" · ") };
}

/** A table calls a judge (contract/room-tools-2026-11-13.md § Judge calls): to the organizers; the app opens the event. */
export function judgeCallCopy(d: Record<string, unknown>): { title: string; body: string } {
  const table = Number(d.table_number ?? 0);
  const parts = [text(d.event_name), text(d.by)].filter(Boolean);
  return { title: table > 0 ? `Judge! Table ${table}` : "Judge!", body: parts.join(" · ") || "A table is calling a judge." };
}
