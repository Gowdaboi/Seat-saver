# Catering Seating & Round Management App

Multi-tenant app for caterers running Indian wedding-style events: hosts design a
floor of sections/tables/seats, guests scan a QR to book seats, and Pankti
(banana-leaf) service runs in timed rounds with seat reassignment and no-show
handling. `project-spec.md` is the living spec — every non-obvious design
decision is appended to its "Resolved decisions" section with the reasoning.
Read that before changing behavior; add to it when you make a new call.

## Stack

- **Flutter** (Dart), single codebase. Only ever verified on **Flutter Web** —
  no Xcode or Android SDK on this machine.
- **Supabase**: Postgres + RLS, Auth, Realtime, `pg_cron`.
- `go_router` for navigation. Guest routes are event-scoped (`/e/:eventId/...`).
- Flutter SDK is **not on PATH** — use `$HOME/development/flutter/bin/flutter`.

## Architecture rules

**Multi-tenancy is RLS, keyed off two helpers** (`0002_rls.sql`):
`auth_caterer_id()` and `auth_guest_id()` map `auth.uid()` to the caterer/guest
row. Every policy scopes through them. Hosts authenticate with email/password;
guests with phone OTP (Twilio).

**Anything atomic, or that must bypass RLS, is a `security definer` function**,
never client-side writes. Each one starts with an explicit ownership check that
raises `'not your section'` (or similar) — the definer rights are why that check
can't be skipped. Current RPCs:

| Function | Purpose |
|---|---|
| `book_seats(event, seats[], party, round?)` | guest books; round-scoped for Pankti |
| `host_assign_seats(event, seats[], party, name, phone, round?)` | host books for a walk-in/VIP (guest may have no auth account) |
| `ensure_bookable_round(event, party)` | earliest round with room; opens the next sitting when all are full |
| `seats_for_round(section, round?)` | seat list with availability *for that round* |
| `free_seat_count_for_round(event, round)` | capacity remaining in a round |
| `start_round(event)` | complete current, start next, hand seat holds over |
| `check_in_booking` | QR scan → seats occupied |
| `enqueue_due_round_reminders()` | SQL cron, every minute: queue reminders for rounds starting within the lead time |
| `claim_due_round_reminders(limit)` | `service_role` only — hands pending reminders to the sender |
| `mark_round_reminder_sent` / `_failed` | `service_role` only — send outcome back onto the row |
| `get_booking_by_cancel_token` / `cancel_booking_by_token` | **anon-callable**; the SMS cancel link |
| `configure_section_layout` / `configure_hall_rows` / `reflow_section_layout` | floor layout |
| `mark_booking_no_show`, `accept_/reject_/expire_reassignment_offer`, `advance_reassignment_group`, `get_public_event_info` | rounds + reassignment engine |

## Domain model — read before touching seats or bookings

**Seat availability is per-round for Pankti** (`0014`). There is no
`round_seats` table and none is needed: a seat is taken for round R iff an
*active* (`requested`/`confirmed`) booking whose `round_id = R` holds it via
`booking_seats`. Never decide bookability from `seats.status` for Pankti.

**`seats.status` means only what is physically true right now** —
`available | booked | occupied | cleaning`. It is not a reservation ledger.
`booked` means "held for the sitting currently being served". A booking for a
*future* round leaves the physical seat alone until `start_round()`
materialises that round's holds. Buffet is the exception: it has no rounds, so
there status *is* the reservation.

**Any screen that shows seats must show reservations too, or the host sees
nothing happen.** This is the direct consequence of the rule above and it has
already caused one "the app is broken" report: assigning a seat for an
upcoming Pankti round creates a confirmed booking but changes no seat status,
so the grid and every status counter stay exactly as they were. Read
reservations from `bookings` + `booking_seats` (active statuses, joined to
`rounds`) and render them on a *separate axis* from the four physical states —
indigo outline plus an `R2` badge on the seat grid, seat counts on the round
chips. Do not fix this by writing to `seats.status` for a *future* round; that
reintroduces the single-sitting model 0014 removed. Decide whether to draw the
badge by comparing the seat's `current_booking_id` against the booking, never
by asking whether the round is `upcoming` — the round-status version hid
current-round bookings, which is exactly the case that needed showing.

