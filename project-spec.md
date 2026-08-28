# Project Spec: Catering Seating & Round Management App

## One-line pitch
A multi-tenant app for caterers/event floor managers running South Indian catered events (weddings, functions) to digitally manage seating, dining rounds, and guest flow — so guests stop hovering near the dining hall waiting for a seat.

## Problem being solved
At Pankti (row/banana-leaf) style catered events, guests physically wait/hover near the dining hall for the next round, sometimes standing behind people already eating to claim their seat next — which is awkward for the eating guest and drives away introverted guests who avoid the confrontation entirely. This app gives guests live visibility into seat availability and round timing so they don't need to physically wait and watch.

## Tech stack
- **Frontend:** Flutter (Dart) — single codebase for Android + iOS
- **Backend/DB:** Supabase (Postgres + Realtime + Auth)
- **Auth:** Supabase Auth for both roles — host via email/password, guest via **phone number OTP (SMS)**; both are real `auth.users` identities, so RLS can use `auth.uid()` uniformly for host and guest policies
- **Multi-tenancy:** enforced via Postgres Row Level Security (RLS), scoped by `caterer_id`
- **QR codes:** generated per seat/round; scanned via in-app camera

## User roles
1. **Caterer / Floor Manager (Host)** — signs up, creates events, designs floor, manages rounds, confirms seating, handles feedback
2. **Guest** — no account needed beyond phone number; books seats, scans QR to confirm, requests help

---

## v1 Scope (build this first)

### Host capabilities
- Sign up / log in (tenant account)
- Create an event (name, venue, date, service type: **Pankti** or **Buffet**)
- Configure reassignment timing for the event: **no-show timeout** (default 5 min) and **accept/reject response window** (default 1 min) — pre-filled with sensible defaults, editable per event
- Design floor: define one or more **sections** (name, type: veg/nonveg/mixed), then number of tables, seats per table (~15 tables × 6 seats typical, but host-configurable) assigned to a section — a section's capacity is derived from its tables' seats, not typed in separately; host is not limited to exactly two zones, and can add/rename/remove sections while designing the hall
- Add menu items (name, veg/non-veg)
- **Pankti service only:** manually start each round (button-triggered, no smart timing in v1)
- **Buffet service:** no rounds — mark a seat "cleaning/available" manually when a guest leaves
- Manually block/assign seats (walk-ins, VIP holds, guests without the app)
- Scan guest's confirmation QR at seat to mark arrival
- **Review and mark no-shows:** once the no-show timeout has passed, bookings with at least one
  unconfirmed seat surface on the host's screen; the host explicitly marks a booking as a no-show
  (nothing releases automatically) — this kicks off the reassignment queue for that group
- View/respond to guest call requests (text or call-flag)
- Create a simple post-meal feedback form (custom questions) per event

### Guest capabilities
- Access via QR code at venue (opens app if installed, else mobile web); verifies identity via **phone number OTP (SMS)** before booking
- View menu, floor layout (only sections the host has configured for the event), current round status, next round estimate — guest selects a section first, and the seat picker is scoped to that section's tables
- Book available seats for upcoming round (party size selectable) — BookMyShow-style seat picker
- Receive a confirmation QR code to show on arrival
- No-show handling: if not scanned within 5 minutes of round start, the booking becomes visible to
  the host as a no-show candidate — the host confirms it, which is what actually releases the group's
  seats into the reassignment queue (not an automatic timeout)
- Post-seating: "Call Host" button → text message or call-request flag
- One booking per guest per event (guest identity is a phone-OTP-verified Supabase Auth account; dedupe is enforced against that verified phone number, not a self-reported one)

