import { Suspense, lazy, useEffect, useRef, useState } from "react";
import { errorMessage, setEventSchedule, updateEventDetails } from "../../lib/api";
import { CutAndRoundsFields, DecklistsFields, ScheduleFields, type ScheduleValue } from "../../components/EventExtras";
import { isTeamFormat, typeOfFormat } from "../../lib/formats";
import { detailsFromEvent, detailsToInput, type DetailsState } from "../../lib/organizer";
import type { Table1Event } from "../../lib/types";
import { Field, Notice, Row, Segmented } from "../../components/kit";
import { TextPanel } from "../../components/EventListing";
import { BAR_ICON, Icon } from "../../components/icons";
import {
  ADDRESS_MAX, DESCRIPTION_MAX, FIND_PICKS, counter, eventAboutOrMissing, eventListingSet, leaguesError, type EventAbout, type FindPick,
} from "../../lib/leagues";
import { FormatPicker, ProductPicker, RoundTimerSwitch, cubeUrlProblem } from "../../components/EventFormFields";
import { RotoPairingFields, RotoSetupFields } from "../roto/lazy";
import { VISIBILITY_LABEL, currentFix, setEventLocation, type EventVisibility } from "../../lib/nearby";

const DEBOUNCE_MS = 600;

/** An event's League row: only organizers who run a league download it. */
const EventLeagueRow = lazy(() => import("../LeagueTools").then((m) => ({ default: m.EventLeagueRow })));

/** A place for distances, only where the browser already allows location: listing an event never asks for it. */
async function allowedFix() {
  try {
    const p = await navigator.permissions?.query({ name: "geolocation" as PermissionName });
    return p?.state === "granted" ? await currentFix(6000) : null;
  } catch {
    return null;
  }
}

/** What we refuse to send at all (the server's 22023 messages cover the rest). */
function localProblem(s: DetailsState): string | null {
  if (s.formatName === "roto" && !s.cubeName.trim()) return "Name the cube, or choose one of your Library cubes";
  if (typeOfFormat(s.formatName) === "limited" && (s.product === "cube" || s.formatName === "roto")) return cubeUrlProblem(s.cubeUrl);
  return null;
}

/**
 * Setup → Details. Every change saves the full state with update_event_details: steppers and pickers at once,
 * text 600 ms after typing stops (or on blur). Saves run one after another so the last one wins.
 */