**`start_round()` materialises holds once, so booking into the *running*
round must hold its seat itself** (`0017`). A Pankti booking for a future
sitting deliberately holds nothing — but a booking made *after* its round
started had nothing to materialise it, and that is the ordinary path for host
assignment, which exists to seat walk-ins during service. The seat stayed
`available` all event: invisible on the grid, uncounted by every metric, and
offerable to someone else. `book_seats`/`host_assign_seats` now claim the seat
when the target round is `current` (or the event is buffet), guarded on
`status = 'available'` so an occupied or mid-clean seat is never overwritten.

**A booking picks its round when it is made.** An earlier design attached
`round_id` late, in a sweep at round start; `0014` reversed that and deleted the
sweep. Don't reintroduce it.

**Freeing a seat must clear `current_booking_id`, not just the status.** That
column is what `check_in_booking()` tests to decide whether a scanned QR still
holds the seat, so a stale value lets a departed guest re-scan an old QR and
retake a seat the host just freed. This bug has been introduced twice; both
times on Buffet, where no round check catches it. Every path back to
`available` goes through one patch that nulls it.

**Vacating a seat keeps the booking.** The past-event recap counts bookings; a
guest who left is not a booking that never happened.

**Reminders count back from `rounds.scheduled_start_at`, never `started_at`.**
`started_at` is stamped when the host presses Start, which is too late to
warn anyone. `scheduled_start_at` is nullable and an unscheduled round simply
sends nothing. The due window is strictly *before* the round, so a window the
cron missed stays missed — a late "starts in 5 minutes" is worse than silence.

**Cancelling a booking releases only seats where `current_booking_id` is that
booking.** A booking for a future sitting holds no physical seat, so blanket-
freeing every row in its `booking_seats` would evict the sitting currently
being served. Per-round availability frees a future booking's seats on its own
the moment the status flips to `cancelled`.

**Derived values are never stored.** Section capacity is summed from its tables'
seats; a second editable field could only ever disagree with the tables it
describes. Same reasoning applies elsewhere — don't add a denormalized total.

**Destructive layout RPCs refuse when a section has history.** Both
`configure_*` functions reject if any seat is in use *or* if `booking_seats`
holds any past booking for that section — regenerating would yank a seat from a
seated guest, or cascade-delete the past-events record. The host must delete the
section instead: visible and deliberate. `reflow_section_layout` has no such
guard because it only moves grid coordinates.

## Floor layout

`lib/features/shared/widgets/floor_layout.dart` (`FloorLayoutView`) is the
**single renderer for both the host's design preview and the guest's seat
picker** — so what the host arranges is literally what the guest books from.
Don't fork it.

- Geometry is a coarse grid (`grid_row`, `grid_col`), not free x/y pixels: hosts
  describe a seating plan, they don't draw to scale.
- A "table" is a Pankti-style *row* of seats with a bar down the middle, not a
  round table. `orientation` (horizontal/vertical) sets which way it runs.
- `seating_side` (`both`/`near`/`far`) puts seats on one side only, for tables
  against a wall or stage. Near/far are **orientation-relative** (near = top for
  horizontal, left for vertical); the host-facing UI translates that to
  "Top only"/"Left only" so hosts never think in near/far.
- Grid math must stay identical between the Dart preview and the SQL RPC, or the
  host previews something different from what they get:
  `cols = ceil(tableCount / rows)`, table `i` (0-based) at `(i / cols, i % cols)`.
- Hall-rows sections alternate `far`/`near` per row so consecutive rows face each
  other across a shared aisle. **Derive facing arrows and row gaps from each
  row's own `seating_side`, never from row-index parity** — parity broke on real
  data.

## Workflow for any backend change

Established and worth keeping — it has caught real bugs:

1. Write the migration in `supabase/migrations/NNNN_name.sql`.
2. `flutter analyze` && `flutter test`.
3. **Test against local Postgres** (see below) — rebuild the DB from scratch,
   apply all migrations, run a purpose-written SQL script covering the happy
   path *and* adversarial cases (cross-tenant access, refusal guards).
4. Apply to the real Supabase project via the dashboard SQL editor.
5. `flutter build web`, then verify in the browser.

### Local Postgres testing

Postgres.app, binaries at
`/Users/kushaldayanand/Applications/Postgres.app/Contents/Versions/18/bin`.
Socket dir must be short (`/tmp/ccpgsock`) — the scratchpad path exceeds the
103-byte Unix socket limit. Connect as the `postgres` role.

A `0000_supabase_stub.sql` in the session scratchpad stubs what the Supabase
platform normally provides: the `auth` schema, `auth.users`, `auth.uid()` (reads
a session var so you can simulate logins), the `anon`/`authenticated` roles, and
their default `public` grants. App migrations never declare those grants because
real Supabase already has them.

