-- Seat ownership tracking, to close a real replay-protection gap that
-- affects both service types (found while wiring check-in for Buffet):
--
-- Buffet has no rounds, so check_in_booking's round-matching check (the
-- mechanism that stops a Pankti QR from being replayed once its round has
-- passed) doesn't apply at all. But Buffet seats DO get reused many times
-- over an event: guest eats, leaves, host marks the seat cleaning →
-- available, a new guest books it. A guest's original QR still points at
-- the same seat_id forever via booking_seats — nothing previously tracked
-- whether that guest's claim on the seat was still current or long since
-- superseded by someone else's booking.
--
-- Fix: seats.current_booking_id records whoever most recently legitimately
-- claimed that seat (set by book_seats() and accept_reassignment_offer(),
-- the only two paths that hand a seat to a booking). check_in_booking()
-- now requires every seat in the scanned booking to still be *the current
-- claim*, not just historically associated via booking_seats. This applies
-- to both service types — it doesn't weaken Pankti's existing round check,
-- it adds a second, independent guard.
--
-- Fixing this surfaced a second, unrelated bug: accept_reassignment_offer()
-- confirmed a booking and assigned its seats, but never set the booking's
-- round_id — so a guest who accepted a reassignment offer would have no
-- round to match against and their QR would always fail check-in. Fixed
-- in the same pass since it's the same code path being touched.

alter table seats add column current_booking_id uuid references bookings (id) on delete set null;

-- ── prevent_double_seat_booking: rewritten against seat state, not booking
-- status history ─────────────────────────────────────────────────────────
-- The original version (0001_init.sql) treated any booking_seats row whose
-- booking is still 'requested'/'confirmed' as an active claim. That breaks
-- Buffet reuse: a buffet booking never transitions away from 'confirmed'
-- even after the guest has eaten and left, so the old logic would treat
-- guest #1's long-finished booking as still blocking guest #2 from ever
-- being assigned that freed seat. Now checks the seat's own current state
-- instead: blocked only if the seat isn't 'available' AND its
-- current_booking_id doesn't already match the booking being inserted.
-- book_seats() and accept_reassignment_offer() both set current_booking_id
-- (and status) *before* inserting into booking_seats specifically so this
-- trigger sees the new booking as the legitimate holder when it fires.

create or replace function prevent_double_seat_booking() returns trigger as $$
begin
  if exists (
    select 1 from seats s
    where s.id = new.seat_id
      and s.status <> 'available'
      and s.current_booking_id is distinct from new.booking_id
  ) then
    raise exception 'seat % already has an active booking', new.seat_id;
  end if;
  return new;
end;
$$ language plpgsql;

-- ── book_seats: set seat ownership *before* inserting booking_seats (see
-- trigger note above), then also record ownership ───────────────────────

create or replace function book_seats(p_event_id uuid, p_seat_ids uuid[], p_party_size int) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_guest_id uuid;
  v_booking_id uuid;
  v_locked_count int;
begin
  v_guest_id := auth_guest_id();
  if v_guest_id is null then
    raise exception 'no guest identity for current user';
  end if;

  if p_seat_ids is null or array_length(p_seat_ids, 1) is distinct from p_party_size then
    raise exception 'seat count does not match party size';
  end if;

  with locked as (
    select s.id
      from seats s
      join tables t on t.id = s.table_id
     where s.id = any(p_seat_ids)
       and t.event_id = p_event_id
       and s.status = 'available'
     for update of s
  )
  select count(*) into v_locked_count from locked;

  if v_locked_count <> p_party_size then
    raise exception 'one or more selected seats are no longer available';
  end if;

  insert into bookings (event_id, guest_id, party_size, status)
    values (p_event_id, v_guest_id, p_party_size, 'confirmed')
    returning id into v_booking_id;

  -- ownership set before booking_seats insert — see trigger note above
  update seats
     set status = 'booked', current_booking_id = v_booking_id
   where id = any(p_seat_ids);

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  return v_booking_id;
end;
$$;