export function DetailsForm({ event, onSaved, players = 0 }: { event: Table1Event; onSaved: () => void; players?: number }) {
  const [state, setState] = useState<DetailsState>(() => detailsFromEvent(event));
  const [error, setError] = useState<string | null>(null);
  const [schedule, setSchedule] = useState<ScheduleValue>(() => ({
    startsAt: event.startsAt, venueName: event.venueName ?? "", capacity: event.capacity,
  }));
  /** Description, address and league (contract/public-events-leagues-2026-11-13.md § 1): "missing" while the server
   *  has no listings, and then only the older choices show, as before. */
  const [about, setAbout] = useState<EventAbout | "missing" | null>(null);
  const [address, setAddress] = useState("");
  const [describing, setDescribing] = useState(false);
  useEffect(() => {
    let live = true;
    void eventAboutOrMissing(event.id).then((a) => {
      if (!live) return;
      setAbout(a);
      if (a && a !== "missing") setAddress(a.venue_address ?? "");
    });
    return () => { live = false; };
  }, [event.id]);
  const listing = about !== "missing";
  const info = about && about !== "missing" ? about : null;
  /** Who can find it moves at once. Public, Friends and Private go through event_listing_set; the two older choices
   *  pin the event where the organizer stands (the browser asks for location), after unlisting a listed event. */
  const [pendingVis, setPendingVis] = useState<Table1Event["visibility"] | null>(null);
  const listed = event.visibility === "public" || event.visibility === "friends";
  async function changeFind(pick: FindPick) {
    const to = pick === "private" ? "link_only" : pick;
    if (to === event.visibility) return;
    setPendingVis(to);
    try {
      const fix = pick === "private" ? null : await allowedFix();
      const r = await eventListingSet(event.id, { find: pick, ...(fix ? { lat: fix.lat, lng: fix.lng } : {}) });
      // An older Nearby or invitation-only event stays as it is on Private: move it to the link by hand.
      if (pick === "private" && r.visibility !== "link_only") {
        const here = await currentFix();
        if (!here) throw new Error("Turn on location to change who can find it.");
        await setEventLocation(event.id, here, event.venueName, "link_only");
      }
      setError(null);
      onSaved();
    } catch (e) {
      setError(leaguesError(e));
    } finally {
      setPendingVis(null);
    }
  }
  async function changeVisibility(v: EventVisibility) {
    if (v === event.visibility) return;
    setPendingVis(v);
    try {
      const fix = await currentFix();
      if (!fix) setError("Turn on location to change who can find it.");
      else {
        if (listed) await eventListingSet(event.id, { find: "private" });
        await setEventLocation(event.id, fix, event.venueName, v);
        setError(null);
        onSaved();
      }
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setPendingVis(null);
    }
  }
  async function saveListing(patch: { description?: string | null; venue_address?: string | null }) {
    const r = await eventListingSet(event.id, patch);
    setAbout((a) => (a && a !== "missing" ? { ...a, description: r.description, venue_address: r.venue_address } : a));
    setError(null);
  }
  const saveAddress = () => {
    const next = address.trim();
    if (!info || next === (info.venue_address ?? "")) return;
    saveListing({ venue_address: next || null }).catch((e) => setError(leaguesError(e)));
  };
  const scheduleTimer = useRef<number | null>(null);
  const scheduleLatest = useRef(schedule);

  /** When / where / cap save through set_event_schedule: the venue after a pause, the rest at once. */
  function commitSchedule(next: ScheduleValue, immediate: boolean) {
    scheduleLatest.current = next;
    setSchedule(next);
    if (scheduleTimer.current != null) window.clearTimeout(scheduleTimer.current);
    scheduleTimer.current = window.setTimeout(() => {
      scheduleTimer.current = null;
      setEventSchedule(eventId, scheduleLatest.current).then(
        () => { setError(null); onSavedRef.current(); },
        (e) => setError(errorMessage(e)),
      );
    }, immediate ? 0 : DEBOUNCE_MS);
  }

  const latest = useRef(state);
  const timer = useRef<number | null>(null);
  const chain = useRef<Promise<void>>(Promise.resolve());
  const seq = useRef(0);
  const onSavedRef = useRef(onSaved);
  onSavedRef.current = onSaved;
  const eventId = event.id;

  function save() {
    if (timer.current != null) {
      window.clearTimeout(timer.current);
      timer.current = null;
    }
    const snapshot = latest.current;
    const problem = localProblem(snapshot);
    if (problem) {
      setError(problem);
      return;
    }
    const mine = ++seq.current;
    chain.current = chain.current.then(async () => {
      try {
        await updateEventDetails(eventId, detailsToInput(snapshot));
        if (mine === seq.current) {
          setError(null);
          onSavedRef.current();
        }
      } catch (e) {
        if (mine === seq.current) setError(errorMessage(e));
      }
    });
  }

  /** Text: debounced. Steppers, pickers: immediately. */
  function commit(patch: Partial<DetailsState>, immediate: boolean) {
    const next = { ...latest.current, ...patch };
    latest.current = next;
    setState(next);
    if (immediate) {
      save();
    } else {
      if (timer.current != null) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(save, DEBOUNCE_MS);
    }
  }

  /** Blur: save now if typing left a save pending. */
  function flush() {
    if (timer.current != null) save();
  }

  // Roto: roto_set_cube renames the event's cube; take it in without saving it back.
  useEffect(() => {
    if (event.formatName !== "roto" || !event.cubeName || event.cubeName === latest.current.cubeName) return;
    latest.current = { ...latest.current, cubeName: event.cubeName, cubeUrl: event.cubeUrl ?? "" };
    setState(latest.current);
  }, [event.formatName, event.cubeName, event.cubeUrl]);

  // Leaving the tab with a pending edit still saves it.
  const saveRef = useRef(save);
  saveRef.current = save;
  useEffect(
    () => () => {
      if (timer.current != null) saveRef.current();
    },
    [],
  );

  const limited = typeOfFormat(state.formatName) === "limited";
  const team = isTeamFormat(state.formatName);
  const roto = state.formatName === "roto";
  const shownVis = pendingVis ?? event.visibility;

  return (
    <>
      <Field label="Event name" value={state.name} onChange={(v) => commit({ name: v.slice(0, 80) }, false)} onBlur={flush}
             placeholder={event.autoName ? event.name : "Named from the format and date"} />
      <FormatPicker
        format={state.formatName}
        onFormat={(f) => commit({ formatName: f }, true)}
        formatOther={state.formatOther}
        onFormatOther={(v) => commit({ formatOther: v }, false)}
        onCommit={flush}
      />
      {roto && event.formatName === "roto" ? (
        // The pool is one of your Library cubes (roto_set_cube), not a typed name.
        <RotoSetupFields event={event} players={players} onChanged={onSaved} />
      ) : limited && (
        <ProductPicker
          cubeOnly={roto}
          product={state.product}
          onProduct={(p) => commit({ product: p }, true)}
          set={state.set}
          onSet={(s) => commit({ set: s }, true)}
          setNameText={state.setNameText}
          onSetNameText={(v) => commit({ setNameText: v }, false)}
          cubeName={state.cubeName}
          onCubeName={(v) => commit({ cubeName: v }, false)}
          cubeUrl={state.cubeUrl}
          onCubeUrl={(v) => commit({ cubeUrl: v }, false)}
          onCommit={flush}
        />
      )}
      {team && (
        <Segmented
          label="Team size"
          value={state.teamSize}
          onChange={(n) => commit({ teamSize: n }, true)}
          options={[
            { value: 3, label: "3" },
            { value: 4, label: "4" },
          ]}
        />
      )}
      {roto && <RotoPairingFields pairing={state.pairing} onPairing={(p) => commit({ pairing: p }, true)} players={players} />}
      <ScheduleFields value={schedule} onChange={(v) => commitSchedule(v, v.venueName === schedule.venueName)} />
      {!(roto && state.pairing === "round_robin") && (
        <CutAndRoundsFields
          autoRounds={state.autoRounds} onAutoRounds={(v) => commit({ autoRounds: v }, true)}
          rounds={state.rounds} onRounds={(n) => commit({ rounds: n }, true)}
          topCut={state.topCut} onTopCut={(v) => commit({ topCut: v }, true)}
          players={players} swiss={!team && !(roto && state.pairing === "round_robin")}
        />
      )}
      <RoundTimerSwitch on={state.showClock} onChange={(on) => commit({ showClock: on }, true)} />
      {!limited && <DecklistsFields mode={state.decklists} onMode={(m) => commit({ decklists: m }, true)} />}
      {info && (
        <>
          <Row title="Description" detail={info.description?.trim() ? counter(info.description.length, DESCRIPTION_MAX) : "None"}
               value={<Icon d={BAR_ICON.arrow} />} onClick={() => setDescribing(true)} />
          <Field label="Address" value={address} onChange={(v) => setAddress(v.slice(0, ADDRESS_MAX))} onBlur={saveAddress} placeholder="Street and city" />
          <Suspense fallback={null}><EventLeagueRow eventId={event.id} onChanged={onSaved} /></Suspense>
        </>
      )}
      {listing ? (
        <>
          <Segmented label="Who can find it" value={shownVis === "public" || shownVis === "friends" ? shownVis : shownVis === "link_only" ? "private" : null}
                     onChange={(v) => void changeFind(v)} options={FIND_PICKS} />
          <Segmented value={shownVis === "nearby" || shownVis === "private" ? shownVis : null} onChange={(v) => void changeVisibility(v)}
                     options={[{ value: "nearby" as const, label: "Nearby + QR" }, { value: "private" as const, label: "Invitation only" }]} />
        </>
      ) : (
        <Segmented label="Who can find it" value={shownVis === "public" || shownVis === "friends" ? null : shownVis} onChange={(v) => void changeVisibility(v)}
                   options={(["nearby", "link_only", "private"] as const).map((v) => ({ value: v, label: VISIBILITY_LABEL[v] }))} />
      )}
      <Notice tone="info">
        {shownVis === "public" ? "Listed for everyone in Find events. Anyone can open its page and sign up."
          : shownVis === "friends" ? "Listed for the organizers' friends. The link still opens for whoever has it."
          : shownVis === "nearby" ? "Players within 150 m can find and join it. Pinned where you stand."
          : shownVis === "link_only" ? "Anyone with the code, link or QR code can join."
          : "Only people you add or invite can join."}
      </Notice>
      {describing && info && (
        <TextPanel title="Description" value={info.description ?? ""} max={DESCRIPTION_MAX} placeholder="What players should know"
                   onSave={(text) => saveListing({ description: text || null })} onClose={() => setDescribing(false)} />
      )}
      {error && <Notice tone="error">{error}</Notice>}
      <Notice tone="info">Details lock when round 1 is paired. Changes save as you make them.</Notice>
    </>
  );
}
