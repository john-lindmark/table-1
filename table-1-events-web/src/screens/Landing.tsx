import { Link, Navigate, useNavigate } from "react-router-dom";
import { useSession } from "../lib/useSession";
import { SignInButtons } from "../components/SignInButtons";
import { JoinByCode } from "../components/JoinByCode";
import { BackArrow, BigAction, Screen, T1Logo } from "../components/kit";

const FEATURES: { title: string; body: string }[] = [
  {
    title: "Run the event",
    body: "Swiss pairings, the round clock, results and standings from your phone. Constructed, drafts with seating, cubes and team events, by the Magic Tournament Rules.",
  },
  {
    title: "Play your matches",
    body: "Scan the organizer's QR code to join. Report from the life tracker; your opponent confirms. Standings update for everyone.",
  },
  {
    title: "Keep your cards",
    body: "Your collection, decks and cubes with every version saved, and trades that update your collection when you confirm them. Scan cards with the phone apps.",
  },
];

/** table-1.site for signed-out visitors: what Table 1 is, with sign-in one tap away. */
export function Landing() {
  const navigate = useNavigate();
  return (
    <Screen>
      <nav className="shrink-0 flex gap-px items-stretch">
        <div className="flex-1 bg-t1-surface px-4 flex items-center">
          <T1Logo className="h-4 w-auto" />
        </div>
        <Link to="/sign-in" className="bg-t1-surface hover:bg-t1-surface-hover px-5 py-3 text-[11px] uppercase tracking-[1.5px]">
          Sign in
        </Link>
      </nav>

      <div className="bg-t1-surface flex items-center justify-center pt-10 overflow-hidden">
        <T1Logo className="w-full max-w-[400px] h-auto" />
      </div>
      <div className="bg-t1-surface px-4 py-8 flex flex-col gap-3">
        <h1 className="text-[22px] leading-8 uppercase tracking-[4px] font-bold max-w-[640px]">
          Tournaments for Magic players
        </h1>
        <p className="text-[14px] leading-[22px] text-t1-muted max-w-[560px]">
          Run your store's Friday night or your kitchen-table draft, play your matches and keep your collection, in one
          account on iPhone, Android and the web.
        </p>
      </div>
      <BigAction label="Sign in or sign up" tone="accent" onClick={() => navigate("/sign-in")} />

      <div className="bg-t1-surface px-4 pt-4 pb-2 t1-label">Playing tonight? Enter the event code</div>
      <JoinByCode />

      <div className="grid gap-px md:grid-cols-3">
        {FEATURES.map((f) => (
          <section key={f.title} className="bg-t1-surface px-4 py-6 flex flex-col gap-2">
            <h2 className="t1-label text-t1-text!">{f.title}</h2>
            <p className="text-[14px] leading-[22px] text-t1-muted">{f.body}</p>
          </section>
        ))}
      </div>

      <div className="flex-1 bg-t1-surface" />
      <footer className="bg-t1-surface px-4 py-4 flex flex-wrap gap-x-6 gap-y-2 t1-label">
        <Link to="/privacy" className="hover:text-t1-text">Privacy</Link>
        <Link to="/delete-account" className="hover:text-t1-text">Delete account</Link>
        <span>© {new Date().getFullYear()} Table 1</span>
      </footer>
    </Screen>
  );
}

/** Sign in or create an account (the same step: the first sign-in makes the account). Signed in, it goes home. */
export function SignInPage() {
  const { session, ready } = useSession();
  if (ready && session) return <Navigate to="/" replace />;
  return (
    <Screen>
      <div className="shrink-0 bg-t1-surface pr-4 py-3 flex items-center gap-3">
        <Link to="/" aria-label="Back" className="px-4 py-1 -my-1 text-t1-text">
          <BackArrow />
        </Link>
        <span className="t1-label text-t1-text!">Sign in or sign up</span>
      </div>
      <div className="flex-1 bg-t1-surface flex items-center justify-center pt-10 overflow-hidden">
        <T1Logo className="w-full max-w-[720px] h-auto" />
      </div>
      <div className="bg-t1-surface px-4 py-3 t1-label normal-case! tracking-normal!">
        New here? Signing in for the first time creates your account.
      </div>
      <SignInButtons />
    </Screen>
  );
}
