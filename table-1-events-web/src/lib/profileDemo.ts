import type { AccountOverview } from "./types";

/** The Account screen on sample results (dev server, `?demo`): a record and head-to-head for the feature-spot shot
 *  (marketing/bundle/spots/spots.json `record`). Nothing here is a real person. */
export const DEMO_OVERVIEW: AccountOverview = {
  profile: { id: "demo", display_name: "Sam Reyes", handle: null },
  record: {
    match_wins: 61, match_losses: 38, match_draws: 3, byes: 4,
    game_wins: 141, game_losses: 97, game_draws: 2, events_played: 24,
  },
  head_to_head: [
    { opponent_id: "d0000000-0000-0000-0000-0000000f0001", name: "Mara Quinn", match_wins: 6, match_losses: 4, match_draws: 0, game_wins: 14, game_losses: 10, played: 10 },
    { opponent_id: "d0000000-0000-0000-0000-0000000f0002", name: "Theo Alvarez", match_wins: 3, match_losses: 5, match_draws: 1, game_wins: 9, game_losses: 12, played: 9 },
    { opponent_id: "d0000000-0000-0000-0000-0000000f0003", name: "Priya Natarajan", match_wins: 5, match_losses: 2, match_draws: 0, game_wins: 11, game_losses: 5, played: 7 },
    { opponent_id: "d0000000-0000-0000-0000-0000000f0004", name: "Jonas Berg", match_wins: 2, match_losses: 4, match_draws: 0, game_wins: 6, game_losses: 9, played: 6 },
    { opponent_id: "d0000000-0000-0000-0000-0000000f0005", name: "Lena Fischer", match_wins: 4, match_losses: 1, match_draws: 0, game_wins: 8, game_losses: 3, played: 5 },
  ],
};
