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
| `book_seats` | guest books seats atomically |
| `host_assign_seats` | host seats a walk-in/VIP (guest may have no auth account) |
| `check_in_booking` | QR scan → seats occupied |
| `configure_section_layout` | build a grid of two-sided tables |
| `configure_hall_rows` | build rows of one-sided seats (aisle pattern) |
| `reflow_section_layout` | move tables between grid rows, touching nothing else |
| `mark_booking_no_show`, `accept_/reject_/expire_reassignment_offer`, `advance_reassignment_group`, `get_public_event_info` | rounds + reassignment engine |

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
- **Never type or read secrets.** Passwords, service_role keys, Twilio tokens —
  the user handles those. Passwords cannot be retrieved, only reset.
- The local web server (`python3 -m http.server 8765` in `build/web`) does not
  survive a reboot; restart it if localhost stops responding.
- Chrome automation is blocked from `localhost`, so live UI verification means
  asking the user to click and screenshot.

## Repo

`github.com/Gowdaboi/Seat-saver`, public (framed for portfolio/interview
review — see README). Commit only when asked.
