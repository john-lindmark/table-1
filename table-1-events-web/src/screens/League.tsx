import { Suspense, lazy, useCallback, useEffect, useRef, useState } from "react";
import { Link, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { Avatar } from "../components/Avatar";
import { LinkedText } from "../components/EventListing";
import { FilterRow } from "../components/FilterRow";
import { BAR_ICON, Icon, IconButton, ListIcon, TuneIcon } from "../components/icons";
import { Bar, Columns, GhostAction, Menu, Notice, Screen, Section, SwitchRow } from "../components/kit";
import {
  demoPath, finishLine, isMissing, leagueEventLine, leagueFollowSet, leaguePlayer, leagueStandings, leagueView, leaguesDemoOn, leaguesError,
  orderedLeagueEvents, pointsWords, qualifyWords, seasonLine, standingLine,
  type LeagueEvent, type LeaguePlayer, type LeagueView, type StandingRow,
} from "../lib/leagues";
import { useBack } from "../lib/nav";
import { leagueMoney, money as dollars, type LeagueMoney } from "../lib/money";
import { capture } from "../lib/telemetry";
import { useSession } from "../lib/useSession";

/* A league (contract/public-events-leagues-2026-11-13.md § 3 Clients): /league/<slug>, signed in or out. Opens on the
   standings of a season (`?season=<id>`); the whole table, a player's season, the details and the organizer's tools
   are each one tap deeper (`?view=…`, `?player=<key>`), so Back and a shared link land where they should. */

const LeagueTools = lazy(() => import("./LeagueTools").then((m) => ({ default: m.LeagueTools })));

const STANDINGS_PAGE = 100;

function Failed({ error, retry }: { error: unknown; retry: () => void }) {
  return (
    <>
      <Notice tone={isMissing(error) ? "info" : "error"}>{leaguesError(error)}</Notice>
      <div className="flex"><GhostAction label="Try again" onClick={retry} /></div>
    </>
  );
}

/** rank · name · points, `Q` in accent for the qualified; your own row in the accent outline. */
function StandingLine({ row, mine, onOpen }: { row: StandingRow; mine?: boolean; onOpen: () => void }) {
  return (
    <button type="button" onClick={onOpen} aria-label={`${row.rank}. ${row.name}, ${row.points} points${row.qualified ? ", qualified" : ""}`}
            className={`bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3 text-left w-full ${mine ? "outline outline-1 -outline-offset-1 outline-t1-accent" : ""}`}>
      <span className="w-7 shrink-0 text-[13px] tabular-nums text-t1-muted">{row.rank}</span>
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        <span className="text-[14px] truncate">{row.name}</span>
        <span className="t1-label truncate">{standingLine(row)}</span>
      </span>
      {row.qualified && <span className="shrink-0 t1-label text-t1-accent!" title={row.qualified === "winner" ? "Qualified by winning an event" : "Qualified on points"}>Q</span>}
      <span className="shrink-0 w-10 text-right text-[15px] tabular-nums">{row.points}</span>
    </button>
  );
}

function EventLine({ e }: { e: LeagueEvent }) {
  return (
    <Link to={demoPath(`/s/${e.event_id}`)} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex flex-col gap-0.5">
      <span className="text-[14px] truncate">{e.name}</span>
      <span className="t1-label truncate">{leagueEventLine(e)}</span>
    </Link>
  );
}

export function LeagueScreen({ league, onBack }: { league: string; onBack: () => void }) {
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  const real = useSession();
  const signedIn = !!real.session || leaguesDemoOn();
  const seasonId = params.get("season");
  const view = params.get("view");
  const playerKey = params.get("player");
  const [data, setData] = useState<LeagueView | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [menu, setMenu] = useState<"follow" | "tools" | null>(null);
  const [followError, setFollowError] = useState<string | null>(null);
  // The season's prize pool from its cut of each entry (contract/entry-fees-2026-11-13.md § 5); null while the server has none.
  const [pool, setPool] = useState<LeagueMoney | null>(null);
  const shownSeason = data?.season?.id ?? null;
  useEffect(() => {
    setPool(null);
    if (!shownSeason) return;
    let live = true;
    void leagueMoney(shownSeason).then((m) => live && setPool(m));
    return () => { live = false; };
  }, [shownSeason]);
  const here = `/league/${league}`;
  const backToLeague = useBack(seasonId ? `${here}?season=${seasonId}` : here);

  // Where the page was opened from (find, event, profile), else a link; counted once.
  const from = (useLocation().state as { from?: string } | null)?.from ?? "link";
  const counted = useRef(false);
  const load = useCallback(async () => {
    try {
      setData(await leagueView(league, seasonId));
      if (!counted.current) {
        counted.current = true;
        capture("league_opened", { from });
      }
      setError(null);
    } catch (e) {
      setError(e);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [league, seasonId]);
  useEffect(() => void load(), [load]);

  /** One tap deeper, keeping the season. */
  const go = (next: Record<string, string>) => {
    const q = new URLSearchParams(seasonId ? { season: seasonId } : {});
    for (const [k, v] of Object.entries(next)) q.set(k, v);
    navigate(demoPath(`${here}?${q.toString()}`));
  };

  const follow = (on: boolean, notify: boolean | null = null) => {
    setMenu(null);
    setFollowError(null);
    leagueFollowSet(data!.league.id, on, notify)
      .then((r) => setData((d) => (d ? { ...d, me: { ...d.me, ...r } } : d)))
      .catch((e) => setFollowError(leaguesError(e)));
  };

  if (error && !data) {
    return (
      <Screen>
        <Bar title="League" onBack={onBack} />
        <Failed error={error} retry={() => void load()} />
      </Screen>
    );
  }
  if (!data) {
    return (
      <Screen>
        <Bar title="League" onBack={onBack} />
        <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>
      </Screen>
    );
  }

  const { league: l, me, season, seasons } = data;
  if (playerKey && season) return <PlayerSeason seasonId={season.id} seasonName={season.name} playerKey={playerKey} leagueName={l.name} onBack={backToLeague} />;
  if (view === "standings" && season) {
    return <AllStandings data={data} onBack={backToLeague} onPlayer={(key) => go({ player: key })} />;
  }
  if (view === "details") return <Details data={data} signedIn={signedIn} onBack={backToLeague} onNotify={(on) => follow(true, on)} error={followError} />;
  if (view && me.role && ["edit", "seasons", "season", "organizers", "dues"].includes(view)) {
    return (
      <Suspense fallback={<Screen><Bar title={l.name} onBack={backToLeague} /></Screen>}>
        <LeagueTools data={data} view={view} seasonId={params.get("sid")} onBack={backToLeague}
                     go={(v, sid) => go(sid ? { view: v, sid } : { view: v })}
                     onArchived={() => navigate(demoPath("/find?tab=leagues"), { replace: true })}
                     onChanged={(slug) => (slug && slug !== league ? navigate(demoPath(`/league/${slug}`), { replace: true }) : void load())} />
      </Suspense>
    );
  }

  const events = orderedLeagueEvents(data.events);
  return (
    <Screen>
      <Bar title={l.name} onBack={onBack} right={
        <div className="shrink-0 flex items-center">
          {signedIn && !me.role && (
            <FollowButton following={me.following} onTap={() => follow(!me.following)} onHold={() => me.following && setMenu("follow")} />
          )}
          <IconButton label="Details" onClick={() => go({ view: "details" })}><ListIcon /></IconButton>
          {me.role && <IconButton label="League settings" onClick={() => setMenu("tools")}><TuneIcon /></IconButton>}
        </div>
      } />
      {followError && <Notice tone="error">{followError}</Notice>}
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        <div className="bg-t1-bg px-4 pt-6 pb-5 flex flex-col gap-1.5">
          <p className="text-[22px] leading-[28px] tracking-[0.5px] break-words">{l.name}</p>
          {(l.region || season) && (
            <p className="t1-label">{[l.region, season ? seasonLine(season) : null].filter(Boolean).join(" · ")}</p>
          )}
          {pool && pool.entry_cut_cents > 0 && (
            <p className="t1-label">Prize pool <span className="text-t1-text text-[13px] tracking-[1px]">{dollars(pool.pool_cents)}</span></p>
          )}
        </div>
        {seasons.length > 1 && season && (
          <FilterRow telemetry={() => {}} cells={[{
            name: "Season", value: season.name, current: season.id,
            options: seasons.map((s) => ({ value: s.id, label: s.name, detail: seasonLine(s) })),
            onPick: (id) => setParams(leaguesDemoOn() ? { season: id, demo: "" } : { season: id }, { replace: true }),
          }]} />
        )}
        {/* Desktop: the standings on the left, the season's events on the right; a phone stacks them. */}
        <Columns aside={(events.upcoming.length > 0 || events.finished.length > 0) ? (
          <>
            <Section title="Events" />
            {events.upcoming.map((e) => <EventLine key={e.event_id} e={e} />)}
            {events.finished.map((e) => <EventLine key={e.event_id} e={e} />)}
          </>
        ) : undefined}>
        {!season && <Notice tone="info">No season yet.</Notice>}
        {season && data.standings.length === 0 && <div className="bg-t1-surface px-4 py-6 t1-label">No results yet</div>}
        {data.my_row && <StandingLine row={data.my_row} mine onOpen={() => { capture("league_player_opened"); go({ player: data.my_row!.key }); }} />}
        {data.standings.slice(0, 10).map((r) => (
          <StandingLine key={r.key} row={r} onOpen={() => { capture("league_player_opened"); go({ player: r.key }); }} />
        ))}
        {data.standings_count > 10 && (
          <button type="button" onClick={() => go({ view: "standings" })}
                  className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center justify-between gap-3 text-left w-full">
            <span className="text-[13px]">All {data.standings_count}</span>
            <Icon d={BAR_ICON.arrow} />
          </button>
        )}
        </Columns>
      </div>
      {menu === "follow" && (
        <Menu title={l.name} onClose={() => setMenu(null)} items={[
          { title: me.notify ? "Notifications off" : "Notifications on", onClick: () => follow(true, !me.notify) },
          { title: "Unfollow", onClick: () => follow(false) },
        ]} />
      )}
      {menu === "tools" && (
        <Menu title={l.name} onClose={() => setMenu(null)} items={[
          { title: "Edit league", onClick: () => go({ view: "edit" }) },
          { title: "Seasons", detail: seasons.length ? seasons.map((s) => s.name).join(" · ") : "None yet", onClick: () => go({ view: "seasons" }) },
          { title: "Organizers", detail: (data.members?.map((m) => m.name) ?? l.organizers).join(", "), onClick: () => go({ view: "organizers" }) },
          ...(pool?.events ? [{ title: "Dues", detail: `${dollars(pool.received_cents ?? 0)} of ${dollars(pool.pool_cents)} received`, onClick: () => go({ view: "dues" }) }] : []),
        ]} />
      )}
    </Screen>
  );
}

/** Follow / Following in the bar: a tap toggles, a long press (or right-click) opens the notifications menu. */
function FollowButton({ following, onTap, onHold }: { following: boolean; onTap: () => void; onHold: () => void }) {
  const timer = useRef<number | null>(null);
  const held = useRef(false);
  const cancel = () => { if (timer.current != null) { window.clearTimeout(timer.current); timer.current = null; } };
  useEffect(() => cancel, []);
  return (
    <button type="button" aria-pressed={following}
            onPointerDown={() => { held.current = false; timer.current = window.setTimeout(() => { held.current = true; timer.current = null; onHold(); }, 450); }}
            onPointerUp={cancel} onPointerLeave={cancel} onPointerCancel={cancel}
            onContextMenu={(e) => { e.preventDefault(); cancel(); held.current = true; onHold(); }}
            onClick={() => { if (held.current) { held.current = false; return; } onTap(); }}
            className={`shrink-0 h-[30px] px-2.5 mr-1 text-[11px] uppercase tracking-[1.5px] ${
              following ? "outline outline-1 -outline-offset-1 outline-t1-accent text-t1-text" : "bg-t1-bg text-t1-text hover:bg-t1-surface-hover"}`}>
      {following ? "Following" : "Follow"}
    </button>
  );
}

/** All N: the whole table, a page at a time. */
function AllStandings({ data, onBack, onPlayer }: { data: LeagueView; onBack: () => void; onPlayer: (key: string) => void }) {
  const season = data.season!;
  const [rows, setRows] = useState<StandingRow[]>(data.standings);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const more = async () => {
    setBusy(true);
    try {
      const next = await leagueStandings(season.id, rows.length, STANDINGS_PAGE);
      setRows((r) => [...r, ...next]);
      setError(null);
    } catch (e) {
      setError(e);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Screen>
      <Bar title={`${data.league.name} · ${season.name}`} onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {rows.map((r) => (
          <StandingLine key={r.key} row={r} mine={r.key === data.my_row?.key} onOpen={() => { capture("league_player_opened"); onPlayer(r.key); }} />
        ))}
        {error != null && <Notice tone="error">{leaguesError(error)}</Notice>}
        {rows.length < data.standings_count && (
          <div className="flex"><GhostAction label={busy ? "Loading…" : `More · ${rows.length} of ${data.standings_count}`} disabled={busy} onClick={() => void more()} /></div>
        )}
      </div>
    </Screen>
  );
}

/** A player's season: their points large, then each event with place and points (`·` marks a result outside best N). */
function PlayerSeason({ seasonId, seasonName, playerKey, leagueName, onBack }: {
  seasonId: string; seasonName: string; playerKey: string; leagueName: string; onBack: () => void;
}) {
  const [p, setP] = useState<LeaguePlayer | null>(null);
  const [error, setError] = useState<unknown>(null);
  const load = useCallback(async () => {
    try {
      setP(await leaguePlayer(seasonId, playerKey));
      setError(null);
    } catch (e) {
      setError(e);
    }
  }, [seasonId, playerKey]);
  useEffect(() => void load(), [load]);
  const row = p?.player;
  return (
    <Screen>
      <Bar title={row?.name ?? "Player"} onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {error ? <Failed error={error} retry={() => void load()} /> : !p || !row ? <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div> : (
          <>
            <div className="bg-t1-bg px-4 py-6 flex flex-col items-center gap-1">
              <Avatar name={row.name} userId={row.user_id} size={60} opens="league" />
              <p className="t1-label mt-3">{leagueName} · {seasonName}</p>
              <p className="text-[48px] leading-[56px] tabular-nums tracking-[4px] text-t1-accent">{row.points}</p>
              <p className="t1-label text-center">#{row.rank} · {standingLine(row)}</p>
              {row.qualified && (
                <p className="t1-label text-center text-t1-accent!">{row.qualified === "winner" ? "Qualified · won an event" : "Qualified · on points"}</p>
              )}
            </div>
            {p.events.map((e) => (
              <Link key={e.event_id} to={demoPath(`/s/${e.event_id}`)} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3">
                <span className="flex-1 min-w-0 flex flex-col gap-0.5">
                  <span className="text-[14px] truncate">{e.name}</span>
                  <span className="t1-label truncate">{finishLine(e)}</span>
                </span>
                <span className={`shrink-0 text-[15px] tabular-nums ${e.counted ? "" : "text-t1-muted"}`}
                      aria-label={e.counted ? `${e.points} points` : `${e.points} points, not counted`}>
                  {e.counted ? e.points : `· ${e.points}`}
                </span>
              </Link>
            ))}
          </>
        )}
      </div>
    </Screen>
  );
}

function Fact({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="bg-t1-surface px-4 py-3 flex items-baseline gap-4">
      <span className="t1-label w-[104px] shrink-0">{label}</span>
      <span className="flex-1 min-w-0 text-[13px] leading-[19px] text-right break-words">{children}</span>
    </div>
  );
}

/** The details behind the list icon: description, region, link, organizers, the points rule and qualification in words. */
function Details({ data, signedIn, onBack, onNotify, error }: {
  data: LeagueView; signedIn: boolean; onBack: () => void; onNotify: (on: boolean) => void; error: string | null;
}) {
  const { league: l, season, me } = data;
  return (
    <Screen>
      <Bar title={l.name} onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {l.description?.trim() && <div className="bg-t1-surface px-4 py-4"><LinkedText text={l.description} /></div>}
        {l.region && <Fact label="Region">{l.region}</Fact>}
        {l.link && (
          <Fact label="Link">
            <a href={l.link} target="_blank" rel="noopener noreferrer nofollow" className="underline underline-offset-2 hover:text-t1-accent break-all">
              {l.link.replace(/^https:\/\//, "")}
            </a>
          </Fact>
        )}
        {l.organizers.length > 0 && <Fact label="Organizers">{l.organizers.join(", ")}</Fact>}
        {season && (
          <>
            <Section title={season.name} />
            <Fact label="Dates">{seasonLine(season)}</Fact>
            <Fact label="Points">{pointsWords(season.points)}</Fact>
            {season.best_n != null && <Fact label="Counts">Best {season.best_n} results</Fact>}
            {qualifyWords(season.qualify) && <Fact label="Qualify">{qualifyWords(season.qualify)}</Fact>}
          </>
        )}
        {signedIn && me.following && !me.role && (
          <SwitchRow label="Notifications" on={me.notify} onChange={onNotify} />
        )}
        {error && <Notice tone="error">{error}</Notice>}
      </div>
    </Screen>
  );
}
