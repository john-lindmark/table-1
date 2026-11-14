import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Bar, BigAction, ClockFace, Dialog, GhostAction, Notice, PodHeader, Screen, TabBar } from "../components/kit";
import { matchCount, podSections, type PodRef } from "../lib/draftPods";
import { SignInButtons } from "../components/SignInButtons";
import {
  errorMessage,
  fetchPublicEvent,
  fetchPublicStandingsAndBracket,
  leaveEvent,
  signUpForEvent,
  subscribeToEvent,
  type PublicBracketStage,
  type PublicEvent,
  type PublicPairing,
  type PublicStandingRow,
} from "../lib/api";
import { formatPct } from "../lib/standings";
import { fetchEventFollow, matchScore, roundTitle, setEventFollow, type EventFollow } from "../lib/eventFollows";
import { pageButton, roundName, roundsLine, signUpLine, when } from "../lib/scheduledEvents";
import { capture } from "../lib/telemetry";
import { useSession } from "../lib/useSession";
import { EventAboutRows, PublicResultsNotice, useEventAbout } from "../components/EventListing";
import { leaguesDemoOn, type EventAbout } from "../lib/leagues";
import { getLocalParticipant } from "../lib/session";
import { PayBlock, PrizePoolRow, feeFact, useEventMoney } from "../components/EventMoney";
import { TeamBracketView } from "../components/EventExtras";
import { TeamSignupBlock, TeamsList, teamCodeInAddress, useTeamMine } from "../components/TeamSignup";
import type { PublicTeamBracketStage } from "../lib/api";
import type { EventMoney } from "../lib/money";
import type { TeamMine } from "../lib/teamSignup";

/**
 * One link for the event's whole life (contract/scheduled-events-2026-10-27.md §4): before round 1 the sign-up page,
 * then the standings. Read-only, no sign-in. This is the link people share (contract/privacy-lockdown-2026-10-18.md): event_public
 * gives the event, the clock and current pairings by name, and events-engine the ranked standings. No player list
 * or account ids reach this page; a private event reads "That event isn't available".
 * People land here from a shared link, so every state leads with Back: home when the tab has nothing earlier in the app.
 */