`0003_reassignment_engine.sql` fails locally on `extension "pg_cron" is not
available` — **expected**, managed Supabase has it. Everything after still applies.

## Gotchas already hit

- **Supabase built-in mailer is rate-limited to 2 emails/hour.** No dashboard
  bypass — "send recovery" and "magic link" draw from the same pool.
- **Confirm-email breaks naive signup:** `signUp()` establishes no session, so a
  following RLS-gated insert has no `auth.uid()`. Fixed with
  `ensureCatererProfile()` called on *login*, with `business_name` carried
  through auth metadata.
- **Site URL must match the app's port** (8765), or confirmation links dead-end.
- Already-registered emails are detected via `res.user!.identities` being empty
  (Supabase's documented anti-enumeration behavior).
- **Supabase installs extensions into an `extensions` schema, not `public`.**
  Every `security definer` function here pins `set search_path = public`, so
  any call to an extension function (`gen_random_bytes`, `crypt`, …) resolves
  locally — where `create extension` lands in `public` — and throws 42883 in
  production. It passes migration-time checks too, because the SQL editor's
  own connection *does* have `extensions` on its path; only run time fails.
  This shipped once (0015's `new_cancel_token`) and broke every booking in the
  app. Prefer a `pg_catalog` builtin (`gen_random_uuid()`), or pin the
  function's own `search_path`. Reproduce locally with
  `create schema extensions; create extension pgcrypto with schema extensions;`
  and apply migrations under `PGOPTIONS='-c search_path=public,extensions'`.
- **Never type or read secrets.** Passwords, service_role keys, Twilio tokens —
  the user handles those. Passwords cannot be retrieved, only reset.
- **`revoke ... from public` does NOT lock down a Supabase RPC.** Supabase
  grants `anon`, `authenticated` and `service_role` EXECUTE on new `public`
  functions by default privilege — a grant to those roles directly, which
  revoking PUBLIC leaves alone. Most RPCs here get away with it because they
  gate internally on `auth_guest_id()`/`auth_caterer_id()`; any function
  without such an inner check must
  `revoke ... from public, anon, authenticated` explicitly. The local stub
  replicates those default privileges, so this is testable locally.
- **The Twilio account is on a trial**: it only delivers to numbers verified on
  that account and prefixes every body with its own banner. Anything else comes
  back as a Twilio error, which lands in `round_reminders.error`. WhatsApp
  additionally needs an approved sender and pre-approved templates.
- **The local web server needs restarting after every `flutter build web`.**
  `python3 -m http.server 8765` served from `build/web` starts returning 404
  for *every* path — including files that plainly exist — once a rebuild has
  replaced that directory. Observed repeatedly; the mechanism was not pinned
  down (in one instance the process's cwd inode still matched the live
  directory, so "stale deleted inode" does not fully explain it). Don't spend
  time diagnosing: kill and restart.
- **Start it with the Bash tool's `run_in_background`, not `nohup … &`.** A
  backgrounded shell job is reaped when the tool call's shell exits, so the
  server appears to start, answers one `curl`, and is gone by the next turn —
  while an older stale instance may still hold the port and answer 404s.
- Chrome automation is blocked from `localhost`, so live UI verification means
  asking the user to click and screenshot.
- **Removing an enum value means rebuilding the type**, and Postgres refuses
  while a *view* depends on the column — `host_pending_noshow_bookings` reads
  `seats.status`, so it has to be dropped and recreated around the swap.
- **`ReorderableListView.buildDefaultDragHandles` defaults to `true`** on
  desktop and injects its own handle at each row's trailing edge. Set it
  `false` wherever you supply your own `ReorderableDragStartListener`, or a
  stray `≡` appears mid-card and reads as a rendering glitch.
- `ReorderableListView.onReorder` is deprecated for `onReorderItem`, which
  *pre-adjusts* `newIndex` — drop the usual `if (newIndex > oldIndex) newIndex--`
  when migrating or you introduce an off-by-one.
- **`ListTile.leading` is width-constrained** and will clip two icons placed
  side by side (worse in a select mode that adds a checkbox). Lay such rows out
  directly.
- Naming: `menu_sections` (courses) is deliberately distinct from `sections`
  (floor seating zones), and `menu_items.dietary` is the veg/nonveg tag — it was
  called `type` until `0012`, which read ambiguously once courses existed.

## Repo

`github.com/Gowdaboi/Seat-saver`, public (framed for portfolio/interview
review — see README). Commit only when asked.
