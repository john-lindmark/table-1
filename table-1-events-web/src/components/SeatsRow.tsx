import { SEAT_FORMATS, seatFormatLabel } from "../lib/leagues";
import { capture } from "../lib/telemetry";
import { FilterRow } from "./FilterRow";

/**
 * Team Trios' Seats row (contract/teams-finals-alerts-2026-11-13.md § 1): three cells `A · MODERN` `B · STANDARD`
 * `C · PIONEER`, each a dropdown of the formats a seat can play.
 */
export function SeatsRow({ seats, onChange }: { seats: string[]; onChange: (next: string[]) => void }) {
  return (
    <div className="flex flex-col bg-t1-surface">
      <span className="t1-label px-4 pt-3 pb-2">Seats</span>
      <div className="pt-px bg-t1-bg">
        <FilterRow dense telemetry={(_f, value) => capture("trios_seat_set", { format: value })}
                   cells={[0, 1, 2].map((i) => ({
                     name: `Seat ${"ABC"[i]}`, value: `${"ABC"[i]} · ${seatFormatLabel(seats[i])}`, current: seats[i] ?? null,
                     options: SEAT_FORMATS.map((f) => ({ value: f.key, label: f.label })),
                     onPick: (v: string) => { if (v !== seats[i]) onChange(seats.map((s, j) => (j === i ? v : s))); },
                   }))} />
      </div>
    </div>
  );
}
