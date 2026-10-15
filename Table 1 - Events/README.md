# Match Ops — MTG Team Event Dashboard

A responsive dashboard for running and recording large team-based Magic: The
Gathering events. Optimized for fast, low-error operation during a live match on
a laptop or tablet. Light and dark themes match the Figma design.

## Architecture

This app runs inside Figma Make, which uses a three-tier architecture:

```
React frontend  →  Hono edge function (Supabase)  →  Supabase KV store
```

> **Environment note:** Figma Make does not support custom Postgres tables,
> migrations, DDL, Row Level Security policies, SQL views, or PL/pgSQL database
> functions. The single pre-provisioned key–value table is used instead. The
> guarantees the original spec asked for are still met, just implemented
> differently:
>
> - **Atomic multi-record operations** — each server route reads the event
>   document, mutates it, and writes it back in one handler, so a request either
>   fully succeeds or fails (`create`, `record`, `correct`, `timer`).
> - **Score integrity** — team scores are always computed from pairing results
>   (`computeScores`), never stored as an editable total.
> - **Access control** — role checks (`owner` / `organizer` / `viewer`) run
>   server-side inside every mutating route using the Supabase auth token.
> - **Realtime** — the client subscribes to changes on the KV table for the
>   current event, with a 20s polling fallback.

## Key features

- Email + password and email magic-link authentication (persistent sessions)
- Live dashboard: format sections, per-pairing win selection, diverging score
  bar, large persisted countdown timer with pause/resume and negative overtime
- Record-and-advance flow with confirmation and idempotent finalization
- Result corrections with required reason + append-only audit log
- Event management drawer: rename, set timer, organizers, archive, dark mode
- Loading, empty, saving, saved, offline, and error states

## Backend routes (`/functions/v1/make-server-a539856f`)

| Method | Path | Purpose |
| ------ | ---- | ------- |
| POST | `/signup` | Create user (email auto-confirmed) |
| GET | `/events` | List the user's events |
| POST | `/events` | Create an event atomically from config |
| GET | `/events/:id` | Full event bundle + role + scores |
| POST | `/events/:id/result` | Set a pending pairing result |
| POST | `/events/:id/record` | Record current round and advance |
| POST | `/events/:id/correct` | Correct a result (audited) |
| POST | `/events/:id/timer` | Timer start/pause/resume/set/reset |
| POST | `/events/:id/update` | Rename event / update teams |
| POST | `/events/:id/archive` | Archive (owner only) |
| POST | `/events/:id/members` | Manage organizers (owner only) |
| POST | `/events/seed` | Seed a sample development event |

## Running

The Vite dev server and Supabase connection are managed by Figma Make — no local
`.env` or `vite` commands are needed. Supabase URL / anon key are provided
automatically via `utils/supabase/info.tsx`.

If you edit `supabase/functions/server/index.tsx`, redeploy the edge function
from the **Make settings page** for the changes to take effect.

## Seeding development data

Sign in, then click **Seed sample event** on the event picker. This creates one
event with two teams, three formats, three players per team per format, five
rounds, one recorded round (including a corrected result + audit entry), pending
current-round results, and a running timer.
