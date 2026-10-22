import { useEffect, type ReactNode } from "react";
import { Link, useLocation } from "react-router-dom";
import { NAV_GROUPS, isTypingTarget, navKeyFor, sidebarOn } from "../lib/desktop";
import { isLibraryDemo } from "../lib/libraryDemo";
import { listKindOf } from "../lib/lists";
import { capture } from "../lib/telemetry";
import { useSession } from "../lib/useSession";
import { CardPeekHost } from "./CardPeek";
import { T1Logo } from "./kit";

/** Sidebar width; the content starts one hairline to its right. */
const SIDEBAR_W = 224;

/**
 * The desktop frame (contract/web-desktop-2026-10-22.md): on a wide window and once signed in, a sidebar with
 * every top-level screen stays on the left. Below the desktop width nothing here shows and the screens keep their
 * phone layout, Events | Collection | Account tabs included.
 */
export function DesktopShell({ children }: { children: ReactNode }) {
  const { session } = useSession();
  const { pathname } = useLocation();
  const signedIn = !!session || (import.meta.env.DEV && isLibraryDemo());
  const on = signedIn && sidebarOn(pathname);

  // "/" jumps to the screen's search (or first text field), as on most desktop web apps.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "/" || e.metaKey || e.ctrlKey || e.altKey || isTypingTarget(document.activeElement)) return;
      const field = document.querySelector<HTMLInputElement>(
        "main input[type=search], main input[type=text], main input:not([type])",
      );
      if (!field) return;
      e.preventDefault();
      field.focus();
      field.select();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <>
      {on && <Sidebar pathname={pathname} />}
      <main className={on ? "lg:pl-[225px]" : undefined}>{children}</main>
      <CardPeekHost />
    </>
  );
}

function Sidebar({ pathname }: { pathname: string }) {
  const active = navKeyFor(pathname, listKindOf);
  return (
    <nav aria-label="Table 1" className="hidden lg:flex fixed inset-y-0 left-0 z-30 flex-col gap-px overflow-y-auto bg-t1-bg"
         style={{ width: SIDEBAR_W }}>
      <Link to="/" aria-label="Table 1 home" className="shrink-0 bg-t1-surface px-4 py-5 flex items-center hover:text-t1-accent">
        <T1Logo className="h-5 w-auto" />
      </Link>
      {NAV_GROUPS.map((g) => (
        <div key={g.title} className="shrink-0 flex flex-col gap-px">
          <p className="bg-t1-surface px-4 pt-4 pb-2 t1-label">{g.title}</p>
          {g.items.map((it) => {
            const on = it.key === active;
            return (
              <Link key={it.key} to={it.to} aria-current={on ? "page" : undefined}
                    onClick={() => capture("desktop_nav_used", { to: it.key })}
                    className={`px-4 py-2.5 text-[11px] uppercase tracking-[1.5px] truncate ${
                      on ? "bg-t1-text text-t1-bg" : "bg-t1-surface hover:bg-t1-surface-hover text-t1-text"
                    }`}>
                {it.title}
              </Link>
            );
          })}
        </div>
      ))}
      <div className="flex-1 min-h-4 bg-t1-surface" />
    </nav>
  );
}
