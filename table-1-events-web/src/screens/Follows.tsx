import { useEffect, useState } from "react";
import { Bar, Menu, Notice, Row, Section, type MenuItem } from "../components/kit";
import { errorMessage } from "../lib/api";
import {
  MINUS, fetchFollowChanges, followDetail, followHome, followHref, followSections, followSubtitle, followTitle, loadFollowState, loadFollows,
  setFollow, since, useFollows, type Follow, type FollowChanges, type FollowKind, type FollowRow,
} from "../lib/follows";
import { capture } from "../lib/telemetry";
import { CardRow, LibScreen, useCatalog } from "./Library";
import { BoardHeader } from "./Lists";

/* Following screens (contract/follows-2026-10-25.md): the Follow rows on someone else's binder, deck or cube, the
   Library home row, Following, and an item's Changes. */

function followMenu(title: string, kind: FollowKind, id: string, push: boolean, from: string, onError: (m: string) => void): { title: string; items: MenuItem[] } {
  const run = (work: () => Promise<unknown>) => void work().catch((e) => onError(errorMessage(e)));
  return {
    title,
    items: [
      { title: push ? "Turn pushes off" : "Turn pushes on", detail: push ? "Changes still show in Following" : "A push when a round of changes is done",
        onClick: () => run(() => setFollow(kind, id, true, { push: !push, from })) },
      { title: "Unfollow", onClick: () => run(() => setFollow(kind, id, false, { from })) },
    ],
  };
}

/** On a binder, deck or cube someone else shares with you: Follow, or Following and its Changes. Signed out (a link):
 *  "Sign in to follow". */
