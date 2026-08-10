# Catering Seating & Round Management

A multi-tenant app for caterers running South Indian **Pankti** (row/banana-leaf) and buffet-style events — weddings, functions — to manage seating, dining rounds, and guest flow digitally.

**The problem:** at Pankti-style events, guests physically hover near the dining hall waiting for the next round, sometimes standing behind people who are still eating to claim their seat next. It's awkward for the diner, and it quietly drives away introverted guests who'd rather skip the meal than stand in that line. This app gives guests live visibility into seat availability and round timing so they don't have to wait and watch.

**Who it's for:**
- **Host** (caterer / floor manager) — creates events, designs the floor, manages menu and rounds, reviews no-shows, scans guests in
- **Guest** — no account beyond a phone number; scans a QR at the venue, books a seat, gets a confirmation QR, requests help if needed

Full requirements, data model, and a running log of every non-obvious product decision (with the reasoning behind it) live in **[project-spec.md](./project-spec.md)**.

---

## A few decisions worth reading, if you're evaluating this as product/technical work

The interesting part of this project isn't the CRUD — it's the handful of places where the rules genuinely conflicted, or where a "reasonable-sounding" design turned out to have a real bug once traced through. A sample, each with the full reasoning in `project-spec.md`:

- **Sections, not a fixed veg/nonveg binary.** The original idea was two zones. It became host-defined sections (any number, any name), because caterers don't actually run exactly two zones — and capacity is *derived* from the tables assigned to a section rather than typed in separately, so there's no number that can drift out of sync with reality.
- **A no-show doesn't release seats automatically.** The X-minute timer is a threshold that surfaces a booking to the host as a candidate — the host explicitly confirms it. This resolved a real ambiguity: what happens when 3 of 4 people in a party arrive and 1 doesn't? The host's judgment is the tiebreaker, not an inferred rule.
- **Reassignment offers had to become atomic per seat-*group*, not per seat**, after tracing through what "group bookings are atomic" (no partial no-shows) actually implies once a freed table gets re-offered to the next party in line. Offering 4 seats to 4 unrelated singles instead of 1 party of 4 would have technically satisfied the original schema while violating the actual intent.
- **A guest's QR code deliberately does not encode which round it's for.** It only encodes a booking ID. Baking the round in seemed simpler at first, but a booking doesn't get assigned to a round until the host actually starts one — well after the QR was generated — so the "obvious" version would have shipped broken. Round-matching is instead checked live, server-side, on every scan.
- **Found via testing, not requirements: buffet seat reuse could be replayed.** Buffet seats get reused many times across one event as guests come and go. The original "no double-booking" trigger checked booking *status* history, which works for Pankti but silently breaks buffet — a booking never stops being "confirmed" after a guest leaves, so the old logic would have permanently blocked ever reassigning a freed seat. Fixed by having every seat track who currently holds it, independent of round logic.

---

## Tech stack

- **Frontend:** Flutter (Dart), single codebase for web/iOS/Android
- **Backend:** Supabase — Postgres, Row Level Security for multi-tenant isolation, Realtime, `pg_cron` for scheduled offer expiry
- **Auth:** Supabase Auth — email/password for hosts, phone OTP (Twilio) for guests
- **QR:** generated per booking, scanned via in-app camera for both event entry and arrival check-in

## Current state

**Host side** is fully wired to live data: auth, event creation, floor design, menu, Pankti rounds / buffet seat cycling, no-show review, feedback forms, live call-request inbox (Realtime), QR generation, arrival scanning, and a past-events recap.

**Guest side** is fully wired: QR-scoped entry, phone OTP, live menu/floor, seat picker with atomic booking (race-safe — two guests can't win the same seat), real confirmation QR, no-show reassignment offers (Realtime countdown), call-host.

Every RPC and RLS policy was verified against a real Postgres instance — including deliberately adversarial cases (a different tenant trying to read another caterer's bookings, two guests racing for one seat, an expired-round QR being replayed) — before being applied to the live Supabase project.

**Not yet built:** production SMS (currently on a Twilio trial, capped to verified numbers), and a public deployment.

## Running it locally

```bash
flutter pub get
cp .env.example .env   # fill in your own Supabase project URL + publishable key
flutter run -d chrome
```

Database schema and RLS policies are in [`supabase/migrations`](./supabase/migrations), numbered in application order.
