// Alert text for `insights.new` (contract/insights-2026-10-24.md § New in Insights): something Insights didn't have.
// `data` comes from t1_private.insights_announce: insights_section (constructed / limited), insights_key, name and
// what (data: its first pack; rank: a new set to rank before its draft data).

export function insightsNewCopy(d: Record<string, unknown>): { title: string; body: string } {
  const name = String(d.name ?? d.insights_key ?? "Something new");
  if (d.what === "rank") return { title: "New set to rank", body: `${name} is out. Rank its cards and compare with your friends.` };
  if (d.insights_section === "constructed") {
    return { title: "New in Insights", body: `${name} is in Insights: the metagame, matchups and decklists.` };
  }
  const cube = /\bcube\b/i.test(name);
  return { title: "New in Insights", body: `${name}: draft data from 17Lands is in. See the best ${cube ? "cards" : "cards and color pairs"}.` };
}