### Core business rules (must be handled explicitly)
1. **Group bookings are atomic** — a no-show on a multi-seat booking releases the whole group's seats together, not partially.
2. **No-show reassignment queue** (Pankti rounds only):
   - Seat group unconfirmed **X minutes** (host-configured, default 5) after round start → surfaces to
     the host as a no-show candidate (does **not** auto-release); host explicitly marks it as a
     no-show, which is what triggers the whole freed group being offered atomically (all its seats
     together, not piecemeal) to the next guest in line with **matching party size**
   - Offered guest has **Y minutes** (host-configured, default 1) to accept/reject; auto-rejected if no response
   - On reject/timeout → offer moves to next guest in line (#2 → #3 → #4), still as one atomic group
   - If all in line reject/timeout → the group's seats open up generally (any guest can book)
   - X and Y are set per event by the host at event creation (editable), not hardcoded
3. **QR replay protection** — a scanned QR must match both seat number AND current active round; prevents a guest reusing an old round's QR to claim a seat again.
4. **One booking per guest per event** — dedupe by phone number, enforced against a phone-OTP-verified Supabase Auth identity (not a self-reported, unverified number).
5. **RLS-enforced tenant isolation** — a caterer's queries only ever return their own events/tables/bookings.

---

## Explicitly deferred to v2+ (do not build in v1)
- Geofencing / location-based booking restriction (GPS unreliable indoors — cut entirely for now)
- Email OTP / alternate verification channels for guests (v1 is phone SMS OTP only)
- Smart round timing (auto-estimating based on serving signals like "dessert started")
- Direct in-app calling (v1 is text-request only)
- Self-serve caterer signup/onboarding flow for other businesses (v1 tested against one demo caterer account)
- Rich analytics/reporting on feedback

---

## Rough data model (starting point, not final)

```
caterers        (id, auth_user_id → auth.users, business_name, contact_email)
events          (id, caterer_id → caterers, name, venue_name, date, service_type: 'pankti'|'buffet', no_show_timeout_minutes default 5, reassignment_response_minutes default 1)
sections        (id, event_id → events, name, type: 'veg'|'nonveg'|'mixed', display_order)
tables          (id, event_id → events, section_id → sections, table_number, seat_count)
seats           (id, table_id → tables, seat_number, status: 'available'|'booked'|'occupied'|'blocked'|'cleaning')
menu_items      (id, event_id → events, name, type: 'veg'|'nonveg')
rounds          (id, event_id → events, round_number, status: 'upcoming'|'current'|'completed', started_at)
guests          (id, auth_user_id → auth.users, phone_number, name)
bookings        (id, event_id → events, guest_id → guests, round_id → rounds nullable, party_size, status: 'requested'|'confirmed'|'no_show'|'cancelled', created_at)
booking_seats   (id, booking_id → bookings, seat_id → seats)
reassignment_offers (id, seat_group_id, offered_to_guest_id → guests, queue_position, expires_at, status: 'queued'|'offered'|'accepted'|'rejected'|'expired')
reassignment_offer_seats (id, offer_id → reassignment_offers, seat_id → seats)
call_requests   (id, event_id → events, guest_id → guests, table_id → tables, type: 'text'|'call', message, status)
feedback_forms  (id, event_id → events, questions_json)
feedback_responses (id, form_id → feedback_forms, guest_id → guests, answers_json)
```

Note: a section's seating capacity is not a stored column — it's derived by summing `seat_count`
across the tables assigned to it (`section_id`). This avoids keeping a duplicate figure in sync as
tables are added/removed during floor design.

## Open questions still to resolve
- The **FIFO-by-`created_at`** ordering for who's next in line (among other `requested` bookings of
  matching party size) is still an assumption, not something explicitly confirmed — flagged in the
  "Resolved decisions" below. Low-risk default, but worth a deliberate yes/no at some point.

## Resolved decisions
- **Sections replace fixed veg/nonveg zones:** the host defines one or more named sections while
  designing the floor (not limited to two), assigns tables to a section, and a section's capacity is
  derived from its tables' seats. Guests only ever see sections the host has actually configured for
  the event, pick one, and the seat picker is scoped to that section's tables.
- **Guest auth is phone OTP (SMS) via Supabase Auth, not anonymous/unverified** — both host and guest
  are real `auth.users` identities (host: email/password, guest: phone OTP), so RLS policies for both
  roles can key off `auth.uid()` the same way, and dedupe/QR-replay/no-show rules operate on a
  verified phone number rather than a self-reported one. This supersedes the original "no OTP in v1"
  scope line.
- **Realtime mechanism:** Supabase Realtime `postgres_changes` subscriptions (not Broadcast-from-DB),
  relying on RLS to scope what each connected client actually receives rather than channel-level
  column filters — most tables in this schema (`seats`, `reassignment_offers`, etc.) don't carry
  `event_id` directly, so a `filter: event_id=eq.<id>` isn't available on them anyway. Practically:
  - Floor/menu/round data (`seats`, `rounds`, `menu_items`) is broadly readable by any authenticated
    user per the RLS policies already written, so clients subscribe to those tables and filter
    client-side to the table/seat IDs they already loaded for the event they're viewing.
  - Guest-owned data (`reassignment_offers`, `call_requests`, `bookings`) is RLS-scoped per guest, so
    a guest's subscription naturally only ever receives their own rows — no extra filtering needed.
  - Host dashboards subscribe the same way; RLS scopes them to their own caterer's rows.
  - **v1 tradeoff, noted for v2:** because `postgres_changes` evaluates RLS per subscriber and per
    change, this is fine at "single demo caterer, a handful of concurrent events" scale but doesn't
    scale cleanly to many simultaneous tenants/events. If that becomes real, switch to
    Supabase's "Broadcast from Database" pattern (DB triggers calling `realtime.broadcast_changes()`
    into an `event:{event_id}` topic) — which would need `event_id` denormalized onto `seats` and
    `reassignment_offers` for the trigger to target the right topic. Deliberately not doing that
    up front since it's schema complexity v1 doesn't need yet.
- **Accept/reject countdown UI flow:** driven by a Realtime subscription on `reassignment_offers`
  filtered to the guest's own rows (via RLS). When a row flips to `offered`, the guest sees a
  prominent banner/screen with the seat-group details, a countdown ring computed from `expires_at`,
  and Accept/Decline buttons. The client-side countdown is **cosmetic only** — the authoritative
  expiry is enforced server-side (see `0003_reassignment_engine.sql`: `expire_reassignment_offers()`
  runs on a 15-second `pg_cron` schedule and flips anything past `expires_at`), so a guest closing the
  app or losing connection doesn't stall the queue. Accept calls the `accept_reassignment_offer(offer_id)`
  RPC, decline calls `reject_reassignment_offer(offer_id)`; both are security-definer Postgres
  functions so they can validate ownership, then cascade to the next candidate in line or reopen the
  seats, atomically, without needing extra client-side coordination.
