import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Avatar } from "../components/Avatar";
import { PersonMenu, PersonRow, SharingOfferDialog, useWideningConfirm, type PersonRef } from "../components/PersonActions";
import { BigAction, Bar, Field, Menu, Notice, Row, Screen, Section, Segmented } from "../components/kit";
import { errorMessage } from "../lib/api";
import { coverPrinting, oracleIndexById, type Catalog } from "../lib/catalog";
import { useCollection } from "../lib/collection";
import { useBinders } from "../lib/binders";
import { usePrices, usdPrice, usdText } from "../lib/prices";
import {
  LIBRARY_PARTS, PART_DETAIL, PART_LABEL, VIS_LABEL, VISIBILITIES, blockUser, capped, effective, effectiveItem, fetchProfile,
  fetchProfileCards, fetchSharedCards, sharedByline, sharedTitle, type SharedLinkData, groupOf, inherits, loadFriends, loadMatches, loadSharing, matchShort, matchSummary, matchWith, reach,
  cancelSent, profileValue, removeFriend, requestFriend, requestFriendByEmail, respondFriend, searchPeople, sectionCount, sentLabel,
  setItem, setPart, sharingSummary, setAll, answerOffer, reachOf, seesLine, viewAs, widening, withItem, withPart, offerAnswered,
  fetchProfileFriends, friendsDetail, friendsOwnDetail, friendRowDetail, profileRankingDetail,
  startTradeFromMatch, useFriends, friendsNow, wantTier, copyNote, sharedCardCount, sharedEntries, sharedListKind, type MatchLine, type Person, type ProfileCard, type ProfileData, type SectionKind,
  type SharePart, type ShareItem, type Sharing, type TradeMatch, type Visibility,
} from "../lib/friends";
import { startFriendsDemo } from "../lib/friendsDemo";
import { RankingsRow } from "./Rankings";
import { FollowRows } from "./Follows";
import { SpiceRow } from "./Spice";
import { capture } from "../lib/telemetry";
import {
  CardGroupRow, CardRow, CardTile, LibScreen, StackRows, ViewButton, useBoxWidth, useCatalog, useLibrarySession, useStoredLayout, type StackCardItem,
} from "./Library";
import { DeckImageScreen } from "./DeckImage";
import { BoardHeader, ExportScreen, groupsOf, regrouped, resolveLines, sortLines, useListGrouping, useListSort, useListsData, type Line } from "./Lists";
import { useSearchUsed } from "./Binders";
import { GROUPING_KEY, groupLabel, groupSections, keysOf, useStoredGrouping } from "../lib/cardGrouping";
import { SORT_KEY, applySort, sortKeyOf, useStoredSort } from "../lib/cardSort";
import { BOARD_ORDER, boardTitle, createList, type ListKind } from "../lib/lists";
import { cardMatches } from "../lib/librarySearch";
import { COLLAPSED, addPart, isOpen, lineGroups, sortParts, toggleOne, type Disclosure, type LineGroup, type Part } from "../lib/printings";
import type { Finish } from "../lib/collection";
import { useFollows } from "../lib/follows";

/* Friends, profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md). Same screens as the iOS app:
   Account → Friends / Sharing / Your profile; Library → Trade matches. */

const plural = (n: number, one: string, many = `${one}s`) => `${n.toLocaleString()} ${n === 1 ? one : many}`;

/** Signed in (or the dev demo, once its friends are built from the demo Library). */
export function useFriendsReady(): { ready: boolean; session: boolean } {
  const { session, ready, userId, demo } = useLibrarySession();
  useCollection(userId);
  useBinders(userId);
  const { catalog } = useCatalog();
  const [demoReady, setDemoReady] = useState(false);
  useEffect(() => {
    if (demo && catalog) void startFriendsDemo(catalog).then(() => setDemoReady(true));
  }, [demo, catalog]);
  return { ready: ready && (!demo || demoReady), session: !!session };
}

function Gate({ title, onBack, children }: { title: string; onBack: () => void; children: () => JSX.Element }) {
  const { ready, session } = useFriendsReady();
  if (!ready) return <Screen><Bar title={title} onBack={onBack} /><div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div></Screen>;
  if (!session) return <Screen><Bar title={title} onBack={onBack} /><Notice tone="info">Sign in to see friends and sharing.</Notice></Screen>;
  return children();
}

/* ── rows for other screens ──────────────────────────────────────────── */

/** Account: Friends, Sharing, your profile. */
export function FriendsAccountRows({ onFriends, onSharing, onProfile, eventsPlayed = 0 }: {
  onFriends: () => void; onSharing: () => void; onProfile: () => void; eventsPlayed?: number;
}) {
  const s = useFriends();
  const me = useLibrarySession().userId;
  const [recordOffered, setRecordOffered] = useState(() => offerAnswered("record", me));
  const answerRecord = (yes: boolean) => {
    answerOffer("record", me, yes);
    setRecordOffered(true);
    if (yes) void setAll(["record"], "friends");
  };
  useEffect(() => {
    void loadFriends();
    void loadSharing();
  }, []);
  const friends = s.list?.friends.length ?? 0, waiting = s.list?.incoming.length ?? 0;
  return (
    <>
      <div className="bg-t1-surface px-4 py-2 t1-label">Friends and sharing</div>
      <Row title="Friends" detail={[plural(friends, "friend"), waiting ? `${waiting} waiting` : null].filter(Boolean).join(" · ")}
           value={waiting ? `${waiting} new` : undefined} accentValue onClick={onFriends} />
      <Row title="Sharing" detail={s.sharing ? sharingSummary(s.sharing) : "Who sees your profile and Library"} onClick={onSharing} />
      <Row title="Your profile" detail="Name, photo and what you share" onClick={onProfile} />
      {/* After your first event, with Record private: offer once to show it to friends (§ UX rules 8). */}
      {!recordOffered && eventsPlayed >= 1 && s.sharing?.record === "private" && (
        <div className="flex gap-px">
          <div className="flex-1 min-w-0"><Row title="Show your record on your profile?" detail="Friends would see your wins, losses and draws" /></div>
          <button type="button" className="bg-t1-accent px-4 t1-label text-t1-ink!" onClick={() => answerRecord(true)}>Friends</button>
          <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover px-4 t1-label" onClick={() => answerRecord(false)}>Not now</button>
        </div>
      )}
    </>
  );
}

/** Library home: who has what you want, who wants what you have. */
/** Trades: who has what you want, who wants what you have; with none, one row opens Trade matches. */
export function TradeMatchRows({ onOpen, onNone }: { onOpen: (userId: string) => void; onNone: () => void }) {
  const { ready, session } = useFriendsReady();
  const s = useFriends();
  useEffect(() => {
    if (ready && session) void loadMatches();
  }, [ready, session]);
  const m = s.matches;
  if (!m) return null;
  return (
    <>
      <Section title="Matches" count={m.length || undefined} />
      {!m.length && <Row title="No matches yet" detail="Friends' for-trade cards against your wants" onClick={onNone} />}
      {m.map((x) => <MatchRow key={x.user_id} x={x} onOpen={onOpen} />)}
    </>
  );
}

