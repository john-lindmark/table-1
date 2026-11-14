import { useEffect, useState } from "react";
import { Over } from "../components/EventListing";
import { BAR_ICON, Icon } from "../components/icons";
import { Avatar } from "../components/Avatar";
import { Bar, BigAction, Dialog, Field, GhostAction, Menu, Notice, Row, Screen, Section, Segmented, Stepper, SwitchRow } from "../components/kit";
import { loadFriends, useFriends } from "../lib/friends";
import {
  MEMBER_ACTION_LABEL, MULTIPLIERS, PRESETS, memberActions, ordinal, roleLabel, eventAbout, leagueEventSet, leagueMemberSet, leagueSeasonSet, leagueUpdate, leagueView, leaguesError, leaguesHome,
  multiplierText, pointsWords, presetOf, qualifyWords, seasonLine,
  type EventLeague, type LeagueCard, type LeagueMember, type LeagueRole, type LeagueView, type MemberAction, type PointsBracket, type PointsRule, type Preset, type SeasonRef,
} from "../lib/leagues";
import { centsOf, centsText, leagueDueMark, leagueMoney, money, type LeagueDue, type LeagueMoney } from "../lib/money";

/* An organizer's league tools (contract/public-events-leagues-2026-11-13.md § 3 Clients): Edit league, Seasons (the
   two presets and custom brackets, best N, who qualifies, Close season), Organizers; and an event's League row in
   Setup → Details. Loaded only for people who run a league. */

export function LeagueTools({ data, view, seasonId, onBack, go, onChanged, onArchived }: {
  data: LeagueView; view: string; seasonId: string | null; onBack: () => void;
  go: (view: string, seasonId?: string) => void;
  /** Saved: reload (the slug when the league's address may have changed). */
  onChanged: (slug?: string) => void;
  /** The owner archived the league: its page is gone. */
  onArchived: () => void;
}) {
  if (view === "edit") return <EditLeague data={data} onBack={onBack} onChanged={onChanged} onArchived={onArchived} />;
  if (view === "organizers") return <Organizers data={data} onBack={onBack} onChanged={() => onChanged()} />;
  if (view === "season") return <SeasonEditor data={data} seasonId={seasonId === "new" ? null : seasonId} onBack={onBack} onChanged={() => onChanged()} />;
  if (view === "dues") return <Dues data={data} onBack={onBack} />;
  return (
    <Screen>
      <Bar title="Seasons" onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {data.seasons.map((s) => <Row key={s.id} title={s.name} detail={seasonLine(s)} onClick={() => go("season", s.id)} />)}
        <Row title="New season" value={<Icon d={BAR_ICON.plus} />} onClick={() => go("season", "new")} />
      </div>
    </Screen>
  );
}

