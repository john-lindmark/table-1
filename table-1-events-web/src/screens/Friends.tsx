import { useEffect, useMemo, useState } from "react";
import { Avatar } from "../components/Avatar";
import { BigAction, Bar, Dialog, Menu, Notice, Row, Screen, Section, Segmented, type MenuItem } from "../components/kit";
import { errorMessage } from "../lib/api";
import { coverPrinting, normName, oracleIndexById, type Catalog } from "../lib/catalog";
import { useCollection } from "../lib/collection";
import { useBinders } from "../lib/binders";
import { usePrices, usdPrice, usdText } from "../lib/prices";
import {
  LIBRARY_PARTS, PART_DETAIL, PART_LABEL, VIS_LABEL, VISIBILITIES, blockUser, capped, effective, effectiveItem, fetchProfile,
  fetchProfileCards, groupOf, inherits, loadFriends, loadMatches, loadSharing, matchShort, matchSummary, matchWith, reach,
  cancelSent, profileValue, removeFriend, requestFriend, requestFriendByEmail, respondFriend, searchPeople, sectionCount, sentLabel,
  setItem, setPart, sharingSummary,
  startTradeFromMatch, useFriends, friendsNow, wantTier, type MatchLine, type Person, type ProfileCard, type ProfileData, type SectionKind,
  type SharePart, type ShareItem, type Sharing, type TradeMatch, type Visibility,
} from "../lib/friends";
import { startFriendsDemo } from "../lib/friendsDemo";
import { capture } from "../lib/telemetry";
import { CardRow, LibScreen, useCatalog, useLibrarySession } from "./Library";

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
export function FriendsAccountRows({ onFriends, onSharing, onProfile }: { onFriends: () => void; onSharing: () => void; onProfile: () => void }) {
  const s = useFriends();
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
    </>
  );
}

/** Library home: who has what you want, who wants what you have. */
export function TradeMatchesRow({ onClick }: { onClick: () => void }) {
  const { ready, session } = useFriendsReady();
  const s = useFriends();
  useEffect(() => {
    if (ready && session) void loadMatches();
  }, [ready, session]);
  const m = s.matches ?? [];
  const have = m.reduce((n, x) => n + x.have_copies, 0), want = m.reduce((n, x) => n + x.want_copies, 0);
  return (
    <Row title="Trade matches" value={m.length || undefined} onClick={onClick}
         detail={!s.matches ? "Friends' trades against your wants" : !m.length ? "None yet · friends' trades against your wants"
                 : `${plural(m.length, "person", "people")} · have ${have} · want ${want}`} />
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
  useEffect(() => void loadFriends(), []);
  const run = (id: string, work: () => Promise<unknown>) => {
    setBusy(id);
    setFail(null);
    work().catch((e) => setFail(errorMessage(e))).finally(() => setBusy(null));
  };
  const l = s.list;
  const person = (p: Person, detail: string, action?: { label: string; onClick: () => void }) => (
    <Row key={p.user_id} title={p.display_name} detail={busy === p.user_id ? "Working…" : detail}
         avatar={<Avatar name={p.display_name} userId={p.user_id} />} action={action}
         onClick={action ? undefined : () => onProfile(p.user_id)} />
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
            <div className="flex-1 min-w-0">{person(p, "Asked you")}</div>
            <button type="button" className="bg-t1-accent text-t1-ink px-4 t1-label text-t1-ink!" onClick={() => run(p.user_id, () => respondFriend(p.user_id, true))}>Accept</button>
            <button type="button" className="bg-t1-surface hover:bg-t1-surface-hover px-4 t1-label" onClick={() => run(p.user_id, () => respondFriend(p.user_id, false))}>Decline</button>
          </div>
        ))}
        {l && <Section title="Friends" count={l.friends.length} />}
        {l && !l.friends.length && (
          <Notice tone="info">No friends yet. Friends see what you share with them, show up first in Add players, and their trades are matched against your wants.</Notice>
        )}
        {l?.friends.map((p) => person(p, p.handle ? `@${p.handle}` : "Friend"))}
        {l && l.outgoing.length > 0 && <Section title="Sent" count={l.outgoing.length} />}
        {l?.outgoing.map((r) => {
          const cancel = { label: "Cancel", onClick: () => run(r.key, () => cancelSent(r)) };
          if (r.person) return person(r.person, "Requested", cancel);
          // Asked by email: only the address (the server never says whose account it is).
          return <Row key={r.key} title={sentLabel(r)} detail={busy === r.key ? "Working…" : "Asked by email"} action={cancel} />;
        })}
        {l && l.blocked.length > 0 && <Section title="Blocked" count={l.blocked.length} />}
        {l?.blocked.map((p) => person(p, "Can't see you or ask you", { label: "Unblock", onClick: () => run(p.user_id, () => blockUser(p.user_id, false)) }))}
      </div>
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
            <Row key={p.user_id} title={p.display_name} detail={detail} avatar={<Avatar name={p.display_name} userId={p.user_id} />}
                 value={rel === "friend" ? "Friends" : rel === "requested" ? "Requested" : undefined} accentValue={rel === "friend"}
                 action={rel === "none" || rel === "incoming" ? { label: rel === "incoming" ? "Accept" : "Add", onClick: () => void ask(p), disabled: busy } : undefined} />
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
    </Screen>
  );
}

