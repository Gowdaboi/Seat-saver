-- Catering Seating & Round Management App — initial schema
-- Enums, tables, constraints, and indexes. RLS policies live in 0002_rls.sql.

create extension if not exists "pgcrypto";

-- ── Enums ────────────────────────────────────────────────────────────────

create type service_type as enum ('pankti', 'buffet');
create type section_type as enum ('veg', 'nonveg', 'mixed');
create type seat_status as enum ('available', 'booked', 'occupied', 'blocked', 'cleaning');
create type menu_item_type as enum ('veg', 'nonveg');
create type round_status as enum ('upcoming', 'current', 'completed');
create type booking_status as enum ('requested', 'confirmed', 'no_show', 'cancelled');
-- 'queued': waiting in line, not yet offered. 'offered': active offer with a
-- running countdown (at most one 'offered' row per seat at a time).
create type reassignment_status as enum ('queued', 'offered', 'accepted', 'rejected', 'expired');
create type call_type as enum ('text', 'call');
create type call_status as enum ('open', 'acknowledged', 'resolved');

-- ── Tenants (hosts) ──────────────────────────────────────────────────────

create table caterers (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users (id) on delete cascade,
  business_name text not null,
  contact_email text not null,
  created_at timestamptz not null default now()
);

-- ── Events ───────────────────────────────────────────────────────────────

create table events (
  id uuid primary key default gen_random_uuid(),
  caterer_id uuid not null references caterers (id) on delete cascade,
  name text not null,
  venue_name text not null,
  date date not null,
  service_type service_type not null,
  no_show_timeout_minutes int not null default 5 check (no_show_timeout_minutes > 0),
  reassignment_response_minutes int not null default 1 check (reassignment_response_minutes > 0),
  created_at timestamptz not null default now()
);

create index events_caterer_id_idx on events (caterer_id);

-- ── Floor design: sections, tables, seats ───────────────────────────────

create table sections (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  name text not null,
  type section_type not null default 'mixed',
  display_order int not null default 0
);

create index sections_event_id_idx on sections (event_id);

-- Section capacity is intentionally not stored — derive it by summing
-- seat_count across tables where table.section_id = section.id.

create table tables (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  section_id uuid not null references sections (id) on delete cascade,
  table_number int not null,
  seat_count int not null check (seat_count > 0),
  unique (event_id, table_number)
);

create index tables_event_id_idx on tables (event_id);
create index tables_section_id_idx on tables (section_id);

create table seats (
  id uuid primary key default gen_random_uuid(),
  table_id uuid not null references tables (id) on delete cascade,
  seat_number int not null,
  status seat_status not null default 'available',
  unique (table_id, seat_number)
);

create index seats_table_id_idx on seats (table_id);
create index seats_status_idx on seats (status);

-- ── Menu ─────────────────────────────────────────────────────────────────

create table menu_items (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  name text not null,
  type menu_item_type not null
);

create index menu_items_event_id_idx on menu_items (event_id);

-- ── Rounds (Pankti service) ─────────────────────────────────────────────

create table rounds (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  round_number int not null,
  status round_status not null default 'upcoming',
  started_at timestamptz,
  unique (event_id, round_number)
);

create index rounds_event_id_idx on rounds (event_id);

-- ── Guests ───────────────────────────────────────────────────────────────
-- Guest identity is a phone-OTP-verified Supabase Auth account (auth.users),
-- same as caterers — RLS keys off auth.uid() for both roles.

create table guests (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users (id) on delete cascade,
  phone_number text not null unique,
  name text,
  created_at timestamptz not null default now()
);

-- ── Bookings ─────────────────────────────────────────────────────────────

create table bookings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  guest_id uuid not null references guests (id) on delete cascade,
  round_id uuid references rounds (id),
  party_size int not null check (party_size > 0),
  status booking_status not null default 'requested',
  created_at timestamptz not null default now(),
  -- one booking per guest per event
  unique (event_id, guest_id)
);

