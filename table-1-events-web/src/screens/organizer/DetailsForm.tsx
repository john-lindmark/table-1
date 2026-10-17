import { useEffect, useRef, useState } from "react";
import { errorMessage, updateEventDetails } from "../../lib/api";
import { isTeamFormat, typeOfFormat } from "../../lib/formats";
import { detailsFromEvent, detailsToInput, type DetailsState } from "../../lib/organizer";
import type { Table1Event } from "../../lib/types";
import { Field, Notice, Row, Segmented, Stepper } from "../../components/kit";
import { FormatPicker, ProductPicker, RoundTimerSwitch, cubeUrlProblem } from "../../components/EventFormFields";
import { RotoPairingFields, RotoSetupFields } from "../roto/lazy";

const DEBOUNCE_MS = 600;

/** What we refuse to send at all (the server's 22023 messages cover the rest). */
function localProblem(s: DetailsState): string | null {
  if (!s.autoName && !s.name.trim()) return "Name the event (up to 80 characters)";
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
      {state.autoName ? (
        <Row title={event.name} detail="Named from the format and date" />
      ) : (
        <Field label="Event name" value={state.name} onChange={(v) => commit({ name: v.slice(0, 80) }, false)} onBlur={flush} />
      )}
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
      {!(roto && state.pairing === "round_robin") && (
        <Stepper label="Rounds" value={state.rounds} onChange={(n) => commit({ rounds: n }, true)} min={1} max={15} />
      )}
      <RoundTimerSwitch on={state.showClock} onChange={(on) => commit({ showClock: on }, true)} />
      {error && <Notice tone="error">{error}</Notice>}
      <Notice tone="info">Details lock when round 1 is paired. Changes save as you make them.</Notice>
    </>
  );
}