/* ── profile ─────────────────────────────────────────────────────────── */

export function ProfileScreen(props: {
  userId: string; onBack: () => void; onSection: (kind: SectionKind, id: string | null) => void; onMatch: () => void; onSharing: () => void;
}) {
  return <Gate title="Profile" onBack={props.onBack}>{() => <ProfileBody key={props.userId} {...props} />}</Gate>;
}

function ProfileBody({ userId, onBack, onSection, onMatch, onSharing }: {
  userId: string; onBack: () => void; onSection: (kind: SectionKind, id: string | null) => void; onMatch: () => void; onSharing: () => void;
}) {
  const [d, setD] = useState<ProfileData | null>(null);
  const [match, setMatch] = useState<TradeMatch | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [menu, setMenu] = useState(false);
  const [confirm, setConfirm] = useState<"unfriend" | "block" | null>(null);
  const [busy, setBusy] = useState(false);
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
  const menuItems: MenuItem[] = d ? [
    ...(d.relation === "friend" ? [{ title: "Unfriend", onClick: () => setConfirm("unfriend") }] : []),
    d.relation === "blocked" ? { title: "Unblock", onClick: () => run(() => blockUser(userId, false)) }
                             : { title: "Block", detail: "They can't ask you or see anything of yours", onClick: () => setConfirm("block") },
  ] : [];
  const sub = d ? ({ self: "You", friend: "Friend", requested: "Requested", incoming: "Wants to be friends", blocked: "Blocked",
                    none: d.handle ? `@${d.handle}` : "Profile" } as const)[d.relation] : undefined;
  const open = (title: string, detail: string, kind: SectionKind, id: string | null = null) => (
    <Row key={`${kind}-${id ?? ""}`} title={title} detail={detail} onClick={() => { captureSection(kind); onSection(kind, id); }} />
  );
  return (
    <Screen>
      <Bar title={d?.display_name ?? "Profile"} subtitle={sub} onBack={onBack}
           right={d && d.relation !== "self" ? <button type="button" onClick={() => setMenu(true)} className="t1-label hover:text-t1-text px-2 py-1 -my-1">More</button> : undefined} />
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
            <button type="button" className="flex-1 bg-t1-surface py-3.5 t1-label" onClick={() => run(() => respondFriend(userId, false))}>Decline</button>
          </div>
        )}
        {d?.relation === "blocked" && <Row title="Blocked" detail="They can't see you or ask you" action={{ label: "Unblock", onClick: () => run(() => blockUser(userId, false)) }} />}
        {d?.relation === "self" && (
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
        {d && !d.visible && (
          <Notice tone="info">{d.relation === "blocked" ? `You blocked ${d.display_name}.` : `Only ${d.display_name}'s friends can see their profile.`}</Notice>
        )}
        {d && d.visible && d.relation !== "self" && sectionCount(d) === 0 && (
          <Notice tone="info">{d.display_name} hasn't shared anything with you yet.</Notice>
        )}
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
      </div>
      {menu && d && <Menu title={d.display_name} items={menuItems} onClose={() => setMenu(false)} />}
      {confirm && d && (
        <Dialog title={confirm === "block" ? `Block ${d.display_name}?` : `Unfriend ${d.display_name}?`} tone="danger" cancelLabel="Cancel"
                confirmLabel={confirm === "block" ? "Block" : "Unfriend"} busy={busy}
                message={confirm === "block" ? "They won't be told. They can't ask you again or see anything of yours, even what's public."
                                             : "You'll stop seeing what each of you shares with friends."}
                onCancel={() => setConfirm(null)}
                onConfirm={() => {
                  const c = confirm;
                  setConfirm(null);
                  run(() => (c === "block" ? blockUser(userId, true) : removeFriend(userId)));
                }} />
      )}
    </Screen>
  );
}