-- ── accept_reassignment_offer: also record seat ownership, and (the bug
-- fix) actually set the booking's round_id ──────────────────────────────

create or replace function accept_reassignment_offer(p_offer_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_booking_id uuid;
  v_current_round_id uuid;
begin
  perform 1 from reassignment_offers
   where id = p_offer_id
     and offered_to_guest_id = auth_guest_id()
     and status = 'offered'
   for update;

  if not found then
    raise exception 'no active offer % for current guest', p_offer_id;
  end if;

  select t.event_id into v_event_id
    from reassignment_offer_seats os
    join seats s on s.id = os.seat_id
    join tables t on t.id = s.table_id
   where os.offer_id = p_offer_id
   limit 1;

  select id into v_booking_id
    from bookings
   where event_id = v_event_id and guest_id = auth_guest_id();

  if v_booking_id is null then
    raise exception 'no booking found for current guest on event %', v_event_id;
  end if;

  select id into v_current_round_id from rounds where event_id = v_event_id and status = 'current';

  update reassignment_offers set status = 'accepted' where id = p_offer_id;

  update bookings
     set status = 'confirmed', round_id = coalesce(round_id, v_current_round_id)
   where id = v_booking_id;

  -- ownership set before booking_seats insert — see trigger note above
  update seats
     set status = 'booked', current_booking_id = v_booking_id
   where id in (select seat_id from reassignment_offer_seats where offer_id = p_offer_id);

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, os.seat_id
    from reassignment_offer_seats os
   where os.offer_id = p_offer_id;
end;
$$;

-- ── check_in_booking: verify seat ownership is still current, for both
-- service types ─────────────────────────────────────────────────────────

create or replace function check_in_booking(p_booking_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_round_id uuid;
  v_party_size int;
  v_service_type service_type;
  v_current_round_id uuid;
  v_guest_name text;
  v_seats jsonb;
  v_stale_count int;
begin
  select b.event_id, b.round_id, b.party_size
    into v_event_id, v_round_id, v_party_size
    from bookings b
    join events e on e.id = b.event_id
   where b.id = p_booking_id
     and e.caterer_id = auth_caterer_id()
     and b.status = 'confirmed';

  if v_event_id is null then
    raise exception 'Booking not found, not confirmed, or not one of your events';
  end if;

  select service_type into v_service_type from events where id = v_event_id;

  if v_service_type = 'pankti' then
    select id into v_current_round_id from rounds where event_id = v_event_id and status = 'current';
    if v_current_round_id is null then
      raise exception 'No round is currently running for this event';
    end if;
    if v_round_id is null or v_round_id <> v_current_round_id then
      raise exception 'This booking is not for the round happening right now';
    end if;
  end if;

  select count(*) into v_stale_count
    from booking_seats bs
    join seats s on s.id = bs.seat_id
   where bs.booking_id = p_booking_id
     and s.current_booking_id is distinct from p_booking_id;

  if v_stale_count > 0 then
    raise exception 'One or more of these seats have since been reassigned to a different booking';
  end if;

  update seats
     set status = 'occupied'
   where id in (select seat_id from booking_seats where booking_id = p_booking_id)
     and status <> 'occupied';

  select g.name into v_guest_name
    from guests g join bookings b on b.guest_id = g.id
   where b.id = p_booking_id;

  select jsonb_agg(
           jsonb_build_object('table_number', t.table_number, 'seat_number', s.seat_number)
           order by t.table_number, s.seat_number
         )
    into v_seats
    from booking_seats bs
    join seats s on s.id = bs.seat_id
    join tables t on t.id = s.table_id
   where bs.booking_id = p_booking_id;

  return jsonb_build_object(
    'guest_name', v_guest_name,
    'party_size', v_party_size,
    'seats', coalesce(v_seats, '[]'::jsonb)
  );
end;
$$;
