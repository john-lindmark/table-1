import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { errorMessage } from "../lib/api";
import {
  clearPendingToken, confirmDiscordLink, DISCORD_HELP, type DiscordLinkStatus, fetchDiscordLinkStatus, installUrl,
  linkTokenFromHash, loadPendingToken, savePendingToken, unlinkDiscord,
} from "../lib/discord";
import { capture, screen } from "../lib/telemetry";
import { useSession } from "../lib/useSession";
import { SignInButtons } from "../components/SignInButtons";
import { Bar, BigAction, GhostAction, Notice, Row, Screen } from "../components/kit";

/*
 * Table 1 for Discord (contract/discord-2026-10-29.md §7).
 *   /discord       what the bot does (every command, from the bot's own command file), Add to your server, and, signed
 *                  in, whether this account is linked, with Unlink.
 *   /discord/link  the page behind the bot's /link: #t=<token>. Signed out, the token waits in this tab while you sign
 *                  in (any method); signed in, it's confirmed and you go back to Discord.
 * Both stay in the browser (not claimed by the apps).
 */

const CLIENT_ID = import.meta.env.VITE_DISCORD_CLIENT_ID ?? "";

function when(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  return `${d.getDate()} ${d.toLocaleDateString("en-US", { month: "short" })} ${d.getFullYear()}`;
}