function captureProfile(p: ProfileData) {
  capture("profile_viewed", { relation: p.relation, sections: sectionCount(p) });
}
function captureSection(kind: SectionKind) {
  capture("profile_section_opened", { section: kind });
}

const BOARD: Record<string, string> = { main: "Main", side: "Sideboard", commander: "Commander", maybe: "Considering" };
const BOARD_ORDER = ["commander", "main", "", "side", "maybe"];

interface Group { key: string; oracle: number; cover: number | null; name: string; norm: string; type: string; qty: number }

/** Groups rows by board (decks and cubes) and card; wants for any printing show the card's default printing. */
export function groupProfileCards(rows: ProfileCard[], c: Catalog): { board: string; cards: Group[] }[] {
  const boards = new Map<string, Map<string, Group>>();
  for (const r of rows) {
    let p = r.cardId ? c.printingIndex.get(r.cardId) ?? null : null;
    let oi = p != null ? c.pOracle[p] : -1;
    if (oi < 0 && r.oracleId) {
      oi = oracleIndexById(c, r.oracleId);
      if (oi >= 0) p = coverPrinting(c, oi);
    }
    const key = oi >= 0 ? c.oId[oi] : r.cardId ?? r.oracleId ?? "?";
    const by = boards.get(r.board ?? "") ?? new Map<string, Group>();
    const g = by.get(key) ?? { key, oracle: oi, cover: p, name: oi >= 0 ? c.oName[oi] : "Card not in local data yet",
                               norm: oi >= 0 ? c.oNorm[oi] : "", type: oi >= 0 ? c.oType[oi] : "", qty: 0 };
    g.qty += r.qty;
    by.set(key, g);
    boards.set(r.board ?? "", by);
  }
  return [...boards.keys()].sort((a, b) => BOARD_ORDER.indexOf(a) - BOARD_ORDER.indexOf(b))
    .map((board) => ({ board, cards: [...boards.get(board)!.values()].sort((a, b) => (a.norm < b.norm ? -1 : 1)) }));
}

/** The cards behind one shared section, read-only; tap opens the card (your own copies of it). */
export function ProfileCardsScreen(props: {
  userId: string; section: SectionKind; item: string | null; onBack: () => void; onCard: (oracleId: string) => void;
}) {
  return <Gate title="Cards" onBack={props.onBack}>{() => <ProfileCardsBody {...props} />}</Gate>;
}

