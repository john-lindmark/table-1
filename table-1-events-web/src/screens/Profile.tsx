import { Suspense, lazy, useCallback, useEffect, useRef, useState } from "react";
import {
  deleteAccount,
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
import type { AccountOverview } from "../lib/types";
import { useSession } from "../lib/useSession";
import { Bar, Menu, Notice, Screen, Segmented, TopNav, type MenuItem } from "../components/kit";
import { useTrackerMode } from "../lib/settings";
import { FAN_CONTENT } from "../lib/legal";

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

/** The Account tab: lifetime record, head-to-head, settings, and the account itself. */
/** Friends and Sharing rows; their store loads with the Friends chunk, not the entry bundle. */
const FriendsAccountRows = lazy(() => import("./Friends").then((m) => ({ default: m.FriendsAccountRows })));

export function Profile({ onSignedOut, onFriends, onSharing, onProfile }: {
  onSignedOut: () => void; onFriends: () => void; onSharing: () => void; onProfile: (userId: string) => void;
}) {
  const { session, ready, userId } = useSession();
  const [overview, setOverview] = useState<AccountOverview | null>(null);
  const [alertsOn, setAlertsOn] = useState(false);
  const [showAll, setShowAll] = useState(false);
  const [nameDraft, setNameDraft] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
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

  const load = useCallback(async () => {
    if (!userId) return;
    try {
      setOverview(await fetchAccountOverview());
      setAlertsOn(await fetchNearbyAlerts(userId));
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [userId]);
  useEffect(() => {
    load();
  }, [load]);

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
      await load();
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

  if (!ready) return <Screen><div className="flex-1" /></Screen>;
  if (!session) {
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

  const r = overview?.record;
  const rivals = overview?.head_to_head ?? [];
  const label = overview?.profile ? overview.profile.handle || overview.profile.display_name : "Account";
  const played = r ? r.match_wins + r.match_losses + r.match_draws : 0;
  const row = "bg-t1-surface hover:bg-t1-surface-hover px-4 py-3.5 flex items-center gap-3 text-left w-full";

  return (
    <Screen>
      <TopNav />
      <Bar title={label} subtitle="Account" />
      {error && <Notice tone="error">{error}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <div className="bg-t1-surface px-4 py-6 flex flex-col items-center gap-1">
          <button
            type="button"
            aria-label="Profile photo"
            disabled={avatarBusy || !overview?.profile}
            onClick={() => setAvatarMenu(true)}
            className="mb-[18px] flex flex-col items-center gap-2"
          >
            <Avatar name={overview?.profile?.display_name ?? ""} userId={userId} size={64} />
            {avatarBusy && <span className="t1-label">Saving…</span>}
          </button>
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

        {userId && (
          <Suspense fallback={null}>
            <FriendsAccountRows onFriends={onFriends} onSharing={onSharing} onProfile={() => onProfile(userId)} />
          </Suspense>
        )}

        <div className="bg-t1-surface px-4 py-2 t1-label">Head-to-head</div>
        {overview === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {overview && rivals.length === 0 && (
          <div className="bg-t1-surface px-4 py-6 t1-label">Play a match to start your head-to-head.</div>
        )}
        {(showAll ? rivals : rivals.slice(0, 8)).map((h) => (
          <div key={h.opponent_id} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
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
        {rivals.length > 8 && (
          <button className="bg-t1-surface hover:bg-t1-surface-hover py-3 t1-label" onClick={() => setShowAll((v) => !v)}>
            {showAll ? "Show fewer" : `Show all ${rivals.length}`}
          </button>
        )}

        <div className="bg-t1-surface px-4 py-2 t1-label">Settings</div>
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
        <a href="/privacy" className="bg-t1-surface px-4 py-3.5 flex justify-between t1-label hover:bg-t1-surface-hover">
          <span className="text-t1-text!">Privacy policy</span>
          <span>Open</span>
        </a>
      </div>
      {avatarMenu && <Menu title="Profile photo" items={avatarItems} onClose={() => setAvatarMenu(false)} />}
    </Screen>
  );
}