export function PublicStandings({ eventId, onBack }: { eventId: string; onBack: () => void }) {
  const [event, setEvent] = useState<PublicEvent | null>(null);
  const [rows, setRows] = useState<PublicStandingRow[] | null>(null);
  const [bracket, setBracket] = useState<PublicBracketStage[]>([]);
  const [teamBracket, setTeamBracket] = useState<PublicTeamBracketStage[]>([]);
  const [pods, setPods] = useState<PodRef[]>([]);
  const [tab, setTab] = useState<"standings" | "matchups">("standings");
  const [error, setError] = useState<string | null>(null);
  // Description, address and league (contract/public-events-leagues-2026-11-13.md § 1); nothing until the server has them.
  const about = useEventAbout(eventId, getLocalParticipant(eventId)?.token);
  // Dev server, `?demo`: a found event's page on stand-in data.
  const demo = leaguesDemoOn() && eventId.startsWith("demo-");
  const token = getLocalParticipant(eventId)?.token;
  // The fee and prize pool (contract/entry-fees-2026-11-13.md § 2) and, for team events whose teams sign themselves
  // up, the teams (contract/teams-finals-alerts-2026-11-13.md § 2): read with the event, null while the server has none.
  const { money, reload: reloadMoney } = useEventMoney(eventId, token, event);
  const teams = useTeamMine(eventId, !!about?.team_signup, token, event);

  const load = useCallback(async () => {
    if (demo) {
      const e = (await import("../lib/leaguesDemo")).publicEvent(eventId);
      if (e) {
        // Signing a team up in the demo signs you up to its event.
        if ((await import("../lib/phasesDemo")).demoOnTeam(eventId)) e.me = "player";
        setEvent(e);
        setRows([]);
      } else setError("That event isn't available");
      return;
    }
    try {
      const [e, s] = await Promise.all([fetchPublicEvent(eventId), fetchPublicStandingsAndBracket(eventId)]);
      setEvent(e);
      setRows(s.rows);
      setBracket(s.bracket);
      setTeamBracket(s.teamBracket);
      setPods(s.pods);
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [eventId, demo]);

  useEffect(() => {
    void load();
    if (demo) return;
    const unsubscribe = subscribeToEvent(eventId, () => void load());
    const poll = window.setInterval(() => void load(), 20000);
    return () => {
      unsubscribe();
      window.clearInterval(poll);
    };
  }, [eventId, load]);

  if (error && !event) {
    return (
      <Screen>
        <Bar title="Event not found" onBack={onBack} />
        <Notice tone="error">{error}</Notice>
      </Screen>
    );
  }
  if (!event || !rows) {
    return (
      <Screen>
        <Bar title="Event" onBack={onBack} />
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }

  // Before round 1 (and for someone still on the waitlist then): the sign-up page.
  if (event.signUp !== "closed" || (event.me === "waitlisted" && event.currentRound === 0)) {
    return <SignUpPage event={event} reload={load} onBack={onBack} about={about} money={money} reloadMoney={reloadMoney}
                       teams={teams.mine} onTeams={teams.setMine} />;
  }

  const round = event.round;
  const podOf = new Map(rows.map((r) => [r.participantId, r.podId ?? null]));
  return (
    <Screen>
      <Bar
        title={event.name}
        onBack={onBack}
        subtitle={
          event.status === "completed"
            ? "Final standings"
            : round ? roundName(round.stage, round.number, event.numberOfRounds) : `Round ${event.currentRound} of ${event.numberOfRounds}`
        }
      />
      {event.me === "waitlisted" && <Notice tone="info">Sign-ups are closed: you didn't get in this time.</Notice>}
      <FollowRow event={event} />
      <EventAboutRows about={about} eventName={event.name} />
      <PrizePoolRow money={money} eventName={event.name} leagueName={about?.league?.name} />
      {round && event.showClock && (
        <div className="bg-t1-bg py-4">
          <ClockFace round={round} size="small" />
        </div>
      )}
      <TabBar tabs={["standings", "matchups"]} value={tab} onChange={setTab} labels={{ standings: "Standings", matchups: "Matchups" }} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {tab === "standings" ? (
          <>
            {bracket.length > 0 && <PublicBracket stages={bracket} />}
            <TeamBracketView stages={teamBracket as Parameters<typeof TeamBracketView>[0]["stages"]} seatFormats={about?.seat_formats} />
            <PublicStandingsTable rows={rows} />
          </>
        ) : (
          // Every round, newest first; the round being played leads.
          (event.rounds.length ? event.rounds : round ? [{ number: round.number, stage: round.stage ?? "swiss", status: "active", matches: event.pairings }] : [])
            .map((r) => {
              const byPod = podSections(r.matches, pods, podOf, r.stage, {
                players: (m) => m.sides.map((x) => x.participantId), table: (m) => m.tableNumber, isBye: (m) => m.isBye,
              });
              return byPod ? (
                // Drafts with 2+ pods: "Round 2 · now · Pod 1", "… · Across pods", each its own block.
                <div key={r.number} className="flex flex-col gap-px">
                  {byPod.map((s) => (
                    <div key={s.pod ?? s.title} className="flex flex-col gap-px">
                      <PodHeader title={`${roundTitle(r.number, r.stage, r.status)} · ${s.title}`}
                                 right={matchCount(s.items.filter((m) => !m.isBye).length)} />
                      {s.items.map((m) => <PairingRow key={m.matchId} match={m} />)}
                    </div>
                  ))}
                </div>
              ) : (
                <div key={r.number} className="flex flex-col gap-px">
                  <div className="bg-t1-surface px-4 py-2 t1-label">{roundTitle(r.number, r.stage, r.status)}</div>
                  {r.matches.map((m) => <PairingRow key={m.matchId} match={m} />)}
                </div>
              );
            })
        )}
        {tab === "matchups" && event.rounds.length === 0 && !round && (
          <div className="bg-t1-surface px-4 py-6 t1-label">No rounds yet</div>
        )}
      </div>
    </Screen>
  );
}

function PublicStandingsTable({ rows }: { rows: PublicStandingRow[] }) {
  if (rows.length === 0) return <div className="bg-t1-surface px-4 py-6 t1-label">No players yet</div>;
  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-2 flex items-center gap-3 t1-label">
        <span className="w-6 shrink-0">#</span>
        <span className="flex-1">Player</span>
        <span className="w-12 text-right">Rec</span>
        <span className="w-8 text-right">Pts</span>
        <span className="w-14 text-right">OMW</span>
        <span className="w-14 text-right">GW</span>
      </div>
      {rows.map((r) => (
        <div key={r.participantId} className="bg-t1-surface px-4 py-3 flex items-center gap-3 text-[12px] tabular-nums">
          <span className="w-6 shrink-0 text-t1-muted">{r.rank}</span>
          <span className={`flex-1 min-w-0 truncate ${r.status === "dropped" ? "line-through opacity-50" : ""}`}>
            {r.displayName}
          </span>
          <span className="w-12 text-right">
            {r.matchDraws > 0 ? `${r.matchWins}-${r.matchLosses}-${r.matchDraws}` : `${r.matchWins}-${r.matchLosses}`}
          </span>
          <span className="w-8 text-right font-bold">{r.matchPoints}</span>
          <span className="w-14 text-right text-t1-muted">{formatPct(r.omw)}</span>
          <span className="w-14 text-right text-t1-muted">{formatPct(r.gw)}</span>
        </div>
      ))}
      <div className="bg-t1-surface px-4 py-3 text-[10px] leading-[15px] text-t1-muted">
        Ordered by match points, then opponents' match-win %, then game-win %, then opponents' game-win %. Percentages
        floored at 33% per the Magic Tournament Rules.
      </div>
    </div>
  );
}

function PairingRow({ match }: { match: PublicPairing }) {
  const [a, b] = [match.sides.find((s) => s.side === 0), match.sides.find((s) => s.side === 1)];
  const scored = match.status !== "pending";
  return (
    <div className="bg-t1-surface px-4 py-3 flex items-center gap-3 text-[12px]">
      <span className="w-10 shrink-0 t1-label">{match.isBye ? "Bye" : `T${match.tableNumber ?? "–"}`}</span>
      <span className="flex-1 min-w-0 truncate">{a?.displayName ?? "—"}</span>
      {!match.isBye && (
        <>
          <span className="w-16 shrink-0 text-center tabular-nums text-t1-muted">
            {matchScore(scored ? match.status : "pending", match.sides, match.gameDraws)}
          </span>
          <span className="flex-1 min-w-0 truncate text-right">{b?.displayName ?? "—"}</span>
        </>
      )}
    </div>
  );
}

/**
 * The sign-up page: when, where, the format, how many are in, and Sign up / Join the waitlist. Signed out, Sign up
 * signs in first (any option makes an account) and comes back here with ?signup=1, which signs up once.
 */
export function SignUpPage({ event, reload, onBack, about = null, money = null, reloadMoney, teams = null, onTeams }: {
  event: PublicEvent; reload: () => Promise<void>; onBack: () => void; about?: EventAbout | null;
  money?: EventMoney | null; reloadMoney?: () => Promise<EventMoney | null>;
  /** Team events whose teams sign themselves up: team_mine (null otherwise). */
  teams?: TeamMine | null; onTeams?: (m: TeamMine) => void;
}) {
  const real = useSession();
  // Dev server, `?demo`: the page as someone signed in sees it.
  const { ready } = real;
  const session = real.session ?? (leaguesDemoOn() ? ({ user: { id: "demo" } } as NonNullable<typeof real.session>) : null);
  /** Teams sign themselves up here: Sign up a team / Join a team stand where Sign up would. */
  const teamPage = !!teams?.team_signup || !!teams?.team;
  const teamCode = useRef(teamCodeInAddress());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [signingIn, setSigningIn] = useState(false);
  const [confirmLeave, setConfirmLeave] = useState(false);
  const auto = useRef(new URLSearchParams(window.location.search).has("signup"));
  const state = pageButton(!!session, event.signUp, event.me);

  useEffect(() => {
    if (ready) capture("event_page_viewed", { state: session ? state : "signed_out" });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready]);

  const signUp = useCallback(async (signedInNow: boolean) => {
    setBusy(true);
    setError(null);
    try {
      if (leaguesDemoOn()) throw new Error("The demo has no server to sign up with.");
      const r = await signUpForEvent(event.eventId, signedInNow);
      setMessage(r.status === "waitlisted" || r.status === "already_waitlisted"
        ? `It's full, so you're on the waitlist (number ${r.position ?? 1}).` : "You're signed up.");
      await reload();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }, [event.eventId, reload]);

  // Back from sign-in with ?signup=1: sign up once, then drop the flag from the address.
  useEffect(() => {
    if (!ready || !session || !auto.current) return;
    auto.current = false;
    // Keep the router's entry state, so Back still knows what came before.
    window.history.replaceState(window.history.state, "", window.location.pathname);
    // A team event is signed up to through a team, never alone.
    if ((state === "sign_up" || state === "waitlist") && !teamPage) void signUp(true);
  }, [ready, session, state, signUp, teamPage]);

  async function leave() {
    setBusy(true);
    try {
      await leaveEvent(event.eventId, state === "waitlisted");
      setMessage(state === "waitlisted" ? "You left the waitlist." : "You left the event.");
      setConfirmLeave(false);
      await reload();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  const facts = [when(event.startsAt), event.venueName, event.formatLabel, event.organizerName && `Run by ${event.organizerName}`]
    .filter(Boolean).join(" · ");
  return (
    <Screen>
      <Bar title={event.name} subtitle={event.shortCode ? `Event ${event.shortCode}` : undefined} onBack={onBack} />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface px-5 py-5 flex flex-col gap-2">
          <p className="text-[22px] leading-7">{event.name}</p>
          {facts && <p className="text-[12px] text-t1-muted">{facts}</p>}
          <p className="t1-label">
            {[roundsLine(event.autoRounds, event.numberOfRounds, event.topCut, event.signUp !== "closed"), feeFact(money)].filter(Boolean).join(" · ")}
          </p>
          {event.decklists !== "off" && <p className="t1-label">{event.decklists === "required" ? "Decklist required" : "Decklists welcome"}</p>}
        </div>
        <div className="bg-t1-surface px-4 py-3 text-[13px]">{signUpLine(event.players, event.capacity, event.waitlist)}</div>
        <EventAboutRows about={about} eventName={event.name} />
        <PrizePoolRow money={money} eventName={event.name} leagueName={about?.league?.name} />
        <FollowRow event={event} />
        {state === "in" && reloadMoney && <PayBlock eventId={event.eventId} eventName={event.name} money={money} reload={reloadMoney} onLeft={() => void reload()} />}
        {teamPage && teams && onTeams && session && state !== "organizer" && state !== "closed" && (
          <TeamSignupBlock eventId={event.eventId} eventName={event.name} mine={teams} userId={session.user.id === "demo" ? null : session.user.id}
                           onMine={onTeams} onChanged={() => void reload()} />
        )}
        {teams && (teamPage || teams.teams.length > 0) && <TeamsList mine={teams} />}
        {(state === "sign_up" || state === "waitlist" || state === "sign_in") && <PublicResultsNotice about={about} shown />}
        {message && <Notice tone="info">{message}</Notice>}
        {error && <Notice tone="error">{error}</Notice>}
        {state === "in" && <Notice tone="info">You're in. Your event is on the Events page.</Notice>}
        {state === "waitlisted" && <Notice tone="info">You're number {event.position ?? 1} on the waitlist. We'll tell you if a place opens.</Notice>}
        {state === "organizer" && <Notice tone="info">You're running this event.</Notice>}
        {state === "closed" && <Notice tone="info">Sign-ups are closed.</Notice>}
        {state === "sign_in" && signingIn && (
          <>
            <div className="bg-t1-surface px-4 py-4 flex flex-col gap-1.5">
              <span className="t1-label">Signing up for</span>
              <p className="text-[15px] font-bold">{event.name}</p>
              <p className="text-[12px] text-t1-muted leading-relaxed">
                New to Table 1? Any option below makes your account, then you're signed up.
              </p>
            </div>
            <SignInButtons returnTo={teamPage ? `/s/${event.eventId}${teamCode.current ? `?team=${teamCode.current}` : ""}` : `/s/${event.eventId}?signup=1`} />
          </>
        )}
      </div>
      {(state === "in" || state === "organizer") && (
        <div className="flex gap-px">
          {state === "in" && !teams?.team && <GhostAction label="Leave" onClick={() => setConfirmLeave(true)} />}
          <Link to={state === "organizer" ? `/e/${event.eventId}` : `/p/${event.eventId}`}
                className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px] text-center">
            Open event
          </Link>
        </div>
      )}
      {state === "waitlisted" && <BigAction label="Leave the waitlist" busy={busy} onClick={() => setConfirmLeave(true)} />}
      {(((state === "sign_up" || state === "waitlist") && !teamPage) || (state === "sign_in" && !signingIn)) && (
        <BigAction
          label={state === "sign_in" && teamPage ? (teamCode.current ? "Sign in to join the team" : "Sign in to sign up a team")
            : state === "waitlist" || (state === "sign_in" && event.signUp === "full") ? "Join the waitlist" : "Sign up"}
          tone="accent"
          busy={busy}
          onClick={() => {
            if (state !== "sign_in") return void signUp(false);
            // An email code signs in on this page: sign up as soon as the session arrives, as after a redirect.
            auto.current = true;
            setSigningIn(true);
          }}
        />
      )}
      {confirmLeave && (
        <Dialog
          title={`Leave ${event.name}?`}
          message={state === "waitlisted" ? "You'll lose your place on the waitlist."
            : event.waitlist > 0 ? "Your place goes to the next person on the waitlist." : "You can sign up again while there's room."}
          cancelLabel="Stay"
          confirmLabel="Leave"
          tone="danger"
          busy={busy}
          onCancel={() => setConfirmLeave(false)}
          onConfirm={() => void leave()}
        />
      )}
    </Screen>
  );
}

/**
 * Follow / Following for anyone signed in who doesn't run or play in the event (contract/event-follows-2026-11-09.md):
 * it shows on their Events page under Following, with a notification for each round and the final standings in the apps.
 */
function FollowRow({ event }: { event: PublicEvent }) {
  const { session } = useSession();
  const [f, setF] = useState<EventFollow | null>(null);
  const [menu, setMenu] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const member = event.me === "organizer" || event.me === "player";
  useEffect(() => {
    if (!session || member) return;
    fetchEventFollow(event.eventId).then(setF).catch(() => setF(null));
  }, [session, member, event.eventId]);
  if (!f || member || !(f.following || f.can_follow)) return null;
  const set = (on: boolean, notify: boolean | null) => {
    setMenu(false);
    setEventFollow(event.eventId, on, notify).then((r) => setF({ ...r, can_follow: true })).catch((e) => setError(errorMessage(e)));
  };
  return (
    <>
      <button type="button" onClick={() => (f.following ? setMenu((m) => !m) : set(true, null))}
              className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3 text-left">
        <span className="flex-1 min-w-0 flex flex-col gap-0.5">
          <span className="text-[14px]">{f.following ? "Following" : "Follow"}</span>
          {f.following && <span className="t1-label">{f.notify ? "Each round and the final standings" : "Notifications off"}</span>}
        </span>
        <span className={`t1-label ${f.following ? "text-t1-accent" : "text-t1-text"}`}>{f.following ? "✓" : "Follow"}</span>
      </button>
      {menu && (
        <div className="flex gap-px">
          <GhostAction label={f.notify ? "Notifications off" : "Notifications on"} onClick={() => set(true, !f.notify)} />
          <GhostAction label="Unfollow" onClick={() => set(false, null)} />
        </div>
      )}
      {error && <Notice tone="error">{error}</Notice>}
    </>
  );
}

/** The top 8 on the public page: "(1) Ana 2–0 (8) Bo" per match, the winner in the accent. */
function PublicBracket({ stages }: { stages: PublicBracketStage[] }) {
  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-2 t1-label">{stages.some((s) => s.stage === "quarterfinal") ? "Top 8" : "Top 4"}</div>
      {stages.map((st) => (
        <div key={st.stage} className="flex flex-col gap-px">
          <p className="t1-label px-4 py-2">{roundName(st.stage, 0, 0)}</p>
          {st.matches.map((m) => (
            <div key={m.match_id} className="bg-t1-surface px-4 py-3 flex items-center gap-2 text-[12px]">
              {[0, 1].map((n) => {
                const sd = m.sides[n];
                const won = !!sd?.participant_id && sd.participant_id === m.winner;
                return (
                  <span key={n} className={`flex-1 min-w-0 truncate ${n === 1 ? "text-right order-3" : ""} ${won ? "text-t1-accent font-bold" : ""}`}>
                    ({sd?.seed ?? "–"}) {sd?.display_name ?? "—"}
                  </span>
                );
              })}
              <span className="order-2 text-t1-muted tabular-nums">
                {m.status === "pending" ? "vs" : `${m.sides[0]?.game_wins ?? 0}–${m.sides[1]?.game_wins ?? 0}`}
              </span>
            </div>
          ))}
        </div>
      ))}
      <div className="bg-t1-surface px-4 py-2 t1-label">Standings</div>
    </div>
  );
}