function EditLeague({ data, onBack, onChanged, onArchived }: {
  data: LeagueView; onBack: () => void; onChanged: (slug?: string) => void; onArchived: () => void;
}) {
  const l = data.league;
  const [name, setName] = useState(l.name);
  const [region, setRegion] = useState(l.region ?? "");
  const [link, setLink] = useState(l.link ?? "");
  const [description, setDescription] = useState(l.description ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [archiving, setArchiving] = useState(false);
  const run = async (patch: Parameters<typeof leagueUpdate>[1], done: (slug: string) => void) => {
    setBusy(true);
    setError(null);
    try {
      const next = await leagueUpdate(l.id, patch);
      done(next.slug);
    } catch (e) {
      setError(leaguesError(e));
      setArchiving(false);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Screen>
      <Bar title="Edit league" onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        <Field label="Name" value={name} onChange={(v) => setName(v.slice(0, 60))} />
        <Field label="Region" value={region} onChange={(v) => setRegion(v.slice(0, 80))} placeholder="Denver, Colorado" />
        <Field label="Link" value={link} onChange={(v) => setLink(v.slice(0, 300))} placeholder="https://" />
        <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
          <span className="t1-label">Description</span>
          <textarea value={description} rows={7} onChange={(e) => setDescription(e.target.value.slice(0, 2000))}
                    className="bg-transparent border-0 outline-0 text-[15px] leading-[22px] resize-none w-full" />
        </label>
        {error && <Notice tone="error">{error}</Notice>}
        {data.me.role === "owner" && <Row title="Archive league" onClick={() => setArchiving(true)} />}
      </div>
      <BigAction label="Save" tone="accent" busy={busy} disabled={name.trim().length < 2}
                 onClick={() => void run({ name: name.trim(), region: region.trim() || null, link: link.trim() || null, description: description.trim() || null },
                                         (slug) => { onChanged(slug); onBack(); })} />
      {archiving && (
        <Dialog title={`Archive ${l.name}?`} message="Its page closes for everyone and its seasons stop counting." cancelLabel="Keep" confirmLabel="Archive"
                tone="danger" busy={busy} onCancel={() => setArchiving(false)}
                onConfirm={() => void run({ archived: true }, onArchived)} />
      )}
    </Screen>
  );
}

/**
 * Who runs the league. The owner gets Remove and Make owner / Make organizer on each member, and adds from friends;
 * other organizers read it. A server from before `members` sends names only: then the list is names, with Add.
 */
function Organizers({ data, onBack, onChanged }: { data: LeagueView; onBack: () => void; onChanged: () => void }) {
  const friends = useFriends().list?.friends ?? [];
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [menu, setMenu] = useState<LeagueMember | null>(null);
  const [removing, setRemoving] = useState<LeagueMember | null>(null);
  const owner = data.me.role === "owner";
  useEffect(() => { if (owner) void loadFriends(); }, [owner]);
  const members = data.members ?? null;
  const set = async (userId: string, role: LeagueRole | null) => {
    setBusy(userId);
    try {
      await leagueMemberSet(data.league.id, userId, role);
      setError(null);
      onChanged();
    } catch (e) {
      // "A league keeps an owner…" and the rest: the server's own words.
      setError(leaguesError(e));
    } finally {
      setBusy(null);
      setRemoving(null);
    }
  };
  const act = (m: LeagueMember, a: MemberAction) => (a === "remove" ? setRemoving(m) : void set(m.user_id, a === "make_owner" ? "owner" : "organizer"));
  const have = new Set(members ? members.map((m) => m.user_id) : []);
  const names = new Set(data.league.organizers.map((n) => n.toLowerCase()));
  const canAdd = friends.filter((f) => (members ? !have.has(f.user_id) : !names.has(f.display_name.toLowerCase())));
  return (
    <Screen>
      <Bar title="Organizers" onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {members
          ? members.map((m) => (
              <Row key={m.user_id} title={m.name} detail={roleLabel(m.role)} avatar={<Avatar name={m.name} userId={m.user_id} opens="league_organizers" />}
                   onClick={memberActions(data.me.role, m).length && busy == null ? () => setMenu(m) : undefined} />
            ))
          : data.league.organizers.map((n, i) => <Row key={`${n}-${i}`} title={n} detail={i === 0 ? "Owner" : "Organizer"} />)}
        {error && <Notice tone="error">{error}</Notice>}
        {owner && (
          <>
            <Section title="Add from friends" />
            {canAdd.length === 0 && <div className="bg-t1-surface px-4 py-4 t1-label">No friends to add</div>}
            {canAdd.map((f) => (
              <Row key={f.user_id} title={f.display_name} avatar={<Avatar name={f.display_name} userId={f.user_id} />}
                   action={{ label: busy === f.user_id ? "Adding…" : "Add", disabled: busy != null, onClick: () => void set(f.user_id, "organizer") }} />
            ))}
          </>
        )}
      </div>
      {menu && (
        <Menu title={menu.name} onClose={() => setMenu(null)}
              items={memberActions(data.me.role, menu).map((a) => ({ title: MEMBER_ACTION_LABEL[a], onClick: () => act(menu, a) }))} />
      )}
      {removing && (
        <Dialog title={`Remove ${removing.name}?`} message={`They stop running ${data.league.name}. Their events stay in its seasons.`}
                cancelLabel="Keep" confirmLabel="Remove" tone="danger" busy={busy != null}
                onCancel={() => setRemoving(null)} onConfirm={() => void set(removing.user_id, null)} />
      )}
    </Screen>
  );
}

/** Today's date here, as a date field takes it. */
const today = () => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};
const num = (v: string, min: number, max: number) => Math.max(min, Math.min(max, Math.trunc(Number(v) || 0)));

function SeasonEditor({ data, seasonId, onBack, onChanged }: { data: LeagueView; seasonId: string | null; onBack: () => void; onChanged: () => void }) {
  const leagueId = data.league.id;
  // The page carries one season in full: an edit of another reads it first.
  const [full, setFull] = useState(seasonId && data.season?.id === seasonId ? data.season : null);
  const [loadError, setLoadError] = useState<string | null>(null);
  useEffect(() => {
    if (!seasonId || full) return;
    leagueView(leagueId, seasonId).then((v) => setFull(v.season), (e) => setLoadError(leaguesError(e)));
  }, [seasonId, full, leagueId]);
  if (seasonId && !full) {
    return (
      <Screen>
        <Bar title="Season" onBack={onBack} />
        {loadError ? <Notice tone="error">{loadError}</Notice> : <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
      </Screen>
    );
  }
  return <SeasonForm key={seasonId ?? "new"} leagueId={leagueId} season={full} onBack={onBack} onChanged={onChanged} />;
}

function SeasonForm({ leagueId, season, onBack, onChanged }: {
  leagueId: string; season: LeagueView["season"]; onBack: () => void; onChanged: () => void;
}) {
  const year = new Date().getFullYear();
  const [name, setName] = useState(season?.name ?? String(year));
  const [starts, setStarts] = useState(season?.starts_on ?? today());
  const [ends, setEnds] = useState(season?.ends_on ?? `${year}-12-31`);
  const [preset, setPreset] = useState<Preset>(season ? presetOf(season.points) : "places");
  const [custom, setCustom] = useState<PointsRule>(season?.points ?? PRESETS.places);
  const [bestN, setBestN] = useState<number | null>(season?.best_n ?? null);
  const [winners, setWinners] = useState(season?.qualify.winners ?? true);
  const [top, setTop] = useState(season?.qualify.top ?? 0);
  /** What each paid entry of the season's events owes the league (contract/entry-fees-2026-11-13.md § 5). */
  const [cut, setCut] = useState(season?.entry_cut_cents ? centsText(season.entry_cut_cents) : "");
  const cutCents = cut.trim() === "" ? 0 : centsOf(cut);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [closing, setClosing] = useState(false);
  const rule = preset === "custom" ? custom : PRESETS[preset];
  const qualify = { winners, pass_down: season?.qualify.pass_down ?? true, top };
  // Brackets rise: each `through` past the one before.
  const rising = rule.places.every((b, i) => b.through > (i ? rule.places[i - 1].through : 0));
  const problem = !name.trim() ? "Name the season" : !starts || !ends || ends < starts ? "The season ends on or after the day it starts"
    : !rising ? "Each bracket reaches further than the one before" : !pointsWords(rule) ? "Give points for something"
    : cutCents == null || cutCents > 100000 ? "The cut per entry is $0 to $1,000" : null;

  const save = async (patch: Parameters<typeof leagueSeasonSet>[2]) => {
    setBusy(true);
    setError(null);
    try {
      await leagueSeasonSet(leagueId, season?.id ?? null, patch);
      onChanged();
      onBack();
    } catch (e) {
      setError(leaguesError(e));
      setClosing(false);
    } finally {
      setBusy(false);
    }
  };
  const setBracket = (i: number, patch: Partial<PointsBracket>) =>
    setCustom((r) => ({ ...r, places: r.places.map((b, j) => (j === i ? { ...b, ...patch } : b)) }));
  const cell = "w-[84px] bg-t1-bg px-3 py-2 text-[15px] tabular-nums outline-0 border-0 text-right";

  return (
    <Screen>
      <Bar title={season ? season.name : "New season"} onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        <Field label="Name" value={name} onChange={(v) => setName(v.slice(0, 40))} />
        <div className="flex gap-px">
          <div className="flex-1 min-w-0"><Field label="Starts" type="date" value={starts} onChange={setStarts} /></div>
          <div className="flex-1 min-w-0"><Field label="Ends" type="date" value={ends} onChange={setEnds} /></div>
        </div>
        <Segmented label="Points" value={preset}
                   onChange={(p) => { if (p === "custom" && preset !== "custom") setCustom(rule); setPreset(p); }}
                   options={[{ value: "places", label: "Places" }, { value: "match_wins", label: "Match wins" }, { value: "custom", label: "Custom" }]} />
        <div className="bg-t1-surface px-4 py-3 t1-label">{pointsWords(rule) || "No points yet"}</div>
        {preset === "custom" && (
          <>
            <div className="bg-t1-surface pl-4 py-2 flex items-center gap-px t1-label">
              <span className="flex-1">Finish</span>
              <span className="w-[84px] px-3 text-right">Through</span>
              <span className="w-[84px] px-3 text-right">Points</span>
              <span className="w-[50px]" />
            </div>
            {custom.places.map((b, i) => (
              <div key={i} className="bg-t1-surface pl-4 flex items-center gap-px">
                <span className="flex-1 text-[13px]">{b.through === (i ? custom.places[i - 1].through : 0) + 1 ? ordinal(b.through) : `Top ${b.through}`}</span>
                <input type="number" inputMode="numeric" min={1} max={512} aria-label={`Bracket ${i + 1}: through place`} value={b.through}
                       onChange={(e) => setBracket(i, { through: num(e.target.value, 1, 512) })} className={cell} />
                <input type="number" inputMode="numeric" min={0} max={1000} aria-label={`Bracket ${i + 1}: points`} value={b.points}
                       onChange={(e) => setBracket(i, { points: num(e.target.value, 0, 1000) })} className={cell} />
                <button type="button" aria-label={`Remove bracket ${i + 1}`} onClick={() => setCustom((r) => ({ ...r, places: r.places.filter((_, j) => j !== i) }))}
                        className="w-[50px] h-[42px] bg-t1-bg hover:bg-t1-surface-hover text-[18px]">−</button>
              </div>
            ))}
            {custom.places.length < 16 && (
              <Row title="Add a bracket" value={<Icon d={BAR_ICON.plus} />}
                   onClick={() => setCustom((r) => {
                     const last = r.places[r.places.length - 1];
                     return { ...r, places: [...r.places, { through: last ? Math.min(512, last.through * 2) : 1, points: last ? Math.max(0, Math.floor(last.points / 2)) : 10 }] };
                   })} />
            )}
            <Stepper label="For playing" value={custom.participation} min={0} max={100} onChange={(n) => setCustom((r) => ({ ...r, participation: n }))} />
            <Stepper label="Per match win" value={custom.match_win} min={0} max={20} onChange={(n) => setCustom((r) => ({ ...r, match_win: n }))} />
          </>
        )}
        <SwitchRow label="Count every result" on={bestN == null} onChange={(on) => setBestN(on ? null : 6)} />
        {bestN != null && <Stepper label="Best results that count" value={bestN} min={1} max={50} onChange={setBestN} />}
        <Section title="The final" />
        <SwitchRow label="Event winners qualify" on={winners} onChange={setWinners} />
        <Stepper label="Top on points qualify" value={top} min={0} max={64} onChange={setTop} />
        {qualifyWords(qualify) && <div className="bg-t1-surface px-4 py-3 t1-label">{qualifyWords(qualify)}</div>}
        {(season == null || "entry_cut_cents" in season) && (
          <Field label="Cut per entry · USD" value={cut} placeholder="0" onChange={(v) => setCut(v.replace(/[^0-9.]/g, "").slice(0, 7))} />
        )}
        {error && <Notice tone="error">{error}</Notice>}
        {season && !season.closed && season.state !== "upcoming" && (
          <div className="flex"><GhostAction label="Close season" onClick={() => setClosing(true)} /></div>
        )}
        {season?.closed && <Notice tone="info">This season is closed.</Notice>}
      </div>
      <BigAction label={problem ?? (season ? "Save" : "Add season")} tone="accent" busy={busy} disabled={!!problem}
                 onClick={() => void save({ name: name.trim(), starts_on: starts, ends_on: ends, points: rule, best_n: bestN, qualify,
                                            ...(cutCents != null && cutCents !== (season?.entry_cut_cents ?? 0) ? { entry_cut_cents: cutCents } : {}) })} />
      {closing && season && (
        <Dialog title={`Close ${season.name}?`} message="Standings become final, whoever qualifies on points is told, and followers hear the season is over."
                cancelLabel="Not yet" confirmLabel="Close season" busy={busy} error={error}
                onCancel={() => setClosing(false)} onConfirm={() => void save({ closed: true })} />
      )}
    </Screen>
  );
}

/* ── dues ────────────────────────────────────────────────────────────── */

/** What each event's host owes the league from its cut of the entries, and what the league has marked received. */
function Dues({ data, onBack }: { data: LeagueView; onBack: () => void }) {
  const seasonId = data.season?.id ?? null;
  const [m, setM] = useState<LeagueMoney | null | "failed">(null);
  const [marking, setMarking] = useState<LeagueDue | null>(null);
  const [amount, setAmount] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const load = () => {
    if (seasonId) void leagueMoney(seasonId).then((r) => setM(r ?? "failed"));
  };
  useEffect(load, [seasonId]);
  const cents = amount.trim() === "" ? 0 : centsOf(amount);
  const mark = async () => {
    if (!marking || cents == null) return;
    setBusy(true);
    setError(null);
    try {
      await leagueDueMark(marking.event_id, cents);
      setMarking(null);
      load();
    } catch (e) {
      setError(leaguesError(e));
    } finally {
      setBusy(false);
    }
  };
  const info = m && m !== "failed" ? m : null;
  return (
    <Screen>
      <Bar title="Dues" onBack={onBack} />
      <div className="flex-1 min-h-0 flex flex-col gap-px">
        {m === "failed" && <Notice tone="info">This isn't available yet.</Notice>}
        {m === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {info && (
          <>
            <div className="bg-t1-bg px-4 py-6 flex flex-col items-center gap-1">
              <p className="t1-label">{data.season?.name} · received</p>
              <p className="text-[40px] leading-[48px] tabular-nums tracking-[2px]">
                <span className="text-t1-accent">{money(info.received_cents ?? 0)}</span><span className="text-t1-muted text-[20px]"> of {money(info.pool_cents)}</span>
              </p>
              <p className="t1-label">{money(info.entry_cut_cents)} an entry</p>
            </div>
            {(info.events ?? []).length === 0 && <Notice tone="info">No paid entries yet.</Notice>}
            {(info.events ?? []).map((d) => {
              const settled = d.received_cents >= d.owed_cents;
              return (
                <button key={d.event_id} type="button" onClick={() => { setAmount(centsText(d.received_cents || d.owed_cents)); setError(null); setMarking(d); }}
                        className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3 text-left w-full">
                  <span className="flex-1 min-w-0 flex flex-col gap-0.5">
                    <span className="text-[14px] truncate">{d.name}</span>
                    <span className="t1-label truncate">{d.entries} {d.entries === 1 ? "ENTRY" : "ENTRIES"} · OWES {money(d.owed_cents)}</span>
                  </span>
                  <span className={`shrink-0 text-[13px] tabular-nums ${settled ? "text-t1-accent" : d.received_cents > 0 ? "" : "text-t1-muted"}`}>
                    {d.received_cents > 0 ? money(d.received_cents) : "Mark received"}
                  </span>
                </button>
              );
            })}
          </>
        )}
      </div>
      {marking && (
        <Dialog title={marking.name} message={`Owes ${money(marking.owed_cents)}. What has the league received?`} cancelLabel="Cancel" confirmLabel="Mark received"
                busy={busy} error={error ?? (cents == null ? "Type an amount" : null)} onCancel={() => setMarking(null)} onConfirm={() => void mark()}>
          <input value={amount} autoFocus inputMode="decimal" aria-label="Received, in dollars" onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, "").slice(0, 9))}
                 className="bg-t1-surface px-3 py-3 outline-0 border-0 text-[17px] tabular-nums" />
        </Dialog>
      )}
    </Screen>
  );
}

/* ── an event's League row (Setup → Details) ─────────────────────────── */

/** For organizers who run a league: the league and season this event counts for. Nothing for everyone else, or
 *  while the server part isn't live. */
export function EventLeagueRow({ eventId, onChanged }: { eventId: string; onChanged?: () => void }) {
  const [mine, setMine] = useState<LeagueCard[] | null>(null);
  const [current, setCurrent] = useState<EventLeague | null>(null);
  const [open, setOpen] = useState(false);
  useEffect(() => {
    let live = true;
    leaguesHome().then((h) => live && setMine(h.mine), () => live && setMine([]));
    void eventAbout(eventId).then((a) => live && setCurrent(a?.league ?? null));
    return () => { live = false; };
  }, [eventId]);
  if (!mine?.length && !current) return null;
  return (
    <>
      <Row title="League" detail={current ? [current.name, current.season, current.final ? "The final" : current.multiplier && current.multiplier !== 1 ? multiplierText(current.multiplier) : null].filter(Boolean).join(" · ") : "Not in a league"}
           value={<Icon d={BAR_ICON.arrow} />} onClick={() => setOpen(true)} />
      {open && (
        <EventLeaguePanel eventId={eventId} leagues={mine ?? []} current={current} onClose={() => setOpen(false)}
                          onSaved={(l) => { setCurrent(l); setOpen(false); onChanged?.(); }} />
      )}
    </>
  );
}

function EventLeaguePanel({ eventId, leagues, current, onClose, onSaved }: {
  eventId: string; leagues: LeagueCard[]; current: EventLeague | null; onClose: () => void; onSaved: (l: EventLeague | null) => void;
}) {
  const [leagueId, setLeagueId] = useState<string | null>(current?.id ?? (leagues.length === 1 ? leagues[0].id : null));
  const [seasons, setSeasons] = useState<SeasonRef[] | null>(null);
  const [seasonId, setSeasonId] = useState<string | null>(current?.season_id ?? null);
  const [multiplier, setMultiplier] = useState(current?.multiplier ?? 1);
  const [final, setFinal] = useState(current?.final ?? false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!leagueId) return;
    let live = true;
    setSeasons(null);
    leagueView(leagueId).then((v) => {
      if (!live) return;
      const open = v.seasons.filter((s) => s.state !== "over" || s.id === current?.season_id);
      setSeasons(open);
      setSeasonId((id) => (id && open.some((s) => s.id === id) ? id : open.find((s) => s.state === "active")?.id ?? open[0]?.id ?? null));
    }, (e) => live && setError(leaguesError(e)));
    return () => { live = false; };
  }, [leagueId, current?.season_id]);
  const run = async (season: string | null) => {
    setBusy(true);
    setError(null);
    try {
      const r = await leagueEventSet(eventId, season, multiplier, final);
      onSaved(r.league);
    } catch (e) {
      setError(leaguesError(e));
      setBusy(false);
    }
  };
  return (
    <Over title="League" onBack={onClose}
          bottom={<BigAction label={current ? "Save" : "Add to league"} tone="accent" busy={busy} disabled={!seasonId} onClick={() => void run(seasonId)} />}>
      {leagues.length > 1 && (
        <Segmented label="League" columns={1} value={leagueId} onChange={setLeagueId} options={leagues.map((l) => ({ value: l.id, label: l.name }))} />
      )}
      {leagues.length === 1 && <Row title={leagues[0].name} detail="League" />}
      {leagueId && seasons === null && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
      {seasons && seasons.length === 0 && <Notice tone="info">This league has no open season. Add one from the league's page.</Notice>}
      {seasons && seasons.length > 0 && (
        <>
          <Segmented label="Season" columns={seasons.length > 3 ? 2 : undefined} value={seasonId} onChange={setSeasonId}
                     options={seasons.map((s) => ({ value: s.id, label: s.name }))} />
          <Segmented label="Points" value={multiplier} onChange={setMultiplier} options={MULTIPLIERS.map((m) => ({ value: m, label: multiplierText(m), disabled: final }))} />
          <SwitchRow label="This is the final" on={final} onChange={setFinal} />
        </>
      )}
      {error && <Notice tone="error">{error}</Notice>}
      {current && <div className="flex"><GhostAction label="Remove from league" disabled={busy} onClick={() => void run(null)} /></div>}
    </Over>
  );
}
