import { Link, Navigate, useNavigate } from "react-router-dom";
import { useSession } from "../lib/useSession";
import { SignInButtons } from "../components/SignInButtons";
import { JoinByCode } from "../components/JoinByCode";
import { BackArrow, BigAction, Screen, T1Logo } from "../components/kit";
import { FAN_CONTENT, copyrightLine } from "../lib/legal";
import { SPOTS, shotUrl, spots } from "../lib/spots";

/** table-1.site for signed-out visitors: what Table 1 is, with sign-in one tap away. */
export function Landing() {
  const navigate = useNavigate();
  return (
    <Screen width="full">
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
        <h1 className="text-[22px] leading-8 uppercase tracking-[4px] font-bold max-w-[640px]">{SPOTS.product.tagline}</h1>
        <p className="text-[14px] leading-[22px] text-t1-muted max-w-[560px]">{SPOTS.product.line}</p>
      </div>
      <BigAction label="Sign in or sign up" tone="accent" onClick={() => navigate("/sign-in")} />

      <div className="bg-t1-surface px-4 pt-4 pb-2 t1-label">Playing tonight? Enter the event code</div>
      <JoinByCode />

      <Spots />

      <div className="flex-1 bg-t1-surface" />
      <footer className="bg-t1-surface px-4 py-4 flex flex-wrap gap-x-6 gap-y-2 t1-label">
        <Link to="/terms" className="hover:text-t1-text">Terms</Link>
        <Link to="/privacy" className="hover:text-t1-text">Privacy</Link>
        <Link to="/delete-account" className="hover:text-t1-text">Delete account</Link>
        <span>{copyrightLine()}</span>
        <p className="basis-full normal-case tracking-normal">{FAN_CONTENT}</p>
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

/** The feature spots (contract/feature-spots-2026-11-01.md): copy beside the phone shot of the real screen, shot and
 *  copy swapping sides down the page on a wide window, stacked on a phone. The same spots open the apps. */
function Spots() {
  return (
    <div className="flex flex-col gap-px">
      {spots().map((s, i) => {
        const src = shotUrl(s.key);
        return (
          <section key={s.key} className="grid gap-px md:grid-cols-2">
            <div className={`bg-t1-surface px-4 py-8 md:px-8 md:py-12 flex flex-col gap-3 justify-center ${i % 2 ? "md:order-last" : ""}`}>
              <h2 className="t1-label">{s.title}</h2>
              <p className="text-[20px] leading-7 uppercase tracking-[2px] font-bold max-w-[480px]">{s.headline}</p>
              <p className="text-[14px] leading-[22px] text-t1-muted max-w-[480px]">{s.body}</p>
            </div>
            {src && (
              <div className="bg-t1-surface flex justify-center items-start px-4 pt-6 max-h-[440px] md:max-h-[560px] overflow-hidden">
                <img src={src} alt={s.headline} width={390} height={844} loading={i === 0 ? "eager" : "lazy"}
                     className="w-[260px] md:w-[300px] h-auto border border-t1-bg border-b-0" />
              </div>
            )}
          </section>
        );
      })}
    </div>
  );
}