function ProfileCardsBody({ userId, section, item, onBack, onCard }: {
  userId: string; section: SectionKind; item: string | null; onBack: () => void; onCard: (oracleId: string) => void;
}) {
  const { catalog, error: catError } = useCatalog();
  const [rows, setRows] = useState<ProfileCard[] | null>(null);
  const [title, setTitle] = useState<string>("");
  const [error, setError] = useState<string | null>(null);
  const [q, setQ] = useState("");
  useEffect(() => {
    fetchProfileCards(userId, section, item).then(setRows, (e) => { setError(errorMessage(e)); setRows([]); });
    // The address carries ids only; the title comes from the profile.
    fetchProfile(userId).then((p) => {
      const s = p.sections;
      const named = [...(s.binders ?? []), ...(s.decks ?? []), ...(s.cubes ?? [])].find((x) => x.id === item)?.name;
      setTitle(`${p.display_name} · ${named ?? { all_cards: "All cards", for_trade: "For trade", wants: "Wants" }[section as string] ?? "Cards"}`);
    }, () => {});
  }, [userId, section, item]);
  const groups = useMemo(() => (catalog && rows ? groupProfileCards(rows, catalog) : []), [catalog, rows]);
  const n = normName(q);
  const copies = rows?.reduce((s, r) => s + r.qty, 0) ?? 0;
  return (
    <LibScreen>
      <Bar title={title || "Cards"} subtitle={rows ? plural(copies, "card") : undefined} onBack={onBack} />
      {(error || catError) && <Notice tone="error">{error ?? catError}</Notice>}
      <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Name or type"
             className="bg-t1-surface px-4 py-4 outline-0 border-0 text-[15px] placeholder:text-t1-muted/60" />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {(!catalog || !rows) && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {rows?.length === 0 && !error && <Notice tone="info">Nothing here.</Notice>}
        {catalog && groups.map((g) => {
          const shown = n ? g.cards.filter((x) => x.norm.includes(n) || normName(x.type).includes(n)) : g.cards;
          return (
            <div key={g.board} className="flex flex-col gap-px">
              {groups.length > 1 && shown.length > 0 && <Section title={BOARD[g.board] ?? "Cards"} count={shown.reduce((s, x) => s + x.qty, 0)} />}
              {shown.map((x) => (
                <div key={x.key} style={{ height: 60 }}>
                  <CardRow c={catalog} p={x.cover} title={x.name} detail={x.type} value={x.qty} onClick={() => x.oracle >= 0 && onCard(x.key)} />
                </div>
              ))}
            </div>
          );
        })}
      </div>
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
  useEffect(() => void loadSharing(), []);
  const s = st.sharing;
  const part = (p: SharePart) => s && (
    <SharingControl key={p} title={PART_LABEL[p]} detail={PART_DETAIL[p]} own={s[p]} settings={s} isProfile={p === "profile"}
                    parent={inherits(p) ? { name: "Library", value: s.library } : null} onChange={(v) => void setPart(p, v)} />
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
                          settings={s} parent={{ name: PART_LABEL[group], value: effective(s, group) }} onChange={(v) => void setItem(i, v)} />
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
            <Notice tone="info">Everything starts private. Friends see what's Friends or Public; anyone on Table 1 sees what's Public. Your profile caps the rest.</Notice>
            {part("profile")}
            {part("record")}
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
  return (
    <Screen>
      <Bar title="Trade matches" subtitle={m ? plural(m.length, "person", "people") : undefined} onBack={onBack} />
      {st.error && <Notice tone="error">{st.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Notice tone="info">Your wants against friends' for-trade cards, and theirs against yours. People you've played with count when they share publicly.</Notice>
        {!m && <div className="bg-t1-surface px-4 py-4 t1-label">Looking…</div>}
        {m?.length === 0 && (
          <>
            <Notice tone="info">No matches yet. Matches show once friends share For trade or Wants, and you have wants or a for-trade binder.</Notice>
            <Row title="Friends" detail="Add friends to trade with" onClick={onFriends} />
            <Row title="Sharing" detail="Share your For trade and Wants" onClick={onSharing} />
          </>
        )}
        {m?.map((x) => (
          <Row key={x.user_id} title={x.display_name} detail={matchShort(x) + (x.friend ? "" : " · played with you")}
               avatar={<Avatar name={x.display_name} userId={x.user_id} />}
               value={x.have_usd + x.want_usd > 0 ? usdText(x.have_usd + x.want_usd) : undefined} onClick={() => onOpen(x.user_id)} />
        ))}
      </div>
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
        const price = l.usd ?? usdPrice(l.card_id, l.finish);
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
           right={<button type="button" onClick={onProfile} className="t1-label hover:text-t1-text px-2 py-1 -my-1">Profile</button>} />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!match && <div className="bg-t1-surface px-4 py-4 t1-label">{loaded ? "Nothing matches with them right now." : "Looking…"}</div>}
        {match && <Notice tone="info">{matchSummary(match)}</Notice>}
        {match && side(`They have · ${match.have_copies} you want`, match.they_have, match.have_usd, true)}
        {match && side(`They want · ${match.want_copies} you have`, match.they_want, match.want_usd, false)}
      </div>
      {match && <BigAction label="Start a trade" tone="accent" busy={busy} onClick={() => void start()} />}
    </LibScreen>
  );
}