function MatchRow({ x, onOpen }: { x: TradeMatch; onOpen: (userId: string) => void }) {
  const [menu, setMenu] = useState<PersonRef | null>(null);
  return (
    <>
      <PersonRow person={{ userId: x.user_id, displayName: x.display_name, relation: x.friend ? "friend" : "none" }} onMenu={setMenu}>
        <Row title={x.display_name} detail={matchShort(x) + (x.friend ? "" : " · played with you")}
             avatar={<Avatar name={x.display_name} userId={x.user_id} opens="trade_match" />}
             value={x.have_usd + x.want_usd > 0 ? usdText(x.have_usd + x.want_usd) : undefined} onClick={() => onOpen(x.user_id)} />
      </PersonRow>
      <PersonMenu person={menu} from="trade_match" onClose={() => setMenu(null)} />
    </>
  );
}

/* ── friends ─────────────────────────────────────────────────────────── */

export function FriendsScreen({ onBack, onProfile, onAdd }: { onBack: () => void; onProfile: (id: string) => void; onAdd: () => void }) {
  return <Gate title="Friends" onBack={onBack}>{() => <FriendsBody onBack={onBack} onProfile={onProfile} onAdd={onAdd} />}</Gate>;
}

function FriendsBody({ onBack, onProfile, onAdd }: { onBack: () => void; onProfile: (id: string) => void; onAdd: () => void }) {
  const s = useFriends();
  const [busy, setBusy] = useState<string | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  const [menuFor, setMenuFor] = useState<{ p: PersonRef; from: "friends" | "request" } | null>(null);
  useEffect(() => void loadFriends(), []);
  const run = (id: string, work: () => Promise<unknown>) => {
    setBusy(id);
    setFail(null);
    work().catch((e) => setFail(errorMessage(e))).finally(() => setBusy(null));
  };
  const l = s.list;
  /** Every person row takes a long press or right-click: the same menu as their profile's More (§ UX rules 6). */
  const person = (p: Person, detail: string, relation: string, action?: { label: string; onClick: () => void }) => (
    <PersonRow key={p.user_id} person={{ userId: p.user_id, displayName: p.display_name, relation }}
               onMenu={(ref) => setMenuFor({ p: ref, from: relation === "incoming" ? "request" : "friends" })}>
      <Row title={p.display_name} detail={busy === p.user_id ? "Working…" : detail}
           avatar={<Avatar name={p.display_name} userId={p.user_id} />} action={action}
           onClick={action ? undefined : () => onProfile(p.user_id)} />
    </PersonRow>
  );
  return (
    <Screen>
      <Bar title="Friends" onBack={onBack}
           subtitle={l ? [plural(l.friends.length, "friend"), l.incoming.length ? `${l.incoming.length} waiting` : null].filter(Boolean).join(" · ") : undefined}
           right={<button type="button" onClick={onAdd} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Add</button>} />
      {(s.error || fail) && <Notice tone="error">{fail ?? s.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Row title="Add a friend" detail="Played with you, a name or an email" onClick={onAdd} />
        {!l && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {l && l.incoming.length > 0 && <Section title="Requests" count={l.incoming.length} />}
        {l?.incoming.map((p) => (
          <div key={p.user_id} className="flex gap-px">
            <div className="flex-1 min-w-0">{person(p, p.shared_events ? `${plural(p.shared_events, "event")} together` : "Asked you", "incoming")}</div>
            <button type="button" className="bg-t1-accent text-t1-ink px-4 t1-label text-t1-ink!" onClick={() => run(p.user_id, () => respondFriend(p.user_id, true))}>Accept</button>
            <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover px-4 t1-label" onClick={() => run(p.user_id, () => respondFriend(p.user_id, false))}>Ignore</button>
          </div>
        ))}
        {l && <Section title="Friends" count={l.friends.length} />}
        {l && !l.friends.length && (
          <Notice tone="info">No friends yet. Friends see what you share with them, show up first in Add players, and their trades are matched against your wants.</Notice>
        )}
        {l?.friends.map((p) => person(p, p.handle ? `@${p.handle}` : "Friend", "friend"))}
        {l && l.outgoing.length > 0 && <Section title="Sent" count={l.outgoing.length} />}
        {l?.outgoing.map((r) => {
          const cancel = { label: "Cancel", onClick: () => run(r.key, () => cancelSent(r)) };
          if (r.person) return person(r.person, "Requested", "requested", cancel);
          // Asked by email: only the address (the server never says whose account it is).
          return <Row key={r.key} title={sentLabel(r)} detail={busy === r.key ? "Working…" : "Asked by email"} action={cancel} />;
        })}
        {l && l.blocked.length > 0 && <Section title="Blocked" count={l.blocked.length} />}
        {l?.blocked.map((p) => person(p, "Can't see you or ask you", "blocked", { label: "Unblock", onClick: () => run(p.user_id, () => blockUser(p.user_id, false)) }))}
      </div>
      <PersonMenu person={menuFor?.p ?? null} from={menuFor?.from ?? "friends"} onClose={() => setMenuFor(null)} />
    </Screen>
  );
}

/** Add a friend: people you've played with first; a name also finds public profiles; email never says whether an account exists. */
export function FriendAddScreen({ onBack }: { onBack: () => void }) {
  return <Gate title="Add a friend" onBack={onBack}>{() => <FriendAddBody onBack={onBack} />}</Gate>;
}

function FriendAddBody({ onBack }: { onBack: () => void }) {
  const [query, setQuery] = useState("");
  const [people, setPeople] = useState<Person[] | null>(null);
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [menuFor, setMenuFor] = useState<PersonRef | null>(null);
  const load = (q: string) => searchPeople(q).then(setPeople, (e) => { setError(errorMessage(e)); setPeople((p) => p ?? []); });
  useEffect(() => {
    const t = window.setTimeout(() => void load(query), query ? 300 : 0);
    return () => window.clearTimeout(t);
  }, [query]);
  const emailValid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.trim());
  const ask = async (p: Person) => {
    setBusy(true);
    try {
      const status = await requestFriend(p.user_id, query ? "search" : "played_with");
      setNotice(status === "friends" ? `You and ${p.display_name} are friends.` : `Asked ${p.display_name}.`);
      await load(query);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  const sendEmail = async () => {
    const address = email.trim();
    setBusy(true);
    try {
      await requestFriendByEmail(address);
      setEmail("");
      setNotice(`If ${address} has a Table 1 account, they'll get your request.`);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Screen>
      <Bar title="Add a friend" subtitle="They accept to become friends" onBack={onBack} />
      <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Name or handle"
             className="bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60" />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {error && <Notice tone="error">{error}</Notice>}
        {notice && <Notice tone="info">{notice}</Notice>}
        <div className="bg-t1-surface px-4 py-2 t1-label">{query ? "Matches" : "Played with you"}</div>
        {people === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {people?.length === 0 && (
          <Notice tone="info">{query ? `No one you've played with or with a public profile matches "${query}".`
                                     : "People you play events with show up here. Until then, add a friend by email below."}</Notice>
        )}
        {people?.map((p) => {
          const detail = [p.handle ? `@${p.handle}` : null, p.shared_events ? `${plural(p.shared_events, "event")} together` : "Public profile"]
            .filter(Boolean).join(" · ");
          const rel = p.relation ?? "none";
          return (
            <PersonRow key={p.user_id} person={{ userId: p.user_id, displayName: p.display_name, relation: rel }} onMenu={setMenuFor}>
              <Row title={p.display_name} detail={detail} avatar={<Avatar name={p.display_name} userId={p.user_id} opens="friend_search" />}
                   value={rel === "friend" ? "Friends" : rel === "requested" ? "Requested" : undefined} accentValue={rel === "friend"}
                   action={rel === "none" || rel === "incoming" ? { label: rel === "incoming" ? "Accept" : "Add", onClick: () => void ask(p), disabled: busy } : undefined} />
            </PersonRow>
          );
        })}
        <div className="bg-t1-surface px-4 py-2 t1-label">By email</div>
        <div className="flex gap-px">
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="name@example.com"
                 onKeyDown={(e) => e.key === "Enter" && emailValid && void sendEmail()}
                 className="flex-1 min-w-0 bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60" />
          <button type="button" disabled={!emailValid || busy} onClick={() => void sendEmail()}
                  className="bg-t1-accent text-t1-ink px-6 text-[11px] uppercase tracking-[1px] disabled:bg-t1-surface disabled:text-t1-muted">Ask</button>
        </div>
        <Notice tone="info">Works for people who already have a Table 1 account.</Notice>
      </div>
      <PersonMenu person={menuFor} from="search" onClose={() => setMenuFor(null)} changed={() => void load(query)} />
    </Screen>
  );
}

/* ── profile ─────────────────────────────────────────────────────────── */

export function ProfileScreen(props: {
  userId: string; onBack: () => void; onSection: (kind: SectionKind, id: string | null) => void; onMatch: () => void; onSharing: () => void;
  onFriends: () => void; onRanking: (id: string) => void;
}) {
  return <Gate title="Profile" onBack={props.onBack}>{() => <ProfileBody key={props.userId} {...props} />}</Gate>;
}

function ProfileBody({ userId, onBack, onSection, onMatch, onSharing, onFriends, onRanking }: {
  userId: string; onBack: () => void; onSection: (kind: SectionKind, id: string | null) => void; onMatch: () => void; onSharing: () => void;
  onFriends: () => void; onRanking: (id: string) => void;
}) {
  const [own, setD] = useState<ProfileData | null>(null);
  const [match, setMatch] = useState<TradeMatch | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [menu, setMenu] = useState(false);
  const [busy, setBusy] = useState(false);
  /** Your own profile: You (2), as a friend (1) or as anyone (0) would see it (contract § UX rules 5). */
  const [as, setAs] = useState(2);
  const sharing = useFriends().sharing;
  useEffect(() => { if (own?.relation === "self") void loadSharing(); }, [own?.relation]);
  const d = own && own.relation === "self" && as < 2 && sharing ? viewAs(own, sharing, as) : own;
  const load = async (first = false) => {
    try {
      const p = await fetchProfile(userId);
      if (first) captureProfile(p);
      setD(p);
      setError(null);
      if (p.relation !== "self" && p.visible) setMatch(await matchWith(userId).catch(() => null));
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  useEffect(() => void load(true), [userId]);
  const run = (work: () => Promise<unknown>) => {
    setBusy(true);
    work().then(() => load()).catch((e) => setError(errorMessage(e))).finally(() => setBusy(false));
  };
  const s = d?.sections;
  const rec = s?.record;
  const sub = own?.relation === "self" && as < 2 ? `As ${as === 1 ? "a friend" : "anyone"} sees it` : d ? ({ self: "You", friend: "Friend", requested: "Requested", incoming: "Wants to be friends", blocked: "Blocked",
                    none: d.handle ? `@${d.handle}` : "Profile" } as const)[d.relation] : undefined;
  const open = (title: string, detail: string, kind: SectionKind, id: string | null = null) => (
    <Row key={`${kind}-${id ?? ""}`} title={title} detail={detail} onClick={() => { captureSection(kind); onSection(kind, id); }} />
  );
  return (
    <Screen>
      <Bar title={d?.display_name ?? "Profile"} subtitle={sub} onBack={onBack}
           right={d && d.relation !== "self" ? <button type="button" onClick={() => setMenu(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">More</button> : undefined} />
      {own?.relation === "self" && (
        <Segmented options={[{ value: "2", label: "You" }, { value: "1", label: "A friend" }, { value: "0", label: "Anyone" }]} value={String(as)}
                   onChange={(v) => {
                     const n = Number(v);
                     setAs(n);
                     if (n < 2) capture("profile_view_as", { as: n === 1 ? "friend" : "anyone" });
                   }} />
      )}
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!d && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {d && (
          <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-2">
            <Avatar name={d.display_name} userId={d.user_id} size={64} />
            <p className="text-[17px]">{d.display_name}</p>
            {d.handle && <p className="t1-label">@{d.handle}</p>}
            {rec && (
              <>
                <p className="text-[36px] tabular-nums tracking-[3px] text-t1-accent mt-2">
                  {rec.match_wins}-{rec.match_losses}{rec.match_draws ? `-${rec.match_draws}` : ""}
                </p>
                <p className="t1-label">
                  {plural(rec.match_wins + rec.match_losses + rec.match_draws, "match", "matches")} · {plural(rec.events_played, "event")}
                </p>
              </>
            )}
          </div>
        )}
        {d?.relation === "none" && <BigAction label="Add friend" tone="accent" busy={busy} onClick={() => run(() => requestFriend(userId, "profile"))} />}
        {d?.relation === "requested" && <Row title="Requested" detail="They haven't answered yet" action={{ label: "Cancel", onClick: () => run(() => removeFriend(userId)) }} />}
        {d?.relation === "incoming" && (
          <div className="flex gap-px">
            <button type="button" className="flex-1 bg-t1-accent text-t1-ink py-3.5 t1-label text-t1-ink!" onClick={() => run(() => respondFriend(userId, true))}>Accept</button>
            <button type="button" className="flex-1 bg-t1-surface py-3.5 t1-label" onClick={() => run(() => respondFriend(userId, false))}>Ignore</button>
          </div>
        )}
        {d?.relation === "blocked" && <Row title="Blocked" detail="They can't see you or ask you" action={{ label: "Unblock", onClick: () => run(() => blockUser(userId, false)) }} />}
        {d?.relation === "self" && as === 2 && (
          <>
            <Notice tone="info">You see everything here. Others see only what reaches them in Sharing.</Notice>
            <Row title="Sharing" detail="Choose who sees each part" onClick={onSharing} />
          </>
        )}
        {match && d?.relation !== "self" && (
          <>
            <Section title="Trade matches" />
            <Row title={matchShort(match)} detail="The cards, and Start a trade" onClick={onMatch}
                 value={match.have_usd + match.want_usd > 0 ? usdText(match.have_usd + match.want_usd) : undefined} />
          </>
        )}
        {d && !d.visible && <Notice tone="info">{d.relation === "blocked" ? `You blocked ${d.display_name}.` : `Only ${d.display_name}'s friends can see their profile.`}</Notice>}
        {d && d.visible && d.relation !== "self" && sectionCount(d) === 0 && <Notice tone="info">Nothing shared yet.</Notice>}
        {s?.friends && (() => {
          // View as can't know which of them each viewer would see, so the row doesn't open there.
          const asOther = own?.relation === "self" && as < 2;
          const detail = d?.relation === "self" ? (asOther || !sharing ? undefined : friendsOwnDetail(reachOf(sharing, "friends")))
            : friendsDetail(s.friends.mutual) ?? undefined;
          return <Row title="Friends" detail={detail}
                      onClick={asOther ? undefined : () => { capture("profile_section_opened", { section: "friends" }); onFriends(); }} />;
        })()}
        {s && (s.all_cards || s.for_trade || s.wants) && <Section title="Library" />}
        {s?.all_cards && open("All cards", [plural(s.all_cards.cards, "card"), d && profileValue(d) ? usdText(profileValue(d)!) : null].filter(Boolean).join(" · "), "all_cards")}
        {s?.for_trade && open("For trade", plural(s.for_trade.cards, "card"), "for_trade")}
        {s?.wants && open("Wants", `${plural(s.wants.cards, "card")} wanted`, "wants")}
        {!!s?.binders?.length && <Section title="Binders" count={s.binders.length} />}
        {s?.binders?.map((b) => open(b.name, [plural(b.cards, "card"), b.for_trade ? "For trade" : null].filter(Boolean).join(" · "), "binder", b.id))}
        {!!s?.decks?.length && <Section title="Decks" count={s.decks.length} />}
        {s?.decks?.map((l) => open(l.name, `${l.format} · ${plural(l.cards, "card")}`, "deck", l.id))}
        {!!s?.cubes?.length && <Section title="Cubes" count={s.cubes.length} />}
        {s?.cubes?.map((l) => open(l.name, plural(l.cards, "card"), "cube", l.id))}
        {!!s?.rankings?.length && <Section title="Rankings" count={s.rankings.length} />}
        {s?.rankings?.map((r) => (
          <Row key={`ranking-${r.id}`} title={r.subject.name} detail={profileRankingDetail(r)}
               onClick={() => { capture("profile_section_opened", { section: "ranking", kind: r.subject.kind }); onRanking(r.id); }} />
        ))}
      </div>
      <PersonMenu person={menu && d ? { userId, displayName: d.display_name, relation: d.relation } : null} from="profile"
                  onClose={() => setMenu(false)} changed={() => void load()} />
    </Screen>
  );
}

/** A profile's friends that reach you (contract § Friends on profiles): mutual friends first; a tap opens their
 *  profile, a long press or right-click the person menu. Nothing says how many are hidden. */
export function ProfileFriendsScreen(props: { userId: string; onBack: () => void; onProfile: (userId: string) => void }) {
  return <Gate title="Friends" onBack={props.onBack}>{() => <ProfileFriendsBody key={props.userId} {...props} />}</Gate>;
}

function ProfileFriendsBody({ userId, onBack, onProfile }: { userId: string; onBack: () => void; onProfile: (userId: string) => void }) {
  const [people, setPeople] = useState<Person[] | null>(null);
  const [name, setName] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [menuFor, setMenuFor] = useState<PersonRef | null>(null);
  const load = async (first = false) => {
    try {
      const rows = await fetchProfileFriends(userId);
      if (first) capture("profile_friends_viewed", { people: rows.length, mutual: rows.filter((r) => r.mutual).length });
      setPeople(rows);
      setError(null);
    } catch {
      setError("This isn't available.");
    }
  };
  useEffect(() => {
    void load(true);
    fetchProfile(userId).then((p) => setName(p.display_name)).catch(() => undefined);
  }, [userId]);
  return (
    <Screen>
      <Bar title="Friends" subtitle={name ?? undefined} onBack={onBack} />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!people && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {people && !people.length && <Notice tone="info">No friends to show.</Notice>}
        {people?.map((p) => (
          <PersonRow key={p.user_id} person={{ userId: p.user_id, displayName: p.display_name, relation: p.relation ?? "none" }}
                     onMenu={(ref) => { if (p.relation !== "self") setMenuFor(ref); }}>
            <Row title={p.display_name} detail={friendRowDetail(p) ?? undefined} avatar={<Avatar name={p.display_name} userId={p.user_id} />}
                 onClick={() => { capture("person_tapped", { from: "profile_friends" }); onProfile(p.user_id); }} />
          </PersonRow>
        ))}
      </div>
      <PersonMenu person={menuFor} from="profile" onClose={() => setMenuFor(null)} changed={() => void load()} />
    </Screen>
  );
}

function captureProfile(p: ProfileData) {
  capture("profile_viewed", { relation: p.relation, sections: sectionCount(p) });
}
function captureSection(kind: SectionKind) {
  capture("profile_section_opened", { section: kind });
}

interface Group {
  key: string; oracle: number; cover: number | null; coverFinish: Finish; name: string; norm: string; type: string; qty: number;
  /** Copies per printing and finish, oldest printing first: the rows a card opens into. */
  parts: Part[];
}

/** Binders, all cards, for trade and wants: one group per card, by name; wants for any printing show the card's
 *  default printing. (Decks and cubes go through the list lines instead.) */
export function groupProfileCards(rows: ProfileCard[], c: Catalog): Group[] {
  const by = new Map<string, Group & { coverQty: number }>();
  for (const r of rows) {
    let p = r.cardId ? c.printingIndex.get(r.cardId) ?? null : null;
    let oi = p != null ? c.pOracle[p] : -1;
    if (oi < 0 && r.oracleId) {
      oi = oracleIndexById(c, r.oracleId);
      if (oi >= 0) p = coverPrinting(c, oi);
    }
    const key = oi >= 0 ? c.oId[oi] : r.cardId ?? r.oracleId ?? "?";
    const finish: Finish = r.finish ?? "nonfoil";
    const g = by.get(key) ?? { key, oracle: oi, cover: p, coverQty: 0, coverFinish: finish, name: oi >= 0 ? c.oName[oi] : "Card not in local data yet",
                               norm: oi >= 0 ? c.oNorm[oi] : "", type: oi >= 0 ? c.oType[oi] : "", qty: 0, parts: [] };
    g.qty += r.qty;
    if (p != null && r.qty > g.coverQty) { g.cover = p; g.coverQty = r.qty; g.coverFinish = finish; }
    addPart(g.parts, p != null ? c.pId[p] : r.cardId ?? key, finish, r.qty, p);
    by.set(key, g);
  }
  for (const g of by.values()) sortParts(c, g.parts);
  return [...by.values()].sort((a, b) => (a.norm < b.norm ? -1 : a.norm > b.norm ? 1 : 0));
}

const FINISH_NAME: Record<Finish, string> = { nonfoil: "Non-foil", foil: "Foil", etched: "Etched" };
const partTitle = (c: Catalog, pt: Part) =>
  [pt.p == null ? null : `${c.pSet[pt.p].toUpperCase()} #${c.pCn[pt.p]}`, pt.finish === "nonfoil" ? null : FINISH_NAME[pt.finish]].filter(Boolean).join(" · ");

/** The cards behind one shared section, read-only, in the View you pick (list, grid or stacks, like your own); tap
 *  opens the card (your own copies of it). Decks and cubes group by section, then by Group by, and add Export and
 *  Copy to my Library (contract/shared-lists-grouping-2026-10-20.md). */
export function ProfileCardsScreen(props: {
  userId: string; section: SectionKind; item: string | null; onBack: () => void; onCard: (oracleId: string) => void; onList: (listId: string) => void;
  onRankings?: (listId: string) => void; onFollowChanges?: (kind: "binder" | "deck" | "cube", id: string) => void;
}) {
  return <Gate title="Cards" onBack={props.onBack}>{() => <ProfileCardsBody {...props} />}</Gate>;
}

/** A share link's part (contract/share-links-2026-10-23.md): the same screen, its cards through the link. */
export interface LinkSource { token: string; data: SharedLinkData; signedIn: boolean; onSignIn: () => void }

/** Cards already in hand (an Insights example list): nothing to fetch, no owner, rows of its own above Export. */
export interface PresetSource { rows: ProfileCard[]; name: string; format: string; byline?: string; actions?: ReactNode }

export function ProfileCardsBody({ userId, section, item, onBack, onCard, onList, onRankings, onFollowChanges, link, preset }: {
  userId: string; section: SectionKind; item: string | null; onBack: () => void; onCard: (oracleId: string) => void; onList: (listId: string) => void;
  onRankings?: (listId: string) => void; onFollowChanges?: (kind: "binder" | "deck" | "cube", id: string) => void; link?: LinkSource;
  preset?: PresetSource;
}) {
  const { catalog, error: catError } = useCatalog();
  useListsData(); // your lists, so a copy lands in them (the dev demo's too)
  const follows = useFollows();
  const [rows, setRows] = useState<ProfileCard[] | null>(null);
  const [profile, setProfile] = useState<ProfileData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [q, setQ] = useState("");
  const [layout, setLayout] = useStoredLayout("table1.library.shared.layout", "table1.library.shared.grid");
  const kind = sharedListKind(section);
  const [listGrouping, setListGrouping] = useListGrouping(kind);
  const [cardsGrouping, setCardsGrouping] = useStoredGrouping(GROUPING_KEY.shared, "none", false);
  const [grouping, setGrouping] = kind ? [listGrouping, setListGrouping] : [cardsGrouping, setCardsGrouping];
  /** Sort the same way: decks and cubes with your own, everything else its own (all start on Name). */
  const [listSort, setListSort] = useListSort(kind);
  const [cardsSort, setCardsSort] = useStoredSort(SORT_KEY.shared, "shared");
  const [sort, setSort] = kind ? [listSort, setListSort] : [cardsSort, setCardsSort];
  const [printings, setPrintings] = useState<Disclosure>(COLLAPSED);
  const [exporting, setExporting] = useState(false);
  const [imaging, setImaging] = useState(false);
  const [copying, setCopying] = useState(false);
  const [boxRef, width] = useBoxWidth();
  useSearchUsed(q, "profile_cards");
  useEffect(() => {
    if (preset) { setRows(preset.rows); return; }
    if (link) {
      fetchSharedCards(link.token, section).then(setRows, (e) => { setError(errorMessage(e)); setRows([]); });
      return;
    }
    fetchProfileCards(userId, section, item).then(setRows, (e) => { setError(errorMessage(e)); setRows([]); });
    // The address carries ids only; the title, a list's format and its owner come from the profile.
    fetchProfile(userId).then(setProfile, () => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId, section, item, link?.token, preset?.rows]);
  const s = profile?.sections;
  const shared = [...(s?.binders ?? []), ...(s?.decks ?? []), ...(s?.cubes ?? [])].find((x) => x.id === item);
  const listFormat = preset ? preset.format : link ? (kind ? link.data.format ?? null : null) : kind && shared && "format" in shared ? shared.format : null;
  const name = preset ? preset.name : link ? sharedTitle(link.data)
    : shared?.name ?? ({ all_cards: "All cards", for_trade: "For trade", wants: "Wants" } as Record<string, string>)[section] ?? "Cards";
  /** Whose it is; null on your own profile (no Copy there: your deck screen has Duplicate). */
  const owner = preset ? null : link ? (link.data.mine ? null : link.data.owner.display_name) : profile && profile.relation !== "self" ? profile.display_name : null;
  const canCopy = !!owner && (!link || link.signedIn);
  /** Someone else's binder, deck or cube (contract/follows-2026-10-25.md); on a profile, once it says whose. */
  const followKind = section === "binder" || section === "deck" || section === "cube" ? section : null;
  const followable = !!followKind && !!item && !!onFollowChanges && (link ? !link.data.mine : !!profile && profile.relation !== "self");
  const entries = useMemo(() => (rows ? sharedEntries(rows) : []), [rows]);
  const lines = useMemo(() => (kind && catalog ? sortLines(regrouped(resolveLines(entries, kind, catalog), grouping), sort, catalog) : []),
                        [kind, catalog, entries, grouping, sort]);
  const groups = useMemo(() => (!kind && catalog && rows
    ? applySort(groupProfileCards(rows, catalog), sort, (g) => sortKeyOf(catalog, g.name, g.oracle, g.cover)) : []), [kind, catalog, rows, sort]);
  const searching = q.trim().length > 0;
  const cols = Math.max(3, Math.floor(width / 180));
  const tile = Math.floor((width - (cols - 1)) / cols);
  const title = (sec: { key: string; qty: number }) => `${groupLabel(grouping, sec.key)} · ${sec.qty}`;
  const sum = (xs: { qty: number }[]) => xs.reduce((n, x) => n + x.qty, 0);

  const copy = async () => {
    if (!kind || !listFormat) return;
    setCopying(true);
    try {
      onList(await createList(kind, name.slice(0, 60), listFormat, entries, copyNote(owner, name), "profile"));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setCopying(false);
    }
  };

  const grid = (cards: StackCardItem[]) => (
    <div className="grid gap-px shrink-0" style={{ gridTemplateColumns: `repeat(${cols}, ${tile}px)` }}>
      {cards.map((t) => <CardTile key={t.key} c={catalog!} p={t.p} name={t.name} qty={t.qty} width={tile} finish={t.finish} onClick={t.onClick} />)}
    </div>
  );

  /* decks and cubes */

  const lineTiles = (inGroup: Line[]): StackCardItem[] => lineGroups(inGroup).flatMap((cg) => {
    const lead = cg.lines[0];
    const onClick = () => lead.oracleId && onCard(lead.oracleId);
    if (!printings.all || cg.lines.length < 2) return [{ key: cg.id, p: lead.p, name: lead.name, qty: cg.qty, finish: lead.finish, onClick }];
    return cg.lines.map((l) => ({ key: `${l.board}|${l.cardId}|${l.finish}`, p: l.p, name: l.name, qty: l.qty, finish: l.finish, onClick }));
  });
  /** One card's lines in a section: a row, with its printings under a chevron when there are several. */
  const lineRows = (cg: LineGroup<Line>) => {
    const lead = cg.lines[0];
    const open = cg.lines.length > 1 && isOpen(printings, cg.id);
    return (
      <div key={cg.id} className="flex flex-col gap-px shrink-0">
        <div className="h-[60px]">
          <CardGroupRow open={open} parts={cg.lines.length}
                        onToggle={() => { setPrintings(toggleOne(printings, cg.id)); capture("printings_toggled", { expanded: !open, all: false, screen: "list" }); }}>
            <CardRow c={catalog!} p={lead.p} title={lead.name} detail={cg.lines.length > 1 ? `${cg.lines.length} printings · ${lead.type}` : lead.type}
                     value={cg.qty} finish={lead.finish} onClick={() => lead.oracleId && onCard(lead.oracleId)} />
          </CardGroupRow>
        </div>
        {open && cg.lines.map((l) => (
          <div key={`${l.cardId}|${l.finish}`} className="h-[60px]">
            <CardRow c={catalog!} p={l.p} indent finish={l.finish} value={l.qty} onClick={() => l.oracleId && onCard(l.oracleId)}
                     title={partTitle(catalog!, { cardId: l.cardId, finish: l.finish, qty: l.qty, p: l.p })} />
          </div>
        ))}
      </div>
    );
  };
  const listBody = (k: ListKind) => {
    const shown = searching ? lines.filter((x) => cardMatches(q, x.name, x.type)) : lines;
    return (<>
      {searching && !shown.length && !!lines.length && <Row title="No cards match" />}
      {BOARD_ORDER.filter((b) => shown.some((x) => x.board === b)).map((board) => {
        const inBoard = shown.filter((x) => x.board === board);
        const groupKeys = groupsOf(inBoard, grouping);
        return (
          <div key={board} className="flex flex-col gap-px shrink-0">
            <BoardHeader title={boardTitle(k, board)} count={sum(inBoard)} />
            {layout === "stacks" ? (
              <StackRows c={catalog!} boxWidth={width} stacks={groupKeys.map((g) => {
                const inGroup = inBoard.filter((x) => x.group === g);
                return { key: `${grouping}|${g}|${printings.all}`, title: title({ key: g, qty: sum(inGroup) }), cards: lineTiles(inGroup) };
              })} />
            ) : groupKeys.map((g) => {
              const inGroup = inBoard.filter((x) => x.group === g);
              return (
                <div key={g} className="flex flex-col gap-px shrink-0">
                  <Section title={groupLabel(grouping, g)} count={sum(inGroup)} />
                  {layout === "grid" ? grid(lineTiles(inGroup)) : lineGroups(inGroup).map(lineRows)}
                </div>
              );
            })}
          </div>
        );
      })}
    </>);
  };

  /* binders, all cards, for trade, wants */

  const groupTiles = (gs: Group[]): StackCardItem[] => gs.flatMap((g) => {
    const onClick = () => g.oracle >= 0 && onCard(g.key);
    if (!printings.all || g.parts.length < 2) return [{ key: g.key, p: g.cover, name: g.name, qty: g.qty, finish: g.coverFinish, onClick }];
    return g.parts.map((pt) => ({ key: `${g.key}|${pt.cardId}|${pt.finish}`, p: pt.p, name: g.name, qty: pt.qty, finish: pt.finish, onClick }));
  });
  const cardsBody = () => {
    const shown = searching ? groups.filter((g) => cardMatches(q, g.name, g.type)) : groups;
    const sections = groupSections(shown, grouping, (g) => keysOf(catalog!, g.oracle));
    return (<>
      {searching && !shown.length && !!groups.length && <Row title="No cards match" />}
      {layout === "stacks" ? (
        // Grouped: one stack per group; None: stacks of ten.
        <StackRows c={catalog!} boxWidth={width} stacks={grouping !== "none"
          ? sections.map((sec) => ({ key: `st|${sec.key}|${printings.all}`, title: title({ key: sec.key, qty: sum(sec.items) }), cards: groupTiles(sec.items) }))
          : (() => {
            const all = groupTiles(shown);
            return Array.from({ length: Math.ceil(all.length / 10) }, (_, i) => ({ key: `st|${printings.all}|${i}`, cards: all.slice(i * 10, i * 10 + 10) }));
          })()} />
      ) : sections.map((sec) => (
        <div key={sec.key} className="flex flex-col gap-px shrink-0">
          {grouping !== "none" && <Section title={groupLabel(grouping, sec.key)} count={sum(sec.items)} />}
          {layout === "grid" ? grid(groupTiles(sec.items)) : sec.items.map((g) => {
            const open = g.parts.length > 1 && isOpen(printings, g.key);
            return (
              <div key={g.key} className="flex flex-col gap-px shrink-0">
                <div className="h-[60px]">
                  <CardGroupRow open={open} parts={g.parts.length}
                                onToggle={() => { setPrintings(toggleOne(printings, g.key)); capture("printings_toggled", { expanded: !open, all: false, screen: "list" }); }}>
                    <CardRow c={catalog!} p={g.cover} title={g.name} detail={g.type} value={g.qty} finish={g.coverFinish} onClick={() => g.oracle >= 0 && onCard(g.key)} />
                  </CardGroupRow>
                </div>
                {open && g.parts.map((pt) => (
                  <div key={`${pt.cardId}|${pt.finish}`} className="h-[60px]">
                    <CardRow c={catalog!} p={pt.p} indent finish={pt.finish} value={pt.qty} title={partTitle(catalog!, pt)} onClick={() => g.oracle >= 0 && onCard(g.key)} />
                  </div>
                ))}
              </div>
            );
          })}
        </div>
      ))}
    </>);
  };

  return (
    <LibScreen width={layout === "list" ? "column" : "wide"}>
      <Bar title={link || preset ? name : profile ? `${profile.display_name} · ${name}` : "Cards"} subtitle={rows ? plural(sharedCardCount(rows, kind), "card") : undefined} onBack={onBack}
           right={<ViewButton layout={layout} onChange={setLayout} screen={`profile_${section}`} printings={printings} onPrintings={setPrintings}
                              grouping={grouping} onGrouping={setGrouping} list={!!kind}
                              sort={sort} onSort={setSort} sorts={kind ? "list" : "shared"} />} />
      {(error || catError) && <Notice tone="error">{error ?? catError}</Notice>}
      <Field label="Search these cards" value={q} onChange={setQ} placeholder="Name or type" />
      <div ref={boxRef} className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {link && !searching && (
          <Row title={sharedByline(link.data)} avatar={<Avatar name={link.data.owner.display_name} size={24} />} />
        )}
        {preset?.byline && !searching && <Notice tone="info">{preset.byline}</Notice>}
        {(!catalog || !rows) && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {rows?.length === 0 && !error && <Notice tone="info">Nothing here.</Notice>}
        {followable && followKind && item && !searching && (
          <FollowRows kind={followKind} id={item} title={name} owner={owner} token={link?.token} signedIn={!link || link.signedIn}
                      onSignIn={link?.onSignIn} onChanges={() => onFollowChanges!(followKind, item)} />
        )}
        {preset?.actions && !searching && preset.actions}
        {kind && catalog && !!rows?.length && !searching && (<>
          <Row title="Export" detail={kind === "deck" ? "Text, Arena, MTGO, download or copy" : "Text, Cube Cobra, download or copy"}
               onClick={() => setExporting(true)} />
          {kind === "deck" && <Row title="Deck image" detail="The cards as a picture, to save or share" onClick={() => setImaging(true)} />}
          {item && listFormat && (
            <SpiceRow listId={item} token={link?.token} kind={kind} format={listFormat} name={name} onCard={onCard}
                      demo={entries.flatMap((e) => {
                        const p = catalog.printingIndex.get(e.cardId);
                        if (p == null) return [];
                        const oi = catalog.pOracle[p];
                        return [{ oracleId: catalog.oId[oi], name: catalog.oName[oi], qty: e.qty, board: e.board, basic: catalog.oType[oi].startsWith("Basic") }];
                      })} />
          )}
          {/* Through a link you can rank a cube once you follow it (contract/owned-by-card-2026-10-31.md § 3): the row
              shows the moment Follow succeeds. */}
          {kind === "cube" && item && onRankings && !preset && (!link || follows.states[item]?.following) &&
            <RankingsRow listId={item} onOpen={() => onRankings(item)} />}
          {canCopy && listFormat && (
            <Row title={copying ? "Copying…" : "Copy to my Library"} detail={kind === "deck" ? "A new private deck with these cards" : "A new cube with these cards"}
                 onClick={copying ? undefined : () => void copy()} />
          )}
        </>)}
        {catalog && rows && (kind ? listBody(kind) : cardsBody())}
        {link && !link.signedIn && rows && <Row title="Make your own on Table 1" detail="Sign in to copy decks, track your collection and trade" onClick={link.onSignIn} />}
      </div>
      {exporting && kind && catalog && <ExportScreen name={name} kind={kind} entries={entries} catalog={catalog} from="profile" onClose={() => setExporting(false)} />}
      {imaging && kind === "deck" && catalog && <DeckImageScreen name={name} format={listFormat ?? ""} entries={entries} catalog={catalog} owner={owner} from="profile" onClose={() => setImaging(false)} />}
    </LibScreen>
  );
}

/* ── sharing ─────────────────────────────────────────────────────────── */

export function SharingScreen({ onBack }: { onBack: () => void }) {
  return <Gate title="Sharing" onBack={onBack}>{() => <SharingBody onBack={onBack} />}</Gate>;
}

function SharingControl({ title, detail, own, parent, settings, isProfile, onChange }: {
  title: string; detail: string; own: Visibility | null; parent: { name: string; value: Visibility } | null; settings: Sharing;
  isProfile?: boolean; onChange: (v: Visibility | null) => void;
}) {
  const eff = own ?? parent?.value ?? "private";
  const isCapped = !isProfile && capped(settings, eff);
  const options = [...(parent ? [{ value: "same", label: "Same" }] : []), ...VISIBILITIES.map((v) => ({ value: v as string, label: VIS_LABEL[v] }))];
  return (
    <div className="flex flex-col gap-px">
      <Row title={title} detail={detail} value={VIS_LABEL[eff]} accentValue={eff !== "private"} />
      <Segmented options={options} value={own ?? "same"} onChange={(v) => onChange(v === "same" ? null : (v as Visibility))} />
      {own == null && parent && <Notice tone="info">Same as {parent.name}: {VIS_LABEL[parent.value].toLowerCase()}.</Notice>}
      {isCapped && (
        <Notice tone="info">
          Shows to {reach(settings, eff) === "friends" ? "friends" : "you"} only: your profile is {VIS_LABEL[settings.profile].toLowerCase()}.
        </Notice>
      )}
    </div>
  );
}

function SharingBody({ onBack }: { onBack: () => void }) {
  const st = useFriends();
  const [open, setOpen] = useState<string | null>(null);
  const { ask, dialog } = useWideningConfirm();
  useEffect(() => void loadSharing(), []);
  const s = st.sharing;
  // Widening asks first, narrowing never does (contract § UX rules 4).
  const part = (p: SharePart) => s && (
    <SharingControl key={p} title={PART_LABEL[p]} detail={PART_DETAIL[p]} own={inherits(p) ? s[p] ?? null : effective(s, p)} settings={s}
                    isProfile={p === "profile"}
                    parent={inherits(p) ? { name: "Library", value: s.library } : null}
                    onChange={(v) => ask(widening(s, withPart(s, p, v)), () => void setPart(p, v))} />
  );
  const items = (kind: ShareItem["kind"]) => {
    if (!s) return null;
    const list = s.items.filter((i) => i.kind === kind);
    if (!list.length) return null;
    const own = list.filter((i) => i.visibility != null).length;
    const group = groupOf(kind);
    return (
      <>
        <Row title={`Each ${kind}`} value={open === kind ? "Close" : "Open"} onClick={() => setOpen(open === kind ? null : kind)}
             detail={`${plural(list.length, kind)} · ${own ? `${own} set on their own` : `all ${VIS_LABEL[effective(s, group)].toLowerCase()}`}`} />
        {open === kind && list.map((i) => (
          <SharingControl key={i.id} title={i.name} detail={i.for_trade ? "For trade" : kind[0].toUpperCase() + kind.slice(1)} own={i.visibility}
                          settings={s} parent={{ name: PART_LABEL[group], value: effective(s, group) }}
                          onChange={(v) => ask(widening(s, withItem(s, i, v)), () => void setItem(i, v))} />
        ))}
        {open === kind && list.length > 0 && (
          <Notice tone="info">{list.map((i) => `${i.name}: ${VIS_LABEL[reach(s, effectiveItem(s, i))].toLowerCase()}`).join(" · ")}</Notice>
        )}
      </>
    );
  };
  return (
    <Screen>
      <Bar title="Sharing" subtitle={s ? sharingSummary(s) : undefined} onBack={onBack} />
      {st.error && <Notice tone="error">{st.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!s && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {s && (
          <>
            <Notice tone="info">{seesLine(s, 1)}</Notice>
            <Notice tone="info">{seesLine(s, 0)}</Notice>
            {part("profile")}
            {part("record")}
            {part("rankings")}
            <Section title="Friends" />
            {part("friends")}
            {part("listed")}
            <Section title="Library" />
            {part("library")}
            {LIBRARY_PARTS.map((p) => (
              <div key={p} className="flex flex-col gap-px">
                {part(p)}
                {p === "binders" && items("binder")}
                {p === "decks" && items("deck")}
                {p === "cubes" && items("cube")}
              </div>
            ))}
          </>
        )}
      </div>
      {dialog}
    </Screen>
  );
}

/* ── matches ─────────────────────────────────────────────────────────── */

export function TradeMatchesScreen(props: { onBack: () => void; onOpen: (userId: string) => void; onFriends: () => void; onSharing: () => void }) {
  return <Gate title="Trade matches" onBack={props.onBack}>{() => <TradeMatchesBody {...props} />}</Gate>;
}

function TradeMatchesBody({ onBack, onOpen, onFriends, onSharing }: { onBack: () => void; onOpen: (userId: string) => void; onFriends: () => void; onSharing: () => void }) {
  const st = useFriends();
  useEffect(() => {
    void loadMatches().then(() => {
      const m = friendsNow().matches;
      if (m) capture("trade_matches_viewed", { people: m.length, have: m.reduce((n, x) => n + x.have_copies, 0), want: m.reduce((n, x) => n + x.want_copies, 0) });
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const m = st.matches;
  const me = useLibrarySession().userId;
  const [offered, setOffered] = useState(() => offerAnswered("matches", me));
  const [offering, setOffering] = useState(false);
  const sh = st.sharing;
  useEffect(() => { if (!sh) void loadSharing(); }, [sh]);
  // With For trade and Wants both private, no one can match with you (§ UX rules 8): offer once.
  const offer = !offered && !!sh && reachOf(sh, "for_trade") === "private" && reachOf(sh, "wants") === "private";
  return (
    <Screen>
      <Bar title="Trade matches" subtitle={m ? plural(m.length, "person", "people") : undefined} onBack={onBack} />
      {st.error && <Notice tone="error">{st.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Notice tone="info">Your wants against friends' for-trade cards, and theirs against yours. People you've played with count when they share with anyone.</Notice>
        {offer && <Row title="Share For trade and Wants with friends" detail="So friends' trade matches can find you" onClick={() => setOffering(true)} />}
        {!m && <div className="bg-t1-surface px-4 py-4 t1-label">Looking…</div>}
        {m?.length === 0 && (
          <>
            <Notice tone="info">No matches yet. Matches show once friends share For trade or Wants, and you have wants or a for-trade binder.</Notice>
            <Row title="Friends" detail="Add friends to trade with" onClick={onFriends} />
            <Row title="Sharing" detail="Share your For trade and Wants" onClick={onSharing} />
          </>
        )}
        {m?.map((x) => <MatchRow key={x.user_id} x={x} onOpen={onOpen} />)}
      </div>
      {offering && (
        <SharingOfferDialog offer="matches" userId={me} title="Share For trade and Wants with friends?" parts={["for_trade", "wants"]}
                            message="Friends can see your for-trade copies and your wishlist (never your max prices), and trade matches can find you."
                            onDone={() => { setOffering(false); setOffered(true); }} />
      )}
    </Screen>
  );
}

export function TradeMatchScreen(props: { userId: string; onBack: () => void; onProfile: () => void; onCard: (oracleId: string) => void; onTrade: (id: string) => void }) {
  return <Gate title="Trade match" onBack={props.onBack}>{() => <TradeMatchBody {...props} />}</Gate>;
}

function TradeMatchBody({ userId, onBack, onProfile, onCard, onTrade }: {
  userId: string; onBack: () => void; onProfile: () => void; onCard: (oracleId: string) => void; onTrade: (id: string) => void;
}) {
  const st = useFriends();
  const { catalog } = useCatalog();
  const [match, setMatch] = useState<TradeMatch | null>(st.matches?.find((x) => x.user_id === userId) ?? null);
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [more, setMore] = useState(false);
  const [menuFor, setMenuFor] = useState<PersonRef | null>(null);
  useEffect(() => {
    matchWith(userId).then(setMatch, (e) => setError(errorMessage(e))).finally(() => setLoaded(true));
  }, [userId]);
  usePrices(useMemo(() => (match ? [...match.they_have, ...match.they_want].map((l) => l.card_id) : null), [match]));
  const start = async () => {
    if (!match) return;
    setBusy(true);
    try {
      onTrade(await startTradeFromMatch(match));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  const side = (title: string, lines: MatchLine[], value: number, have: boolean) => (
    <>
      <Section title={title + (value > 0 ? ` · ${usdText(value)}` : "")} />
      {!lines.length && <Notice tone="info">{have ? "Nothing of theirs that you want." : "Nothing of yours that they want."}</Notice>}
      {catalog && lines.map((l) => {
        const p = catalog.printingIndex.get(l.card_id) ?? null;
        const oi = p != null ? catalog.pOracle[p] : -1;
        const tier = wantTier(l.want);
        const want = tier === "exact" ? (have ? "You want this printing and finish" : "Wants this printing and finish")
          : tier === "printing" ? (have ? "You want this printing" : "Wants this printing") : (have ? "You want any printing" : "Wants any printing");
        const detail = [p != null ? `${catalog.pSet[p].toUpperCase()} ${catalog.pCn[p]}` : null, l.finish === "nonfoil" ? null : l.finish,
                        l.condition === "NM" ? null : l.condition, l.lang === "en" ? null : l.lang.toUpperCase(), want].filter(Boolean).join(" · ");
        const price = l.usd ?? usdPrice(l.card_id, l.finish, l.condition);
        return (
          <div key={`${l.card_id}|${l.finish}|${l.condition}|${l.lang}`} style={{ height: 60 }}>
            <CardRow c={catalog} p={p} title={oi >= 0 ? catalog.oName[oi] : "Card not in local data yet"} detail={detail}
                     value={l.over_max ? `${l.qty} · over your max` : `${l.qty}${price != null ? ` · ${usdText(price)}` : ""}`} warn={!!l.over_max}
                     onClick={() => oi >= 0 && onCard(catalog.oId[oi])} />
          </div>
        );
      })}
    </>
  );
  return (
    <LibScreen>
      <Bar title={match?.display_name ?? "Trade match"} subtitle={match ? (match.friend ? "Friend" : "Played with you") : undefined} onBack={onBack}
           right={<button type="button" onClick={() => setMore(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">More</button>} />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!match && <div className="bg-t1-surface px-4 py-4 t1-label">{loaded ? "Nothing matches with them right now." : "Looking…"}</div>}
        {match && <Notice tone="info">{matchSummary(match)}</Notice>}
        {match && side(`They have · ${match.have_copies} you want`, match.they_have, match.have_usd, true)}
        {match && side(`They want · ${match.want_copies} you have`, match.they_want, match.want_usd, false)}
      </div>
      {match && <BigAction label="Start a trade" tone="accent" busy={busy} onClick={() => void start()} />}
      {more && (
        <Menu title={match?.display_name ?? "Trade match"} onClose={() => setMore(false)} items={[
          { title: "Profile", onClick: onProfile },
          ...(match ? [{ title: "Block or report", detail: "They won't know", onClick: () => setMenuFor({ userId, displayName: match.display_name, relation: match.friend ? "friend" : "none" }) }] : []),
        ]} />
      )}
      <PersonMenu person={menuFor} from="trade_match" onClose={() => setMenuFor(null)} />
    </LibScreen>
  );
}