- **Reassignment offers are atomic per seat-group, not per seat** — a no-show releases a group's seats
  together (rule #1), and "matching party size" (rule #2) implies the group is re-offered as one unit.
  Modeled as `reassignment_offers` (one row per candidate-in-line, covering the whole freed group) +
  `reassignment_offer_seats` (which seats that offer covers) — mirroring the existing
  `bookings`/`booking_seats` split rather than the single per-seat `reassignment_queue` table originally
  sketched.
- **No-show detection is host-mediated, not automatic.** The X-minute timeout doesn't silently release
  seats — it's the threshold past which a booking with at least one unconfirmed seat becomes visible
  to the host (via the `host_pending_noshow_bookings` view) as a no-show candidate. The host explicitly
  marks it (`mark_booking_no_show(booking_id)`), and only that action releases the group — atomically,
  per rule #1, even if some of the group's seats were individually scanned in. This resolves the
  partial-arrival ambiguity flagged earlier: the host's judgment is the tiebreaker, not an inferred
  rule. `mark_booking_no_show()` also builds the reassignment queue at that moment — a FIFO (by
  `created_at`) scan of other `requested` bookings for the same event with matching `party_size` —
  and kicks off the first offer, or opens the seats immediately if nobody's waiting.
- **Guest entry is exclusively via a host-generated, per-event QR code** — the host has an "Event QR
  code" screen (any event, picked the same way as floor design/menu) showing a QR that encodes a deep
  link straight to `/e/:eventId`. Every guest-side screen after that carries `eventId` (and, where
  relevant, `sectionId`/`bookingId`) through the route, so the whole guest flow is always scoped to one
  specific event — there is no generic "browse events" guest experience, matching how the app is
  actually used (one QR per event, scanned at the venue). The role-picker screen guests used to share
  with hosts was removed; it's host-only now, with a one-line note telling guests to scan the QR.
  The QR encodes `${Uri.base.origin}/#/e/:eventId` — the app's own current origin, not a hardcoded URL,
  so this keeps working wherever the app ends up hosted without a config value to keep in sync.
- **Public event info before login, without opening up anonymous browsing:** the QR-landing page shows
  the real event name/venue before the guest has verified their phone, which needs *some* anonymous
  read access. Rather than grant the `anon` role broad `SELECT` on `events` (which would let anyone
  enumerate every tenant's event names/dates, not just the one they scanned), added a narrow
  `get_public_event_info(event_id)` RPC — security definer, returns only display fields for one
  caller-specified event, no way to browse. See `0005_guest_booking.sql`.
- **Seat booking is an atomic, security-definer RPC (`book_seats`)**, not a client-side insert —
  guests have no RLS write access to `seats` (only hosts do), and a booking has to succeed or fail as
  a whole: lock the requested seats, confirm they're all still `available`, then create the booking +
  `booking_seats` + flip seat status together. Two guests racing for the same seat: the second one's
  call fails cleanly with "one or more selected seats are no longer available" rather than partially
  succeeding. `party_size` must exactly match the number of seat ids passed — enforced before touching
  the database.
- **A booking gets its `round_id` when the host starts a round, not when the guest books.** Guests book
  seats ahead of the round actually happening — round_id can't be known at booking time since Pankti
  rounds are started later, on the host's button press. So `mark_booking_no_show`'s host-review flow
  and the no-show timeout it depends on (`host_pending_noshow_bookings`, joined through
  `rounds.started_at`) would never see a booking that has no round attached. Resolved by having
  "Start round N" also sweep: every `confirmed` booking for that event with `round_id is null` gets
  set to the new round. This is a genuine design decision, not something the original spec called out
  explicitly — reasonable interpretation (starting a round means "everyone waiting is being seated
  now"), but worth a deliberate confirmation if the real-world flow turns out to need staggered/partial
  round assignment instead of an all-at-once sweep.
- **QR replay protection (rule #3) is enforced live, not by what's encoded in the QR.** A guest gets
  one QR at booking time, encoding only `booking_id` — deliberately not `seat_ids` or `round_id`,
  because `round_id` isn't set on the booking until the host starts a round (see the sweep decision
  above), which happens after the QR is already generated. Baking round_id in would make every Pankti
  guest's QR permanently stale. Instead, `check_in_booking(booking_id)` looks up the booking's current
  round_id fresh on every scan and compares it against whichever round is presently `status = 'current'`
  for that event — so the same QR keeps working correctly as rounds change, but a QR from a round that's
  already `completed` correctly stops working (the actual replay-protection behavior rule #3 asks for).
  Buffet events have no rounds, so this check is skipped entirely for them; scanning marks seats
  `occupied` directly. Confirmed with the host: one persistent QR per booking, checked live — not a
  new QR reissued each round. See `0006_seat_checkin.sql`.
- **Seats track who currently holds them (`seats.current_booking_id`), independent of the round check.**
  Buffet has no rounds to check against, but Buffet seats *do* get reused repeatedly within one event —
  guest eats, leaves, host cycles the seat `cleaning` → `available`, a new guest books it. A guest's
  original QR still points at the same seat_id forever via `booking_seats`; without this, replaying an
  old Buffet QR after the seat had genuinely moved on to someone else would still "succeed." Now
  `book_seats()` and `accept_reassignment_offer()` — the only two paths that hand a seat to a booking —
  record themselves as the current claimant, and `check_in_booking()` requires every seat in the scanned
  booking to still be *the current claim*, for both service types. This also forced a rewrite of the
  original `prevent_double_seat_booking` trigger (0001_init.sql): it checked booking *status* history
  ("is any other requested/confirmed booking still attached to this seat"), which doesn't work for
  Buffet since a booking never transitions away from `confirmed` even after the guest leaves — the old
  trigger would have permanently blocked ever reassigning a freed Buffet seat to a new guest. It now
  checks the seat's own current state instead.
- **Bug found and fixed in the same pass: `accept_reassignment_offer()` never set the accepting
  booking's `round_id`.** A guest who successfully accepted a reassignment offer would have had their
  confirmation QR permanently rejected at check-in (no round to match against). Now sets it to
  whichever round is currently active for that event at acceptance time. See `0007_seat_ownership_tracking.sql`
  for both fixes.
- **Manual seat block/assign (walk-ins, VIP holds, guests without the app) needed `guests` to allow
  identities with no Supabase Auth account at all.** `guests.auth_user_id` and `phone_number` were both
  `NOT NULL` — correct for the phone-OTP-verified guest flow, but a walk-in by definition has no app
  account, and the host may not even have their phone number. Both columns are now nullable. Assigning
  seats goes through a new `host_assign_seats()` RPC (mirrors `book_seats()`, but host-driven): if a
  phone number is given and already belongs to an existing guest, it links to that guest instead of
  creating a duplicate (so a VIP who happens to already have the app doesn't end up with two guest
  records); otherwise it creates a fresh walk-in guest with no auth identity. A "seat them now" toggle
  controls whether the seat goes straight to `occupied` (walk-in being seated on the spot) or `booked`
  (a hold for someone arriving later, with no QR to scan them in — the host marks it occupied manually
  from the same screen). See `0008_host_seat_assignment.sql`.
- **Floor layout is host-configured as a whole section, not built table-by-table.** The host states a
  table count, seats per table, row count, and orientation for a section; `configure_section_layout()`
  calculates a grid (`grid_row`, `grid_col` per table) and generates every table and seat in one atomic
  RPC call, replacing whatever was in the section before. Geometry is a coarse grid, not free x/y pixels
  — hosts are describing a seating plan, not drawing to scale, and a grid is what both the host's editor
  and the guest's seat picker can render identically from the same widget
  (`lib/features/shared/widgets/floor_layout.dart`), so the arrangement the host lands on is exactly what
  the guest sees while booking. Regenerating a section is refused if any of its seats are currently in
  use or have ever been booked (`booking_seats` history exists) — silently dropping and recreating tables
  would either yank a seat out from under someone seated right now, or erase the record of who sat where
  for the past-events recap; the host has to delete the section and start over instead, which is a
  visible, deliberate action. A separate `reflow_section_layout()` RPC recomputes grid positions alone
  (for "same tables, fewer rows") and has no such guard, since it never touches a table, seat, or booking
  — only where the table sits on screen. See `0009_floor_layout_geometry.sql`.
- **Tables can seat one side only, not just both.** A table by default has guests on its near and far
  side (a banana-leaf row read from the middle out); a table against a wall or stage needs every seat on
  one side instead. `seating_side` (`both` / `near` / `far`) exists both as a section-wide default set
  when building the layout and as a per-table override the host can flip afterward without touching
  anyone else's table — the same two-tier pattern already used for orientation. Near/far rather than an
  explicit side name because the meaning is already orientation-relative in the renderer (near is the top
  for a horizontal table, left for a vertical one); the UI translates that into "Top only"/"Left only" etc.
  based on the table's actual orientation so the host never has to think in near/far terms directly.
  Seat count is unaffected either way — a one-sided table just gets all of its seats on that one side
  instead of splitting them. See `0010_seating_side.sql`.
- **Releasing a seat must clear its ownership, not just its status — found by testing the manual
  seat-assignment flow.** The host seat screen changed `seats.status` directly and left
  `current_booking_id` pointing at the departed guest's booking. That column is exactly what
  `check_in_booking()` tests to decide whether a scanned QR still legitimately holds the seat
  (`0007`), and the test is "does the seat's current_booking_id still match *this* booking" — which
  a stale value passes. Reproduced end-to-end on a Buffet event (no round check to catch it): guest
  checks in, host clears the seat back to `available`, and the guest's **original** QR scans
  successfully and retakes the seat. Freeing a seat now nulls `current_booking_id` in the same
  update, and the same replay is correctly rejected. Same class of bug as the original Buffet
  double-booking trigger: seat state, not booking history, is the source of truth, so every path
  that frees a seat has to reset *all* of that state.
- **Seat availability is per-round for Pankti — which reverses the round-start "sweep" decision
  above.** A seat had one global status, so seat 5 could not be free for round 2 while taken for
  round 1 — the very thing multi-round service is. Bookings therefore had no round until the host
  *started* one, and the sweep existed to attach them late. Now a booking picks its round at the
  moment it is made, and availability is derived from `booking_seats` joined to `bookings.round_id`:
  "seat X is taken for round R if an active booking for round R holds it." No new table was needed —
  those two already said it. The sweep is gone, replaced by `start_round()`, which releases the
  finished sitting's seats and *materialises* the new round's reservations onto the physical seats,
  so a held seat reads as `booked` on the live board exactly while that sitting is being served.
  `seats.status` now means only what is physically true right now. Buffet keeps the status-based rule
  it always had, since its seats are reused within one sitting rather than across several. See
  `0014_round_scoped_booking.sql`.
- **A full round opens the next one rather than refusing the booking.** `ensure_bookable_round()`
  returns the earliest round with room and creates the next sitting when every planned one is full,
  so "there is no space tonight" is never something a guest is told while the caterer would happily
  serve another sitting. Concurrency is settled by `unique (event_id, round_number)`: if two guests
  race to open the same round, the loser adopts the winner's round instead of failing.
- **`blocked` was removed from `seat_status`.** Taking a seat out of service permanently — a broken
  chair, a seat behind a pillar — is a fact about the floor plan, not a live service state the host
  toggles mid-shift, so it belongs in Design floor (delete the seat) rather than on the ops screens.
  Removing it also makes the four remaining statuses exhaustive, so the board's Total genuinely
  equals Occupied + Booked + Available + Cleaning.
- **Assigning a seat on a guest's behalf no longer has a "seat them now" toggle.** Assigning makes a
  booking; whether the guest is physically sitting down is what check-in decides. Letting a host set
  both independently let the two drift out of step for no benefit.
- **The seat board is shown for Pankti as well as Buffet.** The rounds screen originally rendered
  seats only for Buffet events; Pankti hosts saw a bare list of rounds. But Pankti is precisely when
  seats turn over — a round ends, the whole hall is cleared and reset for the next sitting — so the
  board is at least as useful there. Pankti keeps its round controls above the board rather than
  instead of it.
- **Guests carry an `is_vip` flag; dietary preference is deliberately not stored per guest.** VIP
  holds were already a real workflow (`host_assign_seats` exists partly to place them) but "VIP" only
  ever lived in the guest's name or the host's memory, so the seat board had nothing to show. A
  dietary column was considered alongside it and rejected: a guest's dietary choice is expressed by
  what they're served, and `menu_items.dietary` already records veg/nonveg per dish — storing it per
  guest too would be a second source of truth with nothing keeping the two in agreement. See
  `0013_guest_vip.sql`.
- **Vacating a seat frees the seat but keeps the booking.** "The guest has left" is not "the booking
  never happened": the booking is what the past-event recap counts, so it stays `confirmed` and only
  the seat is released. Releasing goes through the same patch as any other return to `available`, so
  it clears `current_booking_id` too and the departed guest's QR cannot retake the seat.
- **`occupied` needed a way out of it.** The same screen offered no action on an occupied seat, so
  the Buffet reuse cycle the `0007` trigger rewrite exists to permit (guest eats and leaves → host
  clears the seat → someone else books it) was unreachable from the app: the capability was in the
  database but had no UI. Tapping an occupied seat now moves it to `cleaning`, which already had a
  path back to `available`.
- **A round reminder needs a *planned* start time, so rounds gained one.** Rounds only ever had
  `started_at`, stamped when the host presses Start — there was nothing to be "five minutes before".
  `rounds.scheduled_start_at` is that plan, and it is nullable on purpose: a round nobody has
  scheduled sends no reminders, which is honest, where inferring a time from the previous round's
  length would quietly message people at the wrong moment. The window is also strictly *before* the
  round — once the scheduled time has passed, "starts in 5 minutes" is false, so a missed window
  stays missed rather than firing late. See `0015_round_reminders.sql`.
- **Reminders are a queue table, not a fire-and-forget call.** `round_reminders` is unique per
  `(booking_id, round_id)`, which is the entire guard against a retried cron run messaging a guest
  twice, and it keeps its state (`pending → sending → sent | failed | skipped`) so a send that
  Twilio refused is visible to the host afterwards instead of disappearing into a function log.
  `sending` is a claim marker: it is what stops two overlapping runs handing the same row to Twilio.
- **The database decides *who* is due; the edge function decides *what the message says*.**
  Splitting it there is what keeps every Twilio credential out of the migration —
  `enqueue_due_round_reminders()` runs on a plain SQL cron and talks to nothing external, so the
  queue keeps filling correctly even when the sender is undeployed or down. The wording and the
  cancel URL depend on deployment, not on the domain model, so they live with the sender.
- **The cancel link authorises with a per-booking token, not a session.** A guest reading an SMS may
  be on a phone that never signed in, and making them log in first means the seat stays held by
  whoever gave up halfway. `bookings.cancel_token` is 24 random bytes as base64url; holding it proves
  nothing about who you are, only that this booking's own message reached you, and the two anon RPCs
  behind it can reach exactly that one booking. An unknown token returns "not valid" with no way to
  tell a wrong guess from an expired link.
- **Cancelling releases only the seats the booking *physically* holds** — the ones where
  `seats.current_booking_id` is this booking. For a booking in a future sitting that is none of them:
  those seats belong to whoever is being served right now, and per-round availability frees them the
  moment the booking flips to `cancelled`. Freeing every row in `booking_seats` instead would have
  thrown the current sitting out of their chairs, which is what the local test in
  `test_round_reminders.sql` step 12 exists to catch.
- **Cancelling is refused once the guest is seated, and is idempotent otherwise.** An `occupied`
  seat, a completed round, or an existing no-show all return `too_late`; a second tap on the link
  returns `already_cancelled`. Outcomes are returned as codes rather than raised as errors so the
  public page can render a calm sentence for each case instead of parsing a Postgres message.
- **`revoke ... from public` is not enough to lock down a Supabase RPC.** Supabase grants `anon`,
  `authenticated` and `service_role` EXECUTE on new `public` functions by *default privilege*, which
  is a grant to those roles directly — revoking PUBLIC's grant leaves it untouched. The older RPCs
  survive that because they gate internally on `auth_guest_id()`/`auth_caterer_id()` and an anon
  caller fails the check; the reminder-queue functions have no such inner guard, so the grant *is*
  the guard and has to name the roles. Caught by local testing, where `anon` successfully drained
  the queue — which would have leaked every due guest's phone number and cancel token.
- **Event names are unique per caterer, compared case- and whitespace-insensitively.** Pickers show
  the event name, so a host with two events called "Marriage" had no way to tell which was which —
  and choosing wrong means designing a floor, starting a round or assigning a seat on the wrong
  night. Scoped to the caterer rather than globally: two different caterers both running a
  "Reception" is normal and none of each other's business. Existing duplicates are *renamed*
  (`Marriage (2)`) rather than deleted, because an event owns floor layout, menu and bookings that
  must not be destroyed to satisfy a constraint. The picker still shows date and venue alongside the
  name, since a unique name is not the same as a recognisable one. See `0016_…`.
- **The cancel token stopped using pgcrypto.** `gen_random_bytes()` needs the pgcrypto extension,
  which Supabase installs into an `extensions` schema while every security-definer function here
  pins `search_path = public`. The migration applied cleanly — the SQL editor's connection *does*
  see `extensions` — and then failed at run time on every single booking, guest and host alike,
  because the column default is evaluated inside those functions. Replaced with `gen_random_uuid()`,
  which is core Postgres in `pg_catalog` and therefore resolves under any search_path at all. The
  lesson generalises: prefer a builtin over an extension for anything a definer function touches.
- **The host can plan a round without starting it.** Previously "Start round N" was the only way to
  create a round, and it made that round `current` immediately — so an `upcoming` round existed only
  when guest bookings happened to overflow into one. That made round scheduling, and therefore
  reminders, unreachable for a host setting up in advance. "Plan a round" creates the next sitting
  as `upcoming` and goes straight into the time picker, because a planned round with no time does
  nothing.
- **A signed-in host stays signed in across a page reload.** The session was always persisted;
  nothing routed it anywhere, so every refresh landed on the role picker and read as a forced
  logout. The router now redirects an existing *host* session away from `/` and `/host/login` only.
  Host and guest are both real auth users, so they are told apart by the presence of an email —
  hosts sign in with email/password, guests with phone OTP — which is the only discriminator
  available to a redirect callback, since it has to answer synchronously. Every other route is left
  alone, including the guest flow, password recovery, and the `/c/:token` cancel link that is
  deliberately reachable signed out.
- **Reservations are shown on their own visual axis, not as a fifth seat status.** Per-round
  availability (0014) means a Pankti booking for an upcoming sitting holds no physical seat, so
  after assigning seats a host saw the grid unchanged and every counter still reading zero — which
  looks exactly like a failed save and invites double-booking a seat believed to be free. The
  temptation is to mark the seat `booked` at assignment time; that is precisely the single-sitting
  model 0014 removed, and it would make the seat unbookable for every other round. Instead the UI
  now reads `bookings` + `booking_seats` and renders reservations *alongside* physical state: an
  indigo outline and an `R2` badge on the seat grid, seat counts on the round chips, and a sentence
  under the counters saying the numbers describe the hall right now. The seat stays selectable,
  because the same seat legitimately belongs to different guests in different rounds.
- **Raw `PostgrestException` text never reaches a user.** A repeat booking put the constraint name,
  the key tuple and two uuids straight into a snackbar. `friendlyError()` translates the constraint
  violations the app can actually provoke and passes through the messages our own RPCs raise, which
  were written for people to read in the first place. Anything unrecognised falls back to a caller-
  supplied sentence rather than to `toString()`.
- **The host is told which round an assignment landed in.** `host_assign_seats` chooses the round
  itself — earliest with room, opening a new sitting when the planned ones are full — so without
  saying so afterwards the host has no way to learn where their guest ended up.
- **A seat booked into the round already running is held immediately.** 0014 correctly stopped
  Pankti bookings from touching `seats.status`, because a booking for a *future* sitting occupies
  nothing — `start_round()` materialises that round's holds when it begins. But it materialises
  once, at the moment it runs, and nothing materialised a booking made afterwards. That is not an
  edge case: it is the ordinary path for host assignment, which exists to seat walk-ins during
  service. Such a seat stayed `available` for the rest of the event, invisible on the grid,
  uncounted by every metric, and offerable to a second guest. `book_seats` and `host_assign_seats`
  now claim the seat when its round is `current`, guarded on `status = 'available'` so a seat still
  occupied or mid-clean from the previous sitting is never overwritten. Future rounds are untouched,
  so per-round availability is unchanged. See `0017_…`.
- **Whether to badge a seat as reserved is decided by its hold, not by its round's status.** The
  first version of the marker asked "is this round upcoming?", which hid precisely the case above —
  a booking into the running round, which has no hold and no badge, so nothing on any screen showed
  it. Comparing `seats.current_booking_id` against the booking is self-correcting: if the seat is
  already holding this booking its colour tells the story, and if it is not, the badge does.
- **Events are visible only to their caterer and to guests holding a booking.** `events_select_all
  ... using (true)` let any signed-in account — and anyone can create one, a guest needs only a
  phone OTP — list every caterer's event names, venues and dates: the customer list of every
  business on the platform. Survivable on localhost, not once the app had a public URL. Nothing on
  the guest side reads `events` directly, so scoping it breaks no flow: the QR landing page uses
  `get_public_event_info()`, a definer RPC that returns one caller-named event and cannot browse,
  and the floor/menu screens read `sections`, `menu_items` and `rounds`. The guest-side check goes
  through a `security definer` helper because `bookings`' own policy already reads `events`, and two
  RLS tables querying each other raise "infinite recursion detected in policy" — the same trap
  `offer_belongs_to_caterer` was built for. See `0018_…`.
- **A queued reminder whose moment has passed is retired, not sent.** 0015 guarded the *insert*
  against past rounds and assumed a missed window therefore stayed missed. It only guarded the
  insert: a row queued at T-5min sits `pending` until something claims it, so while the sender was
  returning 403 a day-old reminder sat primed to fire the instant it was fixed. The same
  "strictly before the round" rule now governs the queue, not just entry to it. See `0019_…`.
- **Reminders are sent as provider-registered templates, not composed text.** Both channels refused
  free text for the same underlying reason: a message sent five minutes before a round is
  business-initiated — the guest has not messaged us — and neither carrier network permits that
  without pre-approval. India's TRAI/DLT rules require a registered template and sender ID for
  commercial SMS; Meta requires an approved template for business-initiated WhatsApp, and reopening
  a fresh 24-hour session did not change it. `events.reminder_content_sid` carries the template id
  and the sender supplies five positional variables ({{1}} guest, {{2}} round, {{3}} event,
  {{4}} minutes, {{5}} cancel URL) — fixed and documented so a template approved months earlier
  keeps working. Free text is kept as the fallback when no template is set, since it is still valid
  outside those regimes and for local testing. See `0020_…`.
- **A retired reminder no longer blocks its round forever.** The unique `(booking_id, round_id)`
  guard is what stops a retried cron run double-messaging, but `on conflict do nothing` meant a
  `skipped` or `failed` row kept the slot — so a host who rescheduled a round silently never
  re-reminded anyone already queued for it. Those two states are now revived to `pending` instead.
  Safe because the insert's own conditions must pass again first: an active booking, an upcoming
  round, a start time still ahead. A row already `pending`, `sending` or `sent` is never touched,
  so the double-send guard is intact.
- **Reminder settings are editable by the host, from the Rounds screen.** Channel, lead time and
  message template id existed only as columns; changing any of them needed database access, which
  put the feature out of reach of the people it exists for. They now sit behind a Reminder settings
  dialog on the screen where the host already reads "guests are messaged N minutes before". The
  screen also warns, in red, when no template is set — because without one the provider refuses the
  send outright and the only trace is an error on a queue row the host never sees.
- **A host can place a walk-in in a specific sitting.** `host_assign_seats` always chose the
  earliest round with room, which is the right default but made "seat this family in the second
  sitting" inexpressible — during testing the only way to move a booking between rounds was SQL.
  The assign dialog now offers "Next with room" (unchanged behaviour) or any open round.
- **`host_assign_seats` now checks the round belongs to the event.** `book_seats` always did;
  its host counterpart never had, because nothing passed a round id — the UI let the RPC choose.
  Adding the round picker made the parameter reachable, and a deliberately foreign round id was
  accepted, producing a booking on one event pointing at another event's round and skewing every
  per-round count that joins the two. Existing damage is detached (round set null) rather than
  deleted, since the booking and its seats are real and only the pointer was wrong. See `0021_…`.
- **The remaining tenant-wide reads are closed.** `sections`, `tables`, `seats`, `menu_items`,
  `menu_sections`, `rounds` and `feedback_forms` were all `using (true)`: a plain `GET /menu_items`
  returned every caterer's menu, `GET /tables` every floor plan — no event id required, so
  unguessable uuids were no protection. The obstacle was that a guest who has scanned a QR but not
  yet booked has no row tying them to the event and must still see the floor and menu. Solved the
  way `get_public_event_info` already solved it: `public_event_menu`, `public_event_sections` and
  `public_round_number` are security-definer functions taking one event id, so naming the event you
  were given is the access rule and cannot be used to browse. Section capacity is summed inside the
  RPC, which also removes the guest's last reason to read `tables` at all. See `0022_…`.
- **Emailed links are derived from the running deployment, not from a fixed setting.** Reported as
  issue #1: confirmation emails linked to `http://localhost:8765`, a machine no one but the
  developer has. `signUp()` passed no `emailRedirectTo`, so Supabase fell back to the project's
  single Site URL — one value, which cannot be right for both a local build and a hosted one. The
  same class of bug sat unreported in password recovery, which used `Uri.base.origin`: scheme and
  host only, dropping the `/Seat-saver/` base path so the link 404'd on GitHub Pages. Both now build
  from the current page's origin *and* path, so each deployment mails links back to itself. Supabase
  still validates these against its Redirect URLs allow-list, so a new deployment origin has to be
  added there before its links work.
- **A rejected auth link explains itself.** The reported symptom was a link that "goes nowhere": an
  expired confirmation drops the person on the app root with the reason buried in query and
  fragment parameters, and the landing page rendered as if nothing had happened. It now shows the
  provider's own wording — "Email link is invalid or has expired" — with the next step underneath,
  since the reason alone doesn't tell anyone what to do. The URL-parsing is a pure function taking a
  `Uri` so it can be tested against the exact link from the report, including that a `/#/c/<token>`
  cancel link is never mistaken for an error.
- **The reminder channel picker was there, but nobody could find it.** SMS vs WhatsApp, lead time
  and template id have been editable since the Reminder settings dialog was added — behind an
  unlabelled bell icon on the Rounds card, which was reported as a missing feature by someone
  looking straight at it. Now a labelled "Reminders" button. Worth remembering as a general point:
  an icon-only control in a busy card is, in practice, an absent one.
- **A confirmation email can be resent.** Confirmation links are single-use and expire, and the
  first one may simply never arrive — spam, a mistyped address, or a mail scanner that follows
  links before the person sees them. The only recovery was signing up again with the same address,
  which the app answers with "an account with this email already exists": a dead end. The resend
  appears in the two places the problem is actually noticed — on the "check your email" panel right
  after signing up, while the address is still on screen and known to be right, and on the login
  screen when sign-in is refused specifically for an unconfirmed address. That refusal is now told
  apart from a wrong password, because the generic wording actively misleads there: the credentials
  are correct. A sixty-second cooldown follows a successful send, since Supabase's built-in mailer
  allows only a couple of emails an hour and rejects rather than queues the rest — without it,
  someone clicking twice burns the allowance on sends that were never going to happen.
- **The host login form is discoverable by password managers.** Requested as HTML attributes —
  `type`, `name`, `autocomplete`, a `<form>` with `onSubmit` — which this app has no direct way to
  set, because Flutter draws to a canvas and there is no hand-written markup. The equivalent is
  `AutofillGroup` plus `autofillHints` on each field: Flutter then emits a real `<form>` containing
  a hidden input per field, carrying the `autocomplete` attribute a manager looks for. Verified in
  the browser rather than assumed — the DOM now holds `autocomplete="username"` and
  `autocomplete="current-password"` inside one form with a submit input. The email field renders as
  `type="text"` rather than `type="email"`, which is how Flutter maps a username field; the email
  keyboard and validation that `type="email"` would have provided come from `keyboardType` and the
  validator instead. `TextInput.finishAutofillContext()` fires on a successful sign-in, which is
  what makes a manager *offer to save* rather than merely fill — without it the credentials are
  fillable but never savable. Enter now submits too, via `onFieldSubmitted`.
- **Signup declares `newPassword`, not `password`.** The same autofill treatment as the login form,
  with one deliberate difference: the signup field is marked `AutofillHints.newPassword`, which is
  what makes a manager offer to *generate* a password. Marking it `password` would instead invite it
  to fill an existing credential into a field creating a new account. Business name is
  `organizationName`, so the DOM form carries `organization`, `username` and `new-password`.
  `finishAutofillContext()` fires only after an account was actually created — deliberately after
  the already-registered check, since that path creates nothing and prompting to save there would
  offer to overwrite a working entry with a password that does not open it.
- **Events can be archived, never deleted.** A caterer running two functions a week accumulates a
  hundred a year, and every one stayed in the picker at the top of Design floor, Menu, Rounds and
  Manage seats — ordered by date, so last winter's wedding sits between this week's two, and picking
  wrong means working on the wrong night. "Mark as inactive" removes an event from every picker
  while preserving it completely: the floor, menu, bookings and past-event recap are all still
  there, and restoring is one tap. Deletion was never an option — an event is the root of a cascade
  that would take its sections, tables, seats and booking history with it. Stored as
  `events.archived_at` rather than a boolean, because "when did this get archived" is the question
  actually asked when something turns up in the archive unexpectedly. See `0023_…`.
- **An event being served cannot be archived.** Archiving removes it from every dropdown — including
  the one the host reaches the Rounds screen through — so doing it mid-service strands them. A
  database trigger refuses while any round is `current`; the menu item is disabled and says why, but
  the rule lives in the database because a client check is a courtesy, not a guarantee.
  Un-archiving is never blocked, since the recovery path must always be open.
- **The Inactive tab ignores the date filter the Past tab applies.** Archiving is allowed on any
  event, so if that view listed only archived *past* events, archiving an upcoming one would strand
  it — gone from every picker, and absent from the only screen that could bring it back.
- **Archiving blocks new commitments; it never blocks completions or releases.** 0023 hid archived
  events from the host's pickers but left every guest path open — an old QR still reached the
  landing page, the floor and the seat picker, and still produced a booking. Now booking is refused,
  while cancelling a booking, checking in at the door, and the no-show/reassignment machinery keep
  working: someone who already holds a seat must never be trapped by an administrative action taken
  after they booked, and a cancellation frees a seat, which stays worth allowing for as long as the
  booking exists. Enforced by an INSERT-only trigger on `bookings` rather than a condition inside
  `book_seats` and `host_assign_seats` — two long functions that would both need editing, and any
  third booking path added later would silently miss the rule. INSERT-only is what makes the trigger
  express exactly "no new commitments". See `0024_…`.
- **A finished event says so, rather than looking like a broken QR code.** Returning no rows from
  `get_public_event_info` would leave the landing page on "This QR code doesn't match a known
  event", which reads as a faulty code and sends guests to find staff about something working
  perfectly. It returns `is_archived` instead, and the page says the event has ended.
