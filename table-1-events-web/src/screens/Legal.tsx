import { useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { deleteAccount, errorMessage } from "../lib/api";
import { supabase } from "../lib/supabaseClient";
import { useSession } from "../lib/useSession";
import { SignInButtons } from "../components/SignInButtons";
import { Notice, Screen, T1Logo } from "../components/kit";

/*
 * Public pages linked from Google's OAuth consent screen and Play Console's App content:
 * /privacy and /delete-account. Both render signed out.
 *
 * DRAFT: John must review this text before it is published. Facts come from the code as of 2026-10-15
 * (delete_account() in supabase/migrations/20261016170000_scan_reports.sql, update_presence(),
 * contract/telemetry-2026-10-15.md, deck-finder and list-import). Keep them in step when those change.
 */

export const CONTACT_EMAIL = "privacy@table-1.site";
const UPDATED = "15 October 2026";

function LegalScreen({ title, children }: { title: string; children: ReactNode }) {
  const tab = (to: string, label: string) => (
    <Link to={to} className="flex-1 py-3 text-center text-[11px] uppercase tracking-[1.5px] bg-t1-surface hover:bg-t1-surface-hover">
      {label}
    </Link>
  );
  return (
    <Screen>
      <nav className="shrink-0 flex gap-px items-stretch">
        <Link to="/" className="bg-t1-surface px-4 flex items-center" aria-label="Table 1 home">
          <T1Logo className="h-4 w-auto" />
        </Link>
        {tab("/privacy", "Privacy")}
        {tab("/delete-account", "Delete account")}
      </nav>
      <div className="shrink-0 bg-t1-surface px-4 py-6">
        <h1 className="text-[22px] leading-7 uppercase tracking-[4px] font-bold">{title}</h1>
        <p className="t1-label mt-1">Table 1 · Updated {UPDATED}</p>
      </div>
      <div className="bg-t1-warning-surface text-t1-warning px-4 py-3 text-[12px] leading-[18px] uppercase tracking-[1px]">
        Draft: under review, not yet final.
      </div>
      <div className="flex-1 flex flex-col gap-px">{children}</div>
      <div className="bg-t1-surface px-4 py-4 t1-label">
        Questions: <a className="text-t1-text underline" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>
      </div>
    </Screen>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="bg-t1-surface px-4 py-5">
      <h2 className="t1-label text-t1-text! mb-3">{title}</h2>
      <div className="max-w-[680px] flex flex-col gap-3 text-[14px] leading-[22px] text-t1-text [&_ul]:flex [&_ul]:flex-col [&_ul]:gap-2 [&_li]:pl-4 [&_li]:relative [&_li]:before:content-['–'] [&_li]:before:absolute [&_li]:before:left-0 [&_li]:before:text-t1-muted [&_b]:font-bold">
        {children}
      </div>
    </section>
  );
}

/** What deletion removes and keeps. Shared by both pages so they never disagree. */
function DeletionScope() {
  return (
    <>
      <p>Deleting your account removes, straight away:</p>
      <ul>
        <li>your sign-in and email address, and your name and profile;</li>
        <li>your collection, its history, decks, cubes (with every saved version) and trades;</li>
        <li>your devices, notification and Live Activity tokens, notification settings and saved nearby area;</li>
        <li>invitations you hadn't answered yet;</li>
        <li>on iOS, Table 1's Sign in with Apple authorization (the app asks Apple to revoke it).</li>
      </ul>
      <p>Kept, without your name:</p>
      <ul>
        <li>
          results of matches you played. Your opponents' records and the event's standings depend on them, so they stay
          in the event as "Deleted player";
        </li>
        <li>scanning corrections you sent (the text read off a card and which card it was), no longer linked to you;</li>
        <li>
          usage and crash data, which is tied only to a random account id. Crash reports are deleted after 90 days.
        </li>
      </ul>
      <p>Database backups roll over and drop deleted data within a few weeks.</p>
    </>
  );
}

export function PrivacyPolicy() {
  return (
    <LegalScreen title="Privacy policy">
      <Section title="Who we are">
        <p>
          Table 1 makes apps for Magic: The Gathering players: Table 1 Events for running and playing tournaments, and a
          Library for your collection, decks, cubes and trades. Table 1 is run by John Lindmark. This policy covers the
          iOS and Android apps and table-1.site.
        </p>
        <p>
          The short version: we collect what we need to run your events and keep your collection, we don't sell it, we
          don't show ads, and we don't track you across other apps or sites.
        </p>
      </Section>

      <Section title="Your account">
        <p>
          You sign in with Apple, Google or an email code. We receive your email address and, from Apple or Google, your
          name. With an email code, you type your name. If you use Apple's "Hide My Email", we only see the relay address.
          We never see a password.
        </p>
      </Section>

      <Section title="Events and results">
        <p>
          When you create or join an event we store the event (format, rounds, seating, pods, teams), who plays, pairings,
          match results, result confirmations and disputes, and life totals synced during a match. Every change is written
          to an audit log so organizers can resolve disputes. Organizers can add guests by name; a guest has no account.
        </p>
        <p>
          Your name, results and standings are visible to the organizer and other players in that event, and to anyone
          the organizer shares the standings link with. Your lifetime record and head-to-head are visible to you.
        </p>
      </Section>

      <Section title="Your Library">
        <p>
          Your collection (cards, printings, finish, condition and the history of changes), decks, cubes and their saved
          versions, and trades are stored so they sync between your devices. They are private to your account.
        </p>
      </Section>

      <Section title="Location">
        <p>
          The phone apps ask for location only while you use them (never in the background), and only to find events
          near you and to pin an event you organize to where you are.
        </p>
        <ul>
          <li>Finding nearby events: your position is used for that search and not stored.</li>
          <li>
            Nearby alerts (Account, off unless you turn it on): we keep only the roughly 1 km area you were last in,
            replaced each time you open the app. Your exact coordinates are discarded.
          </li>
          <li>Pinning an event: the event's location is stored and shown to players looking for events nearby.</li>
        </ul>
      </Section>

      <Section title="Camera">
        <p>
          The camera scans an organizer's QR code to join an event and scans cards into your collection or a trade.
          Recognition runs on your device; images and video never leave it.
        </p>
        <p>
          When you correct a scanned card, the app sends the text it read from the card and which card it really was, so
          we can make scanning better. You can turn this off in Account → Improve scanning.
        </p>
      </Section>

      <Section title="Deck finder and imports">
        <p>
          When you use Find a deck online, or import a deck or cube from a link or pasted list, what you type, the link
          and the pasted list are sent to Anthropic (Claude) to find or read the list, and the linked page is fetched by
          our server. Anthropic processes it for us and does not use it to train its models. Don't paste anything personal.
        </p>
      </Section>

      <Section title="Keeping Table 1 safe">
        <p>
          Content other players can see (display names, handles, profile photos, names of decks, cubes and binders you
          share, event and guest names, and deck photos and their notes) is checked automatically for hate, harassment,
          sexual content, spam, personal contact details and impersonation. The text or image is sent to Anthropic
          (Claude) without your account id or email; Anthropic processes it for us and does not use it to train its
          models. Anything you keep private is never checked. If something breaks the rules, we make the smallest change
          we can (for example reset a name or stop sharing a deck), tell you in Account → From Table 1, and you can appeal
          it once to a person. Reports you make go to us, never to the person you reported. We keep what was checked for
          180 days, then delete the text. Photos that appear to involve the sexual abuse of children are removed, kept
          securely, and reported to the National Center for Missing &amp; Exploited Children as US law requires.
        </p>
      </Section>

      <Section title="Usage and crash data">
        <p>
          The apps send usage events (which screens and features are used, counts like "cards added") to PostHog and crash
          and error reports to Sentry. They carry a random account id, the platform, app version and device model, and no
          email, names, event names, notes or search text. There is no advertising id. Turn it off in Account → Share
          usage and crash data. The website records page views with Google Analytics, with join codes and event ids
          removed from the addresses.
        </p>
      </Section>

      <Section title="Who processes data for us">
        <ul>
          <li>Supabase: database, sign-in and server functions, hosted on Amazon Web Services in the United States (us-east-1).</li>
          <li>Apple and Google: sign-in, and push notifications and Live Activities on iOS.</li>
          <li>Our email provider: sends sign-in codes and links.</li>
          <li>Anthropic: deck finder, link imports and safety checks, as described above.</li>
          <li>PostHog, Sentry and Google Analytics: usage and crash data, as described above.</li>
          <li>
            Scryfall: card data, prices and images. Your device loads card images and set icons from Scryfall, which sees
            its IP address like any website.
          </li>
          <li>Cube Cobra and deck sites: contacted only when you look up a cube or import from a link.</li>
        </ul>
        <p>We don't sell or rent personal data, and we don't share it for advertising.</p>
      </Section>

      <Section title="How long we keep it">
        <p>
          We keep your data while you have an account. Event results are part of other players' records, so they stay
          after you delete your account, under the name "Deleted player".
        </p>
      </Section>

      <Section title="Deleting your account">
        <p>
          In the app: Account → Delete account. On the web, or if you no longer have the app, see{" "}
          <Link className="underline" to="/delete-account">table-1.site/delete-account</Link>.
        </p>
        <DeletionScope />
      </Section>

      <Section title="Your rights">
        <p>
          You can see and change your name in Account, and delete your account at any time. To get a copy of your data,
          correct something you can't change in the app, or object to how we use it, email{" "}
          <a className="underline" href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> from the address you sign in
          with. We answer within 30 days. Depending on where you live (for example the EU, UK or California) you may also
          complain to your data protection authority.
        </p>
      </Section>

      <Section title="Children">
        <p>Table 1 is not directed at children under 13, and we don't knowingly collect their data.</p>
      </Section>

      <Section title="Security">
        <p>
          Data travels over HTTPS. Each account can read only its own private data; tournament rules run on the server.
          Join codes and claim tokens are kept out of analytics.
        </p>
      </Section>

      <Section title="Changes">
        <p>
          If this policy changes we'll update the date above, and tell you in the app when the change is significant.
        </p>
      </Section>
    </LegalScreen>
  );
}

export function DeleteAccountPage() {
  const { session, ready } = useSession();
  const [confirm, setConfirm] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const onDelete = async () => {
    setDeleting(true);
    setError(null);
    try {
      await deleteAccount(); // also signs out locally
      setDone(true);
    } catch (e) {
      setError(`Couldn't delete the account: ${errorMessage(e)}`);
      setConfirm(false);
    } finally {
      setDeleting(false);
    }
  };

  const email = session?.user.email;
  return (
    <LegalScreen title="Delete your account">
      <Section title="In the app">
        <p>
          Open Table 1, go to <b>Account</b> and tap <b>Delete account</b>, then confirm. On iPhone, if you signed in
          with Apple, you confirm with Apple once more so the app can revoke its access.
        </p>
      </Section>

      <Section title="On the web">
        {done ? (
          <p>Your account is deleted and you're signed out.</p>
        ) : !ready ? (
          <p className="t1-label">Loading…</p>
        ) : !session ? (
          <p>Sign in with the same Apple, Google or email account you use in the app, then delete it here.</p>
        ) : (
          <p>
            Signed in{email ? <> as <b>{email}</b></> : null}. Deleting can't be undone.
          </p>
        )}
      </Section>
      {error && <Notice tone="error">{error}</Notice>}
      {ready && !session && !done && <SignInButtons />}
      {session && !done && (
        <div className="flex gap-px">
          {confirm ? (
            <>
              <button className="flex-1 bg-t1-surface hover:bg-t1-surface-hover py-4 t1-label" disabled={deleting}
                      onClick={() => setConfirm(false)}>
                Cancel
              </button>
              <button className="flex-1 bg-t1-danger/20 py-4 t1-label text-t1-danger!" disabled={deleting} onClick={onDelete}>
                {deleting ? "Deleting…" : "Yes, delete"}
              </button>
            </>
          ) : (
            <>
              <button className="flex-1 bg-t1-surface hover:bg-t1-surface-hover py-4 t1-label"
                      onClick={() => supabase.auth.signOut()}>
                Sign out
              </button>
              <button className="flex-1 bg-t1-surface hover:bg-t1-surface-hover py-4 t1-label text-t1-danger!"
                      onClick={() => setConfirm(true)}>
                Delete my account
              </button>
            </>
          )}
        </div>
      )}

      <Section title="Without the app">
        <p>
          Email <a className="underline" href={`mailto:${CONTACT_EMAIL}?subject=Delete%20my%20Table%201%20account`}>{CONTACT_EMAIL}</a>{" "}
          from the address you sign in with and ask us to delete your account. We'll confirm and delete it within 30 days.
          If you signed in with Apple using "Hide My Email", tell us which relay address it was. You can also remove Table 1
          from your Apple Account under Sign in with Apple.
        </p>
      </Section>

      <Section title="What happens to your data">
        <DeletionScope />
      </Section>
    </LegalScreen>
  );
}