/** The link status rows: Linked via … / Unlink, or how to link. */
function LinkStatus({ onBack }: { onBack?: () => void }) {
  const { session, ready } = useSession();
  const [status, setStatus] = useState<DiscordLinkStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!session) {
      setStatus(null);
      return;
    }
    fetchDiscordLinkStatus().then(setStatus, (e) => setError(errorMessage(e)));
  }, [session]);

  async function unlink() {
    setBusy(true);
    setError(null);
    try {
      const r = await unlinkDiscord();
      if (r.unlinked) capture("discord_unlinked", { via: "link" });
      setStatus(await fetchDiscordLinkStatus());
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  if (!ready) return null;
  if (!session) {
    return (
      <>
        <div className="bg-t1-surface px-4 py-2 t1-label">Your account</div>
        <div className="bg-t1-surface px-4 py-3 text-[13px]">
          Sign in to see whether your Table 1 account is linked to Discord. To link it, run <code>/link</code> in a server
          that has the bot, or sign in to Table 1 with Discord.
        </div>
        {onBack && <SignInButtons returnTo="/discord" />}
      </>
    );
  }
  return (
    <>
      <div className="bg-t1-surface px-4 py-2 t1-label">Your account</div>
      {error && <Notice tone="error">{error}</Notice>}
      {status === null && !error && <div className="bg-t1-surface px-4 py-3 t1-label">Loading…</div>}
      {status && !status.linked && (
        <Row title="Not linked to Discord" detail="Run /link in a server that has the bot, or sign in to Table 1 with Discord." />
      )}
      {status?.linked && status.via === "link" && (
        <Row title="Linked to Discord" detail={`Since ${when(status.linkedAt)} · the bot acts as this account`}
             action={{ label: busy ? "…" : "Unlink", onClick: unlink, disabled: busy }} />
      )}
      {status?.linked && status.via === "sign_in" && (
        <Row title="Linked to Discord" detail="You sign in to Table 1 with Discord, so the bot acts as this account." />
      )}
    </>
  );
}

export function DiscordPage({ onBack }: { onBack: () => void }) {
  useEffect(() => screen("discord"), []);
  const install = installUrl(CLIENT_ID);
  return (
    <Screen>
      <Bar title="Table 1 for Discord" subtitle="Events, sign-ups and results in your server" onBack={onBack} />
      <div className="bg-t1-surface px-4 py-3 text-[13px] leading-5">
        Add the bot to a Discord server and people there can make Table 1 events, sign up and drop with a button, see
        who's in, and post the results with a link to the event. The bot acts as each person's own Table 1 account,
        with the same rules as the apps.
      </div>
      {install && (
        <a href={install} target="_blank" rel="noreferrer"
           className="w-full bg-t1-accent text-t1-ink px-4 py-5 text-[13px] uppercase tracking-[3px] font-bold text-center block">
          Add to your server
        </a>
      )}
      <div className="bg-t1-surface px-4 py-3 t1-label normal-case! tracking-normal!">
        Permissions asked: Send Messages and Embed Links. The bot never reads messages and keeps nothing about your
        server but the posted cards' ids and its time zone.
      </div>

      <div className="bg-t1-surface px-4 py-2 t1-label">Commands</div>
      {DISCORD_HELP.map((h) => (
        <div key={h.command} className="bg-t1-surface px-4 py-3 flex flex-col gap-0.5">
          <span className="text-[13px] font-bold tracking-[0.5px]">{h.command}</span>
          <span className="t1-label normal-case! tracking-normal! leading-4">{h.text}</span>
        </div>
      ))}

      <div className="bg-t1-surface px-4 py-2 t1-label">Who sees what</div>
      <div className="bg-t1-surface px-4 py-3 text-[13px] leading-5 flex flex-col gap-2">
        <p>Everything the bot tells you about yourself only you can see. The event card, the results post and a deck you
          post are public in the channel, because you asked for them.</p>
        <p>The card shows players by their Table 1 display name, as the event already does for its players. A deck post is
          a link anyone can open, made only after you confirm; stop sharing it any time under Sharing.</p>
        <p>Table 1 keeps which Discord account is which Table 1 account, nothing else about Discord. Unlink here or with
          <code> /unlink</code>; deleting your account removes it.</p>
      </div>

      <LinkStatus />
      <div className="flex-1 bg-t1-surface" />
      <footer className="bg-t1-surface px-4 py-4 flex flex-wrap gap-x-6 gap-y-2 t1-label">
        <Link to="/privacy" className="hover:text-t1-text">Privacy</Link>
        <Link to="/" className="hover:text-t1-text">Table 1</Link>
      </footer>
    </Screen>
  );
}

type LinkState = "waiting" | "signed_out" | "linking" | "done" | "no_token" | "error";

export function DiscordLinkPage() {
  useEffect(() => screen("discord_link"), []);
  const { session, ready } = useSession();
  const [state, setState] = useState<LinkState>("waiting");
  const [error, setError] = useState<string | null>(null);
  const [token] = useState(() => {
    // The token stays out of history and the address bar once read.
    const fromHash = linkTokenFromHash(window.location.hash);
    if (fromHash) {
      window.history.replaceState(null, "", window.location.pathname);
      savePendingToken(fromHash);
      return fromHash;
    }
    return loadPendingToken();
  });
  const started = useRef(false);

  useEffect(() => {
    if (!ready) return;
    if (!token) {
      setState("no_token");
      return;
    }
    if (!session) {
      setState("signed_out");
      return;
    }
    if (started.current) return;
    started.current = true;
    setState("linking");
    confirmDiscordLink(token).then(
      () => {
        clearPendingToken();
        capture("discord_link_completed", { via: "link" });
        setState("done");
      },
      (e) => {
        clearPendingToken();
        setError(errorMessage(e));
        setState("error");
      },
    );
  }, [ready, session, token]);

  return (
    <Screen>
      <Bar title="Link Discord" subtitle="Table 1 for Discord" />
      {state === "waiting" && <Notice tone="info">One moment…</Notice>}
      {state === "no_token" && (
        <>
          <Notice tone="error">This link is missing its code. Run /link in Discord again and open the link it gives you.</Notice>
          <GhostAction label="What the bot does" onClick={() => window.location.assign("/discord")} />
        </>
      )}
      {state === "signed_out" && (
        <>
          <div className="bg-t1-surface px-4 py-3 text-[13px] leading-5">
            Sign in to the Table 1 account the Discord bot should act as. New here? Signing in makes the account.
          </div>
          <SignInButtons returnTo="/discord/link" />
        </>
      )}
      {state === "linking" && <Notice tone="info">Linking…</Notice>}
      {state === "done" && (
        <>
          <Notice tone="info">Linked. The bot now acts as this Table 1 account. You can close this page and go back to Discord.</Notice>
          <BigAction label="What the bot does" onClick={() => window.location.assign("/discord")} />
        </>
      )}
      {state === "error" && (
        <>
          <Notice tone="error">{error}</Notice>
          <GhostAction label="What the bot does" onClick={() => window.location.assign("/discord")} />
        </>
      )}
    </Screen>
  );
}
