import { Suspense, lazy, useCallback, useEffect, useRef, useState } from "react";
import {
  deleteAccount,
  isDemoTester,
  removeDemo,
  seedDemo,
  fetchAccountOverview,
  fetchNearbyAlerts,
  setDisplayName,
  setNearbyAlerts,
  signOut,
  errorMessage,
} from "../lib/api";
import { capture, setSharing, sharing } from "../lib/telemetry";
import { avatarJpeg, clearAvatar, setAvatar, useAvatarPath } from "../lib/avatarStore";
import { Avatar } from "../components/Avatar";
import { useOpenProfile } from "../lib/personLink";
import type { AccountOverview } from "../lib/types";
import { useSession } from "../lib/useSession";
import { isLibraryDemo } from "../lib/libraryDemo";

/** Account → Payments: its chunk loads with the row. */
const PaymentsAccountRow = lazy(() => import("./Pay").then((m) => ({ default: m.PaymentsAccountRow })));
import { DEMO_OVERVIEW } from "../lib/profileDemo";
import { loadMyDeckPhotos, myDeckPhotoSummary } from "../lib/deckPhotos";
import { Bar, Menu, Notice, Row, Screen, Section, Segmented, TabNav, type MenuItem } from "../components/kit";
import { useTrackerMode } from "../lib/settings";
import { FAN_CONTENT } from "../lib/legal";

/* The Account tab (contract/main-nav-2026-11-14.md § 3): Profile is your own profile screen (Friends.tsx, as
   /u/<your id> shows it); Records holds the lifetime record, deck photos and every head-to-head; Settings every setting
   and account action. */

/** "Share usage and crash data": PostHog and Sentry on this browser (contract/telemetry-2026-10-15.md). */
function SharingToggle() {
  const [on, setOn] = useState(sharing);
  return (
    <button
      className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3.5 flex items-center gap-3 text-left w-full"
      onClick={() => {
        setSharing(!on);
        setOn(!on);
      }}
    >
      <span className="flex-1 min-w-0 flex flex-col">
        <span className="text-[14px]">Share usage and crash data</span>
        <span className="t1-label normal-case! tracking-normal!">
          Which features you use and crash reports, tied to your account id only: never names, cards or events. Saved
          in this browser.
        </span>
      </span>
      <span className={`t1-label ${on ? "text-t1-accent!" : ""}`}>{on ? "On" : "Off"}</span>
    </button>
  );
}

const record = (w: number, l: number, d: number) => (d > 0 ? `${w}-${l}-${d}` : `${w}-${l}`);

/** Friends and Sharing rows; their store loads with the Friends chunk, not the entry bundle. */
const SharingAccountRow = lazy(() => import("./Friends").then((m) => ({ default: m.SharingAccountRow })));
const RecordOffer = lazy(() => import("./Friends").then((m) => ({ default: m.RecordOffer })));
const ModerationAccountRows = lazy(() => import("./Moderation").then((m) => ({ default: m.ModerationAccountRows })));
const CommunityJoin = lazy(() => import("./Discord").then((m) => ({ default: m.CommunityJoin })));