create index bookings_event_id_idx on bookings (event_id);
create index bookings_round_id_idx on bookings (round_id);
create index bookings_guest_id_idx on bookings (guest_id);

create table booking_seats (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings (id) on delete cascade,
  seat_id uuid not null references seats (id) on delete cascade
);

create index booking_seats_booking_id_idx on booking_seats (booking_id);
create index booking_seats_seat_id_idx on booking_seats (seat_id);

-- A seat must not be attached to more than one *active* booking at a time.
-- Postgres partial-index predicates can't reference other tables, so this is
-- enforced with a trigger instead of a partial unique index (historical
-- cancelled/no_show bookings are allowed to keep referencing a seat that's
-- since been rebooked).
create function prevent_double_seat_booking() returns trigger as $$
begin
  if exists (
    select 1
    from booking_seats bs
    join bookings b on b.id = bs.booking_id
    where bs.seat_id = new.seat_id
      and b.status in ('requested', 'confirmed')
  ) then
    raise exception 'seat % already has an active booking', new.seat_id;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger booking_seats_prevent_double_booking
  before insert on booking_seats
  for each row execute function prevent_double_seat_booking();

-- ── No-show reassignment queue ───────────────────────────────────────────
-- A no-show releases a whole group's seats atomically (core rule #1), and
-- offers go out "matching party size" (rule #2) — so the unit of offer is a
-- *group of seats*, not a single seat. reassignment_offers holds one row per
-- candidate-in-line (covering the whole freed group); reassignment_offer_seats
-- lists which seats that offer covers. This mirrors bookings/booking_seats.

create table reassignment_offers (
  id uuid primary key default gen_random_uuid(),
  -- identifies one no-show release event (the specific group of seats freed
  -- together); shared by every candidate's row queued for that group
  seat_group_id uuid not null,
  offered_to_guest_id uuid not null references guests (id) on delete cascade,
  queue_position int not null,
  -- null while status = 'queued'; set when the row transitions to 'offered'
  expires_at timestamptz,
  status reassignment_status not null default 'queued',
  unique (seat_group_id, queue_position)
);

create index reassignment_offers_seat_group_id_idx on reassignment_offers (seat_group_id);
create index reassignment_offers_offered_to_guest_id_idx on reassignment_offers (offered_to_guest_id);
create index reassignment_offers_status_expires_at_idx on reassignment_offers (status, expires_at);

-- Only one candidate's offer active per freed seat-group at a time.
create unique index reassignment_offers_group_offered_uidx on reassignment_offers (seat_group_id)
  where status = 'offered';

create table reassignment_offer_seats (
  id uuid primary key default gen_random_uuid(),
  offer_id uuid not null references reassignment_offers (id) on delete cascade,
  seat_id uuid not null references seats (id) on delete cascade,
  unique (offer_id, seat_id)
);

create index reassignment_offer_seats_offer_id_idx on reassignment_offer_seats (offer_id);
create index reassignment_offer_seats_seat_id_idx on reassignment_offer_seats (seat_id);

-- ── Call requests ────────────────────────────────────────────────────────

create table call_requests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  guest_id uuid not null references guests (id) on delete cascade,
  table_id uuid references tables (id),
  type call_type not null,
  message text,
  status call_status not null default 'open',
  created_at timestamptz not null default now()
);

create index call_requests_event_id_idx on call_requests (event_id);
create index call_requests_status_idx on call_requests (status);

-- ── Feedback ─────────────────────────────────────────────────────────────

create table feedback_forms (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  questions_json jsonb not null default '[]'::jsonb
);

create index feedback_forms_event_id_idx on feedback_forms (event_id);

create table feedback_responses (
  id uuid primary key default gen_random_uuid(),
  form_id uuid not null references feedback_forms (id) on delete cascade,
  guest_id uuid not null references guests (id) on delete cascade,
  answers_json jsonb not null default '{}'::jsonb,
  unique (form_id, guest_id)
);

create index feedback_responses_form_id_idx on feedback_responses (form_id);
