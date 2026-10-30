import { useEffect, useRef, useState } from "react";
import { errorMessage, setEventSchedule, updateEventDetails } from "../../lib/api";
import { CutAndRoundsFields, DecklistsFields, ScheduleFields, type ScheduleValue } from "../../components/EventExtras";
import { isTeamFormat, typeOfFormat } from "../../lib/formats";
import { detailsFromEvent, detailsToInput, type DetailsState } from "../../lib/organizer";
import type { Table1Event } from "../../lib/types";
import { Field, Notice, Segmented } from "../../components/kit";
import { FormatPicker, ProductPicker, RoundTimerSwitch, cubeUrlProblem } from "../../components/EventFormFields";
import { RotoPairingFields, RotoSetupFields } from "../roto/lazy";
import { VISIBILITY_LABEL, currentFix, setEventLocation, type EventVisibility } from "../../lib/nearby";

const DEBOUNCE_MS = 600;

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
  /** Who can find it moves at once; it pins the event where the organizer stands (the browser asks for location). */
  const [pendingVis, setPendingVis] = useState<EventVisibility | null>(null);
  async function changeVisibility(v: EventVisibility) {
    if (v === event.visibility) return;
    setPendingVis(v);
    try {
      const fix = await currentFix();
      if (!fix) setError("Turn on location to change who can find it.");
      else {
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
      <Segmented label="Who can find it" value={pendingVis ?? event.visibility} onChange={(v) => void changeVisibility(v)}
                 options={(["nearby", "link_only", "private"] as const).map((v) => ({ value: v, label: VISIBILITY_LABEL[v] }))} />
      <Notice tone="info">
        {(pendingVis ?? event.visibility) === "nearby" ? "Players within 150 m can find and join it. Pinned where you stand."
          : (pendingVis ?? event.visibility) === "link_only" ? "Anyone with the code, link or QR code can join."
          : "Only people you add or invite can join."}
      </Notice>
      {error && <Notice tone="error">{error}</Notice>}
      <Notice tone="info">Details lock when round 1 is paired. Changes save as you make them.</Notice>
    </>
  );
}