/** The signed-in account and its overview (record, head-to-head, name); `?demo` on the dev server uses sample results. */
function useAccount() {
  const real = useSession();
  // Dev server, `?demo`: the account on sample results (the feature-spot shot of the record), no sign-in.
  const demoAccount = import.meta.env.DEV && isLibraryDemo();
  const { session, ready, userId } = demoAccount ? { session: true as const, ready: true, userId: null } : real;
  const [overview, setOverview] = useState<AccountOverview | null>(demoAccount ? DEMO_OVERVIEW : null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    if (!userId || demoAccount) return;
    try {
      setOverview(await fetchAccountOverview());
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [userId]);
  useEffect(() => {
    void load();
  }, [load]);
  return { session, ready, userId, demoAccount, overview, error, setError, load };
}

/** Signed out, every Account sub-tab: what the old Account screen showed. */
export function AccountSignedOut() {
  return (
    <Screen>
      <Bar title="Account" />
      <Notice tone="info">Sign in to see your record.</Notice>
      <div className="flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-2 t1-label">Settings</div>
        <SharingToggle />
      </div>
    </Screen>
  );
}

/** Account → Records: the lifetime record, Deck photos, the record offer, then head-to-head with every opponent. */
export function AccountRecords({ onDeckPhotos }: {
  /** Account → Records → Deck photos (/me/deck-photos). */
  onDeckPhotos?: () => void;
}) {
  const a = useAccount();
  const openProfile = useOpenProfile("head_to_head");
  if (!a.ready) return <Screen><div className="flex-1" /></Screen>;
  if (!a.session) return <AccountSignedOut />;
  const r = a.overview?.record;
  const rivals = a.overview?.head_to_head ?? [];
  const played = r ? r.match_wins + r.match_losses + r.match_draws : 0;
  return (
    <Screen>
      <TabNav />
      <Bar title="Records" />
      {a.error && <Notice tone="error">{a.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-1">
          <p className="t1-label">Lifetime record</p>
          <p className="text-[48px] tabular-nums tracking-[4px] text-t1-accent">
            {r ? record(r.match_wins, r.match_losses, r.match_draws) : "0-0"}
          </p>
          <p className="t1-label">
            {played} matches · {r?.events_played ?? 0} events · games{" "}
            {r ? record(r.game_wins, r.game_losses, r.game_draws) : "0-0"}
            {r?.byes ? ` · ${r.byes} byes` : ""}
          </p>
        </div>
        {(a.userId || isLibraryDemo()) && onDeckPhotos && <DeckPhotosAccountRow onOpen={onDeckPhotos} />}
        {a.userId && <Suspense fallback={null}><RecordOffer eventsPlayed={r?.events_played ?? 0} /></Suspense>}

        <Section title="Head-to-head" count={rivals.length || undefined} />
        {a.overview === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {a.overview && rivals.length === 0 && (
          <div className="bg-t1-surface px-4 py-6 t1-label">Play a match to start your head-to-head.</div>
        )}
        {rivals.map((h) => (
          <div key={h.opponent_id} role="link" tabIndex={0} onClick={openProfile(h.opponent_id)}
               onKeyDown={(e) => { if (e.key === "Enter") openProfile(h.opponent_id)?.(); }}
               className="bg-t1-surface hover:bg-t1-surface-hover cursor-pointer px-4 py-3 flex items-center gap-3">
            <Avatar name={h.name} userId={h.opponent_id} />
            <span className="flex-1 min-w-0 flex flex-col">
              <span className="text-[14px] truncate">{h.name}</span>
              <span className="t1-label">
                {h.played} match{h.played === 1 ? "" : "es"} · games {h.game_wins}-{h.game_losses}
              </span>
            </span>
            <span className="tabular-nums text-[16px]">{record(h.match_wins, h.match_losses, h.match_draws)}</span>
          </div>
        ))}
      </div>
    </Screen>
  );
}

/** Account → Settings: every setting and account action, in the contract's order (§ 3). */
export function AccountSettings({ onSignedOut, onSharing, onDiscord, onNotices, onReview, onSupport }: {
  onSignedOut: () => void; onSharing: () => void;
  onDiscord?: () => void;
  onNotices?: () => void;
  onReview?: () => void;
  /** Support (/support): questions and the guide (contract/support-2026-11-10.md). */
  onSupport?: () => void;
}) {
  const a = useAccount();
  const { userId, overview, setError } = a;
  const [alertsOn, setAlertsOn] = useState(false);
  const [nameDraft, setNameDraft] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const tracker = useTrackerMode();
  const [avatarMenu, setAvatarMenu] = useState(false);
  const [avatarBusy, setAvatarBusy] = useState(false);
  const avatarPath = useAvatarPath(userId);
  const cameraInput = useRef<HTMLInputElement>(null);
  const libraryInput = useRef<HTMLInputElement>(null);
  // "Take a photo" only where the browser can open a camera (phones); elsewhere capture just picks a file.
  const hasCamera = typeof window !== "undefined" && window.matchMedia?.("(pointer: coarse)").matches;

  useEffect(() => {
    if (!userId || a.demoAccount) return;
    fetchNearbyAlerts(userId).then(setAlertsOn).catch((e) => setError(errorMessage(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId]);

  /** Accounts on the server's tester list: load or remove the sample events (same as the apps). */
  const [demoTester, setDemoTester] = useState(false);
  const [demoBusy, setDemoBusy] = useState(false);
  const [demoNotice, setDemoNotice] = useState<string | null>(null);
  useEffect(() => { if (userId) void isDemoTester().then(setDemoTester); }, [userId]);
  const demo = async (seed: boolean) => {
    if (demoBusy) return;
    setDemoBusy(true);
    try {
      await (seed ? seedDemo() : removeDemo());
      setError(null);
      setDemoNotice(seed ? "Demo data loaded. The live round's clock restarts each time you reset." : "Demo data removed.");
      await a.load();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setDemoBusy(false);
    }
  };

  const onDelete = async () => {
    setDeleting(true);
    try {
      await deleteAccount(); // session ends; the screen falls back to signed-out
      onSignedOut();
    } catch (e) {
      setError(`Couldn't delete the account: ${errorMessage(e)}`);
      setDeleting(false);
      setConfirmDelete(false);
    }
  };

  const toggleAlerts = async () => {
    if (!userId) return;
    const next = !alertsOn;
    setAlertsOn(next);
    try {
      await setNearbyAlerts(userId, next);
    } catch (e) {
      setAlertsOn(!next);
      setError(errorMessage(e));
    }
  };

  const saveName = async () => {
    if (!userId || nameDraft === null) return;
    try {
      await setDisplayName(userId, nameDraft);
      setNameDraft(null);
      await a.load();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const pickAvatar = async (file: File | undefined, source: "camera" | "library") => {
    if (!file || !userId) return;
    setAvatarBusy(true);
    try {
      await setAvatar(userId, await avatarJpeg(file));
      setError(null);
      capture("avatar_photo_set", { source });
    } catch (e) {
      setError(`Couldn't save the photo: ${errorMessage(e)}`);
    } finally {
      setAvatarBusy(false);
    }
  };

  const removeAvatar = async () => {
    if (!userId) return;
    setAvatarBusy(true);
    try {
      await clearAvatar(userId);
      setError(null);
      capture("avatar_photo_removed");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setAvatarBusy(false);
    }
  };

  const avatarItems: MenuItem[] = [
    ...(hasCamera ? [{ title: "Take a photo", onClick: () => cameraInput.current?.click() }] : []),
    { title: "Choose from photos", onClick: () => libraryInput.current?.click() },
    ...(avatarPath ? [{ title: "Remove photo", onClick: () => void removeAvatar() }] : []),
  ];

  if (!a.ready) return <Screen><div className="flex-1" /></Screen>;
  if (!a.session) return <AccountSignedOut />;

  const row = "bg-t1-surface hover:bg-t1-surface-hover px-4 py-3.5 flex items-center gap-3 text-left w-full";

  return (
    <Screen>
      <TabNav />
      <Bar title="Settings" />
      {a.error && <Notice tone="error">{a.error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Row title="Profile photo" detail={avatarBusy ? "Saving…" : avatarPath ? "Change or remove" : "Add a photo"}
             avatar={<Avatar name={overview?.profile?.display_name ?? ""} userId={userId} size={40} />}
             onClick={() => { if (!avatarBusy && overview?.profile) setAvatarMenu(true); }} />
        <input
          ref={cameraInput}
          type="file"
          accept="image/*"
          capture="user"
          hidden
          onChange={(e) => {
            void pickAvatar(e.target.files?.[0], "camera");
            e.target.value = "";
          }}
        />
        <input
          ref={libraryInput}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            void pickAvatar(e.target.files?.[0], "library");
            e.target.value = "";
          }}
        />
        {nameDraft === null ? (
          <button className={row} onClick={() => setNameDraft(overview?.profile?.display_name ?? "")}>
            <span className="flex-1 min-w-0 flex flex-col">
              <span className="text-[14px]">Display name</span>
              <span className="t1-label truncate">{overview?.profile?.display_name ?? "–"}</span>
            </span>
            <span className="t1-label text-t1-text!">Edit</span>
          </button>
        ) : (
          <div className="flex gap-px">
            <input
              autoFocus
              value={nameDraft}
              maxLength={40}
              onChange={(e) => setNameDraft(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && saveName()}
              className="flex-1 min-w-0 bg-t1-surface px-4 py-3.5 outline-0 border-0 text-[15px]"
            />
            <button className="bg-t1-surface px-5 t1-label" onClick={() => setNameDraft(null)}>
              Cancel
            </button>
            <button className="bg-t1-accent text-t1-ink px-5 text-[11px] uppercase tracking-[1px]" onClick={saveName}>
              Save
            </button>
          </div>
        )}
        {userId
          ? <Suspense fallback={<Row title="Sharing" onClick={onSharing} />}><SharingAccountRow onSharing={onSharing} /></Suspense>
          : <Row title="Sharing" detail="Who sees your profile and Library" onClick={onSharing} />}
        <Segmented
          label="Track games"
          value={tracker.mode}
          onChange={(m) => tracker.setMode(m)}
          options={[
            { value: "tracker", label: "Life tracker" },
            { value: "elsewhere", label: "Elsewhere" },
          ]}
        />
        <div className="bg-t1-surface px-4 pb-3 -mt-px t1-label normal-case! tracking-normal!">
          {tracker.mode === "tracker"
            ? "Here in the app: your matches open in the life tracker; results are reported from it."
            : "On paper or another app: the event screen leads with reporting your result."}
        </div>
        {tracker.error && <Notice tone="error">{tracker.error}</Notice>}
        <button className={row} onClick={toggleAlerts}>
          <span className="flex-1 min-w-0 flex flex-col">
            <span className="text-[14px]">Nearby alerts</span>
            <span className="t1-label truncate">In the phone apps, a Join / Decline alert when an event opens near you</span>
          </span>
          <span className={`t1-label ${alertsOn ? "text-t1-accent!" : ""}`}>{alertsOn ? "On" : "Off"}</span>
        </button>
        <SharingToggle />
        {/* Entry fees go to a host's own Stripe account (contract/entry-fees-2026-11-13.md § 1); hidden until the server has payments. */}
        {(userId || a.demoAccount) && <Suspense fallback={null}><PaymentsAccountRow /></Suspense>}
        {userId && onNotices && onReview && <Suspense fallback={null}><ModerationAccountRows onNotices={onNotices} onReview={onReview} /></Suspense>}

        {onDiscord && (
          <>
            <div className="bg-t1-surface px-4 py-2 t1-label">Discord</div>
            <Row title="Table 1 for Discord" detail="Events, sign-ups and results in your server · link your account" onClick={onDiscord} />
            <Suspense fallback={null}>
              <CommunityJoin from="account" hideMember />
            </Suspense>
          </>
        )}

        {onSupport && <Row title="Support" detail="Questions and the guide" onClick={onSupport} />}

        {demoTester && (
          <>
            <div className="bg-t1-surface px-4 py-2 t1-label">Developer · testers only</div>
            <Notice tone="info">Sample events, opponents and results on your account. Only accounts on the tester list see them; your real record never includes them.</Notice>
            <div className="flex gap-px">
              <button type="button" disabled={demoBusy} onClick={() => void demo(true)}
                      className="flex-1 bg-t1-accent px-4 py-3 text-[11px] uppercase tracking-[1px] text-t1-ink disabled:opacity-60">
                {demoBusy ? "Working…" : "Load / reset demo"}
              </button>
              <button type="button" disabled={demoBusy} onClick={() => void demo(false)}
                      className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 text-[11px] uppercase tracking-[1px]">Remove demo</button>
            </div>
            {demoNotice && <Notice tone="info">{demoNotice}</Notice>}
          </>
        )}

        <div className="bg-t1-surface px-4 py-2 t1-label">Account</div>
        {confirmDelete && (
          <Notice tone="error">
            Delete your Table 1 account? Your sign-in, name and devices are removed. Results you played stay in their
            events as "Deleted player". This can't be undone.
          </Notice>
        )}
        <div className="flex gap-px">
          {confirmDelete ? (
            <>
              <button className="flex-1 bg-t1-surface py-3.5 t1-label" onClick={() => setConfirmDelete(false)} disabled={deleting}>
                Cancel
              </button>
              <button className="flex-1 bg-t1-danger/20 py-3.5 t1-label text-t1-danger!" onClick={onDelete} disabled={deleting}>
                {deleting ? "Deleting…" : "Yes, delete"}
              </button>
            </>
          ) : (
            <>
              <button className="flex-1 bg-t1-surface py-3.5 t1-label" onClick={() => signOut().then(onSignedOut)}>
                Sign out
              </button>
              <button className="flex-1 bg-t1-surface py-3.5 t1-label" onClick={() => setConfirmDelete(true)}>
                Delete account
              </button>
            </>
          )}
        </div>
        <div className="bg-t1-surface px-4 py-2 t1-label">About</div>
        <Notice tone="info">{FAN_CONTENT}</Notice>
        <a href="/terms" className="bg-t1-surface px-4 py-3.5 flex justify-between t1-label hover:bg-t1-surface-hover">
          <span className="text-t1-text!">Terms of service</span>
          <span>Open</span>
        </a>
        <a href="/privacy" className="bg-t1-surface px-4 py-3.5 flex justify-between t1-label hover:bg-t1-surface-hover">
          <span className="text-t1-text!">Privacy policy</span>
          <span>Open</span>
        </a>
        <div className="bg-t1-surface px-4 py-3.5 flex justify-between t1-label">
          <span className="text-t1-text!">Version</span>
          <span>{__APP_VERSION__}</span>
        </div>
      </div>
      {avatarMenu && <Menu title="Profile photo" items={avatarItems} onClose={() => setAvatarMenu(false)} />}
    </Screen>
  );
}

/** Account → Records → Deck photos: "12 photos · 5 events" (my_deck_photos asked for one photo, for its totals). */
function DeckPhotosAccountRow({ onOpen }: { onOpen: () => void }) {
  const [summary, setSummary] = useState<string | undefined>(undefined);
  useEffect(() => {
    if (isLibraryDemo()) { setSummary(myDeckPhotoSummary(3, 2)); return; }
    let live = true;
    loadMyDeckPhotos(1).then((m) => { if (live) setSummary(myDeckPhotoSummary(m.total, m.events)); }).catch(() => undefined);
    return () => { live = false; };
  }, []);
  return <Row title="Deck photos" detail={summary} onClick={onOpen} />;
}