export function FollowRows({ kind, id, title, owner, token, signedIn = true, onSignIn, onChanges }: {
  kind: FollowKind; id: string; title: string; owner?: string | null; token?: string; signedIn?: boolean; onSignIn?: () => void;
  onChanges: () => void;
}) {
  const s = useFollows();
  const st = s.states[id];
  const [busy, setBusy] = useState(false);
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  useEffect(() => {
    if (signedIn) void loadFollowState(kind, id);
  }, [kind, id, signedIn]);
  if (!signedIn) return <Row title="Follow" detail="Sign in to follow and get its changes" onClick={onSignIn} />;
  if (!st) return null;
  const follow = () => {
    setBusy(true);
    setFail(null);
    setFollow(kind, id, true, { token, from: "item" }).catch((e) => setFail(errorMessage(e))).finally(() => setBusy(false));
  };
  return (<>
    {fail && <Notice tone="error">{fail}</Notice>}
    {st.following ? (<>
      <Row title="Following" detail={st.push ? "Pushes on" : "Pushes off · changes show in Following"} value="✓" accentValue
           onClick={() => setMenu(followMenu(title, kind, id, st.push, "item", setFail))} />
      {st.last_update && (
        <Row title="Changes" detail={since(st.last_update, new Date())} value={st.unseen ? `${st.unseen} new` : undefined} accentValue onClick={onChanges} />
      )}
    </>) : (
      <Row title="Follow" detail={`Get a push when ${owner ? `${owner} changes` : "they change"} it${kind === "cube" && token ? ", and rank it" : ""}`}
           action={{ label: busy ? "…" : "Follow", onClick: follow, disabled: busy }} />
    )}
    {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
  </>);
}

/** Library home, once you follow anything. */
export function FollowingScreen({ onBack, onOpen }: { onBack: () => void; onOpen: (href: string) => void }) {
  const s = useFollows();
  const [menu, setMenu] = useState<{ title: string; items: MenuItem[] } | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  useEffect(() => {
    void loadFollows().then((items) => {
      if (items) capture("following_viewed", { items: items.length, updated: items.filter((f) => f.available && f.unseen > 0).length });
    });
  }, []);
  const more = (f: Follow) => setMenu(f.available ? followMenu(followTitle(f), f.kind, f.id, f.push, "following", setFail) : {
    title: "This isn't available",
    items: [{ title: "Unfollow", detail: "It may have been made private or deleted",
              onClick: () => void setFollow(f.kind, f.id, false, { from: "following" }).catch((e) => setFail(errorMessage(e))) }],
  });
  const now = new Date();
  return (
    <LibScreen>
      <Bar title="Following" subtitle={s.items ? followHome(s.items) : undefined} onBack={onBack} />
      {(s.error || fail) && <Notice tone="error">{fail ?? s.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {!s.items && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {s.items?.length === 0 && <Notice tone="info">Follow a friend's deck, cube or binder to see their changes here.</Notice>}
        {s.items?.map((f) => (
          <div key={f.id} className="flex gap-px" onContextMenu={(e) => { e.preventDefault(); more(f); }}>
            <div className="flex-1 min-w-0">
              <Row title={followTitle(f)} detail={[f.available ? followSubtitle(f) : null, followDetail(f, now)].filter(Boolean).join(" · ")}
                   value={f.available && f.unseen ? `${f.unseen} new` : undefined} accentValue
                   onClick={() => { const href = followHref(f); if (href) onOpen(href); else more(f); }} />
            </div>
            <button type="button" aria-label="More" onClick={() => more(f)} className="bg-t1-surface hover:bg-t1-surface-hover px-4 t1-label">•••</button>
          </div>
        ))}
      </div>
      {menu && <Menu title={menu.title} items={menu.items} onClose={() => setMenu(null)} />}
    </LibScreen>
  );
}

const SECTION: Record<string, string> = { main: "Main deck", side: "Sideboard", commander: "Commander" };

/** An item's updates since you followed, newest first: Added, then Taken out. */
export function FollowChangesScreen({ kind, id, onBack, onCard }: { kind: FollowKind; id: string; onBack: () => void; onCard: (oracleId: string) => void }) {
  const { catalog, error: catError } = useCatalog();
  const [changes, setChanges] = useState<FollowChanges | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    fetchFollowChanges(kind, id).then(setChanges, (e) => setError(errorMessage(e)));
  }, [kind, id]);
  const row = (r: FollowRow, sign: string) => {
    const p = catalog?.printingIndex.get(r.card_id) ?? null;
    const oi = catalog && p != null ? catalog.pOracle[p] : -1;
    const set = catalog && p != null ? `${catalog.pSet[p].toUpperCase()} #${catalog.pCn[p]}` : null;
    return (
      <div key={`${r.card_id}|${r.board}`} className="h-[60px] shrink-0">
        <CardRow c={catalog!} p={p} title={oi >= 0 ? catalog!.oName[oi] : "Unknown card"}
                 detail={[kind === "deck" ? SECTION[r.board ?? ""] : null, set].filter(Boolean).join(" · ")}
                 value={`${sign}${r.qty}`} onClick={() => oi >= 0 && onCard(catalog!.oId[oi])} />
      </div>
    );
  };
  const now = new Date();
  return (
    <LibScreen>
      <Bar title={changes?.name ?? "Changes"} subtitle="Changes" onBack={onBack} />
      {(error || catError) && <Notice tone="error">{error ?? catError}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {(!changes || !catalog) && !error && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {changes && catalog && !changes.updates.length && <Notice tone="info">No changes since you followed.</Notice>}
        {changes && catalog && changes.updates.map((u) => {
          const s = followSections(u.cards);
          return (
            <div key={u.at} className="flex flex-col gap-px shrink-0">
              <Section title={since(u, now)} />
              {!!s.added.length && <BoardHeader title="Added" count={s.added.reduce((n, r) => n + r.qty, 0)} />}
              {s.added.map((r) => row(r, "+"))}
              {!!s.removed.length && <BoardHeader title="Taken out" count={s.removed.reduce((n, r) => n + r.qty, 0)} />}
              {s.removed.map((r) => row(r, MINUS))}
            </div>
          );
        })}
      </div>
    </LibScreen>
  );
}
