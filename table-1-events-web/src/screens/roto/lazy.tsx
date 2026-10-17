// The roto screens load on first use, so events that aren't rotos never download them (web bundle budget).
// The event screens import from here; each component shows `fallback` while its chunk loads.
import { Suspense, lazy, type ComponentProps, type ComponentType, type ReactNode } from "react";
import type * as Draft from "./RotoDraft";
import type * as Setup from "./RotoSetup";

const draft = () => import("./RotoDraft");
const setup = () => import("./RotoSetup");

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function lazyPart<P extends object>(load: () => Promise<Record<string, any>>, name: string, fallback: ReactNode = null): ComponentType<P> {
  const L = lazy(() => load().then((m) => ({ default: m[name] as ComponentType<P> }))) as unknown as ComponentType<P>;
  return (props: P) => (
    <Suspense fallback={fallback}>
      <L {...props} />
    </Suspense>
  );
}

const loading = <div className="h-[100dvh] flex items-center justify-center t1-label bg-t1-bg">Loading draft…</div>;

export const RotoDraftGate = lazyPart<ComponentProps<typeof Draft.RotoDraftGate>>(draft, "RotoDraftGate", loading);
export const RotoDraftOverlay = lazyPart<ComponentProps<typeof Draft.RotoDraftOverlay>>(draft, "RotoDraftOverlay");
export const RotoPairingFields = lazyPart<ComponentProps<typeof Setup.RotoPairingFields>>(setup, "RotoPairingFields");
export const RotoPickOrder = lazyPart<ComponentProps<typeof Setup.RotoPickOrder>>(setup, "RotoPickOrder");
export const RotoSetupFields = lazyPart<ComponentProps<typeof Setup.RotoSetupFields>>(setup, "RotoSetupFields");
export const RotoStartAction = lazyPart<ComponentProps<typeof Setup.RotoStartAction>>(setup, "RotoStartAction");
export const RotoSchedule = lazyPart<ComponentProps<typeof Setup.RotoSchedule>>(setup, "RotoSchedule");

/** After Create: link the Library cube with the typed name, or import the Cube Cobra link (RotoSetup.linkRotoCube). */
export async function linkRotoCube(eventId: string, name: string, url: string) {
  await (await setup()).linkRotoCube(eventId, name, url);
}
