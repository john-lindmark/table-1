import { useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import {
  PUBLIC_NOTICE, counter, demoPath, eventAbout, eventLine, foundEventPath, publicNoticeDue, publicNoticeSeen, resultsPublic, rowLabel, whenText,
  type EventAbout, type FoundEvent,
} from "../lib/leagues";
import { capture } from "../lib/telemetry";
import { Bar, BigAction, Notice, Row, Screen, useEscape } from "./kit";
import { BAR_ICON, Icon } from "./icons";

/* What finding events adds to an event's own screens (contract/public-events-leagues-2026-11-13.md § 1 Clients): a
   found event's row, the About and league rows on the event page, the text panels, and the once-per-device notice
   that results in public events are public (§ 4). */

/** Plain text with its line breaks kept and `https://` links tappable. */
export function LinkedText({ text }: { text: string }) {
  const parts: ReactNode[] = [];
  const re = /https:\/\/[^\s<>"']+[^\s<>"'.,;:!?)\]]/g;
  let last = 0, m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (m.index > last) parts.push(text.slice(last, m.index));
    parts.push(<a key={m.index} href={m[0]} target="_blank" rel="noopener noreferrer nofollow" className="underline underline-offset-2 hover:text-t1-accent [overflow-wrap:anywhere]">{m[0]}</a>);
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return <p className="text-[15px] leading-[22px] whitespace-pre-line break-words">{parts}</p>;
}

/** A screen over the one below it: its own bar with Back, then the content. Esc goes back. */
export function Over({ title, onBack, right, children, bottom }: {
  title: string; onBack: () => void; right?: ReactNode; children: ReactNode; bottom?: ReactNode;
}) {
  useEscape(onBack);
  return (
    <div className="fixed inset-0 z-40 bg-t1-bg overflow-y-auto" role="dialog" aria-modal="true" aria-label={title}>
      <Screen>
        <Bar title={title} onBack={onBack} right={right} />
        <div className="flex-1 min-h-0 flex flex-col gap-px">{children}</div>
        {bottom}
      </Screen>
    </div>
  );
}

/** A text panel (an event's or a league's description): the text, a counter, Save. */
export function TextPanel({ title, value, max, placeholder, onSave, onClose }: {
  title: string; value: string; max: number; placeholder?: string; onSave: (text: string) => Promise<void> | void; onClose: () => void;
}) {
  const [text, setText] = useState(value);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const over = text.length > max;
  const save = async () => {
    setBusy(true);
    try {
      await onSave(text.trim());
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String((e as { message?: unknown } | null)?.message ?? e));
      setBusy(false);
    }
  };
  return (
    <Over title={title} onBack={onClose} right={<span className={`t1-label tabular-nums ${over ? "text-t1-danger!" : ""}`}>{counter(text.length, max)}</span>}
          bottom={<BigAction label="Save" tone="accent" busy={busy} disabled={over} onClick={() => void save()} />}>
      <textarea value={text} autoFocus placeholder={placeholder} onChange={(e) => setText(e.target.value)} aria-label={title}
                className="flex-1 min-h-[240px] w-full bg-t1-surface px-4 py-4 text-[15px] leading-[22px] outline-0 border-0 resize-none placeholder:text-t1-muted/60" />
      {error && <Notice tone="error">{error}</Notice>}
    </Over>
  );
}

/** A found event in a list: a small label (its league, or FRIENDS), the name, one line of data, IN when you're in it. */
export function FoundEventRow({ event, from }: { event: FoundEvent; from: "home" | "find" }) {
  const label = rowLabel(event);
  return (
    <Link to={demoPath(foundEventPath(event))}
          onClick={() => capture("found_event_opened", { format_key: event.format_key ?? "other", visibility: event.visibility ?? "public", km: event.km ?? -1, from })}
          className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3">
      <span className="flex-1 min-w-0 flex flex-col gap-0.5">
        {label && <span className="text-[9px] leading-[12px] uppercase tracking-[1.5px] text-t1-muted truncate">{label}</span>}
        <span className="text-[14px] truncate">{event.name}</span>
        <span className="t1-label truncate">{eventLine(event, whenText(event.starts_at))}</span>
      </span>
      {event.me && <span className="shrink-0 t1-label text-t1-accent!">In</span>}
    </Link>
  );
}

/** An event's About (description and address) and league, read once; null while loading or when the server has none. */
export function useEventAbout(eventId: string | null | undefined, token?: string | null, version: unknown = 0): EventAbout | null {
  const [about, setAbout] = useState<EventAbout | null>(null);
  useEffect(() => {
    if (!eventId) return;
    let live = true;
    void eventAbout(eventId, token).then((a) => live && setAbout(a));
    return () => { live = false; };
  }, [eventId, token, version]);
  return about;
}

/** The event page's About row (when there's a description or address; second line: the address) and league row. */
export function EventAboutRows({ about, eventName }: { about: EventAbout | null; eventName: string }) {
  const [open, setOpen] = useState(false);
  if (!about) return null;
  const has = !!(about.description?.trim() || about.venue_address?.trim());
  const league = about.league;
  if (!has && !league) return null;
  return (
    <>
      {has && <Row title="About" detail={about.venue_address ?? undefined} value={<Icon d={BAR_ICON.arrow} />} onClick={() => setOpen(true)} />}
      {league && (
        <Link to={demoPath(`/league/${league.slug ?? league.id}${league.season_id ? `?season=${league.season_id}` : ""}`)}
              state={{ from: "event" }}
              className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-3 flex items-center gap-3">
          <span className="flex-1 min-w-0 flex flex-col gap-0.5">
            <span className="text-[13px] truncate">{[league.name, league.season].filter(Boolean).join(" · ")}</span>
            <span className="t1-label truncate">{league.final ? "League · the final" : "League"}</span>
          </span>
          <Icon d={BAR_ICON.arrow} />
        </Link>
      )}
      {open && (
        <Over title={eventName} onBack={() => setOpen(false)}>
          {about.venue_address && (
            <div className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
              <span className="t1-label">Address</span>
              <span className="text-[15px] leading-[22px] select-text break-words">{about.venue_address}</span>
            </div>
          )}
          {about.description?.trim() && <div className="bg-t1-surface px-4 py-4"><LinkedText text={about.description} /></div>}
        </Over>
      )}
    </>
  );
}

/** Once per device, at sign-up for a public or league event: results there are public. */
export function PublicResultsNotice({ about, shown }: { about: EventAbout | null; shown: boolean }) {
  const [due] = useState(publicNoticeDue);
  const on = due && shown && resultsPublic(about);
  useEffect(() => {
    if (on) publicNoticeSeen();
  }, [on]);
  return on ? <Notice tone="info">{PUBLIC_NOTICE}</Notice> : null;
}
