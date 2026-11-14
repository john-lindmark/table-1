import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { VIS_LABEL, VISIBILITIES, asks, reach, type Sharing, type Visibility, type Widening } from "../lib/friends";
import {
  achievementPath, achievementText, achievementsVisibilitySet, demoPath, leaderboardsListedSet, leaguesError, profileAchievements,
  type Achievement, type Achievements, type AchievementsVisibility,
} from "../lib/leagues";
import { capture } from "../lib/telemetry";
import { Notice, Row, Segmented } from "./kit";

/* Achievements on profiles and their sharing (contract/public-events-leagues-2026-11-13.md §§ 4, 7). Nothing is
   stored: a profile's tiles are read from the league standings and the format boards each time. A failed or missing
   call (the server part isn't live yet) draws nothing, here and in Sharing. */

/** A profile's achievements, read once per profile; null until read or when there are none to read. */
export function useAchievements(userId: string | null | undefined, version: unknown = 0): Achievements | null {
  const [a, setA] = useState<Achievements | null>(null);
  useEffect(() => {
    setA(null);
    if (!userId) return;
    let live = true;
    void profileAchievements(userId).then((r) => live && setA(r));
    return () => { live = false; };
  }, [userId, version]);
  return a;
}

const keyOf = (i: Achievement) => (i.kind === "board" ? `b:${i.board}` : `l:${i.season_id}`);

/**
 * The row of small tiles under a profile's name and record: a code over a label, scrolling sideways. The accent
 * outline marks a champion and a first place, nothing else. A league tile opens the league on that season, a board
 * tile the board. No tiles, no section.
 */
export function AchievementTiles({ items }: { items: Achievement[] | null | undefined }) {
  if (!items?.length) return null;
  return (
    <div className="bg-t1-bg flex gap-px overflow-x-auto [scrollbar-width:none]" role="list" aria-label="Achievements">
      {items.map((i) => {
        const t = achievementText(i);
        return (
          <Link key={keyOf(i)} to={demoPath(achievementPath(i))} role="listitem" state={{ from: "profile" }} onClick={() => capture("achievement_opened", { kind: i.kind })}
                aria-label={`${t.code}, ${t.label}`}
                className={`shrink-0 min-w-[104px] max-w-[280px] h-[62px] px-4 bg-t1-surface hover:bg-t1-surface-hover flex flex-col justify-center gap-1 ${
                  t.accent ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}>
            <span className="text-[13px] leading-[16px] uppercase tracking-[1.5px] tabular-nums truncate">{t.code}</span>
            <span className="text-[9px] leading-[12px] uppercase tracking-[1.5px] text-t1-muted truncate">{t.label}</span>
          </Link>
        );
      })}
    </div>
  );
}

/** A profile's tiles, read for `userId`. `hidden` (View as, when the part wouldn't reach that viewer) draws nothing. */
export function ProfileAchievements({ userId, hidden }: { userId: string | null | undefined; hidden?: boolean }) {
  const a = useAchievements(hidden ? null : userId);
  return hidden ? null : <AchievementTiles items={a?.items} />;
}

/** Whether your achievements reach a viewer at `level` (1 a friend, 0 anyone), the profile capping the part. */
export const achievementsReach = (s: Sharing, v: AchievementsVisibility, level: number) => level >= asks(reach(s, v));

const WHAT = "your league finishes and board ranks";

/**
 * Account → Sharing: Leaderboards (Listed | Hidden) and Achievements (Private | Friends | Anyone), after Rankings.
 * Both read from your own profile's achievements; until that answers (or when the server part isn't live) neither
 * draws. Widening Achievements asks first, like every other part.
 */
export function AchievementsSharing({ userId, settings, ask }: {
  userId: string | null; settings: Sharing; ask: (w: Widening, apply: () => void) => void;
}) {
  const [a, setA] = useState<Achievements | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!userId) return;
    let live = true;
    void profileAchievements(userId).then((r) => live && setA(r));
    return () => { live = false; };
  }, [userId]);
  if (!a || a.visibility == null) return null;
  const vis = a.visibility;
  const listed = a.listed !== false;
  const eff = reach(settings, vis);
  const setVis = (v: AchievementsVisibility) => {
    if (v === vis) return;
    const to = reach(settings, v);
    const widens = asks(to) < asks(eff);
    const w: Widening = { friends: widens && to === "friends" ? [WHAT] : [], anyone: widens && to === "public" ? [WHAT] : [],
                          all_cards_to_anyone: false, profile_to_anyone: false };
    ask(w, () => {
      setA({ ...a, visibility: v });   // shows at once; put back if the server refuses
      achievementsVisibilitySet(v).then((r) => { setA((x) => (x ? { ...x, visibility: r.visibility } : x)); setError(null); },
                                        (e) => { setA((x) => (x ? { ...x, visibility: vis } : x)); setError(leaguesError(e)); });
    });
  };
  const setListed = (next: boolean) => {
    if (next === listed) return;
    setA({ ...a, listed: next });
    leaderboardsListedSet(next).then((r) => { setA((x) => (x ? { ...x, listed: r.listed } : x)); setError(null); },
                                     (e) => { setA((x) => (x ? { ...x, listed } : x)); setError(leaguesError(e)); });
  };
  return (
    <>
      <div className="flex flex-col gap-px">
        <Row title="Achievements" detail="League finishes and board ranks" value={VIS_LABEL[vis as Visibility]} accentValue={vis !== "private"} />
        <Segmented options={VISIBILITIES.map((v) => ({ value: v as string, label: VIS_LABEL[v] }))} value={vis} onChange={(v) => setVis(v as AchievementsVisibility)} />
        {asks(settings.profile) > asks(vis) && (
          <Notice tone="info">Shows to {eff === "friends" ? "friends" : "you"} only: your profile is {VIS_LABEL[settings.profile].toLowerCase()}.</Notice>
        )}
      </div>
      <div className="flex flex-col gap-px">
        <Row title="Leaderboards" detail="You on the format boards" value={listed ? "Listed" : "Hidden"} accentValue={listed} />
        <Segmented options={[{ value: "listed", label: "Listed" }, { value: "hidden", label: "Hidden" }]} value={listed ? "listed" : "hidden"}
                   onChange={(v) => setListed(v === "listed")} />
        <Notice tone="info">Your results in public events count either way.</Notice>
      </div>
      {error && <Notice tone="error">{error}</Notice>}
    </>
  );
}
