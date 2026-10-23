import { useEffect, useState } from "react";
import { phonePlatform, signInHint, storeLink } from "../lib/appHandoff";
import { useSession } from "../lib/useSession";
import { capture } from "../lib/telemetry";

const DISMISSED_KEY = "t1.getTheApp.dismissed";

/**
 * After joining on a phone's browser: the app, and how to sign in so this event is already there
 * (contract/qr-sign-up-2026-10-23.md § Get the app). Hidden on computers, for guests, once dismissed, and while
 * that phone's store link isn't set (VITE_IOS_APP_URL / VITE_ANDROID_APP_URL).
 */
export function GetTheApp({ eventId }: { eventId: string }) {
  const { session } = useSession();
  const phone = phonePlatform(navigator.userAgent);
  const base = phone === "ios" ? import.meta.env.VITE_IOS_APP_URL : import.meta.env.VITE_ANDROID_APP_URL;
  const link = phone ? storeLink(phone, base, eventId) : null;
  const hint = signInHint(session?.user.app_metadata.provider, session?.user.email);
  const [dismissed, setDismissed] = useState(() => {
    try {
      return localStorage.getItem(DISMISSED_KEY) === "1";
    } catch {
      return false;
    }
  });
  const shown = !!phone && !!link && !!hint && !dismissed;

  useEffect(() => {
    if (shown) capture("app_handoff_shown", { platform: phone });
  }, [shown, phone]);

  if (!shown) return null;

  function dismiss() {
    setDismissed(true);
    try {
      localStorage.setItem(DISMISSED_KEY, "1");
    } catch {
      /* private mode: hidden until the page reloads */
    }
  }

  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-4 flex flex-col gap-1.5">
        <span className="t1-label">Get the app</span>
        <p className="text-[13px] leading-relaxed">
          Your seat is on your account. In the {phone === "ios" ? "iPhone" : "Android"} app, sign in the same way and
          this event is waiting on your Events tab.
        </p>
        <p className="text-[12px] text-t1-muted">{hint}</p>
      </div>
      <div className="flex gap-px">
        <button
          onClick={dismiss}
          className="flex-1 bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 text-[12px] uppercase tracking-[1px]"
        >
          Not now
        </button>
        <a
          href={link}
          onClick={() => capture("app_handoff_tapped", { platform: phone })}
          className="flex-1 bg-t1-text text-t1-bg px-4 py-4 text-[12px] uppercase tracking-[1px] text-center font-bold"
        >
          Get the app
        </a>
      </div>
    </div>
  );
}
