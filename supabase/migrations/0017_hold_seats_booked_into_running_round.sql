-- A seat booked into the round that is *already running* was never held.
--
-- 0014 made Pankti bookings leave `seats.status` alone, because a booking for
-- a future sitting genuinely occupies nothing yet; `start_round()` then
-- materialises that round's holds onto the physical seats when the sitting
-- begins. That is still right — but it materialises **once**, at the moment
-- it runs.
--
-- Nothing materialised a booking made *after* its round had started. And that
-- is not an edge case: it is the ordinary path for host assignment, which
-- exists precisely to seat walk-ins and VIPs during service. The seat stayed
-- `available` for the rest of the event, so:
--
--   * the Manage-seats grid showed it grey, tooltip "Available", after a full
--     reload — the host had no way to see the seat was taken;
--   * every status counter (Occupied / Booked / Available) ignored it, so the
--     summary bar contradicted the round chip sitting directly beneath it;
--   * and a host reading "72 available" could hand the same seat to someone
--     else.
--
-- The fix is to hold the seat at booking time whenever the booking is for a
-- sitting happening *now* — buffet, which has no rounds at all, or a Pankti
-- booking whose round is already `current`. Future rounds are untouched, so
-- per-round availability is unchanged.

-- ── book_seats ───────────────────────────────────────────────────────────

create or replace function book_seats(
  p_event_id uuid,
  p_seat_ids uuid[],
  p_party_size int,
  p_round_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_guest_id uuid;
  v_booking_id uuid;
  v_service_type service_type;
  v_round_id uuid := p_round_id;
  v_taken int;
  v_serving_now boolean;
begin
  v_guest_id := auth_guest_id();
  if v_guest_id is null then
    raise exception 'no guest identity for current user';
  end if;

  if p_seat_ids is null or array_length(p_seat_ids, 1) is distinct from p_party_size then
    raise exception 'seat count does not match party size';
  end if;

  select service_type into v_service_type from events where id = p_event_id;
  if v_service_type is null then
    raise exception 'no such event';
  end if;

  if v_service_type = 'pankti' then
    if v_round_id is null then
      v_round_id := ensure_bookable_round(p_event_id, p_party_size);
    end if;
    if v_round_id is null then
      raise exception 'no round available to book into';
    end if;
    if not exists (
      select 1 from rounds
       where id = v_round_id and event_id = p_event_id and status in ('upcoming', 'current')
    ) then
      raise exception 'that round is no longer open for booking';
    end if;

    perform 1 from seats s
      join tables t on t.id = s.table_id
     where s.id = any(p_seat_ids) and t.event_id = p_event_id
     for update of s;

    select count(*) into v_taken
      from booking_seats bs
      join bookings b on b.id = bs.booking_id
     where bs.seat_id = any(p_seat_ids)
       and b.status in ('requested', 'confirmed')
       and b.round_id = v_round_id;

    if v_taken > 0 then
      raise exception 'one or more selected seats are already taken for that round';
    end if;
  else
    select count(*) into v_taken
      from seats s
      join tables t on t.id = s.table_id
     where s.id = any(p_seat_ids)
       and t.event_id = p_event_id
       and s.status = 'available'
       and s.current_booking_id is null
     for update of s;

    if v_taken <> p_party_size then
      raise exception 'one or more selected seats are no longer available';
    end if;
  end if;

  insert into bookings (event_id, guest_id, round_id, party_size, status)
    values (p_event_id, v_guest_id, v_round_id, p_party_size, 'confirmed')
    returning id into v_booking_id;

  -- Is this booking for a sitting happening right now?
  v_serving_now := v_service_type <> 'pankti'
    or exists (select 1 from rounds where id = v_round_id and status = 'current');

  if v_serving_now then
    update seats set status = 'booked', current_booking_id = v_booking_id
     where id = any(p_seat_ids)
       -- Only claim seats that are genuinely free. One still `occupied` or
       -- `cleaning` from the previous sitting belongs to that guest until the
       -- host clears it, and overwriting the status would erase a fact the
       -- floor staff are working from.
       and status = 'available';
  end if;

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  return v_booking_id;
end;
$$;

revoke all on function book_seats(uuid, uuid[], int, uuid) from public;
grant execute on function book_seats(uuid, uuid[], int, uuid) to authenticated;

-- ── host_assign_seats ────────────────────────────────────────────────────

create or replace function host_assign_seats(
  p_event_id uuid,
  p_seat_ids uuid[],
  p_party_size int,
  p_guest_name text,
  p_guest_phone text,
  p_round_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_guest_id uuid;
  v_booking_id uuid;
  v_service_type service_type;
  v_round_id uuid := p_round_id;
  v_taken int;
  v_serving_now boolean;
begin
  select service_type into v_service_type
    from events where id = p_event_id and caterer_id = auth_caterer_id();
  if v_service_type is null then
    raise exception 'not your event';
  end if;

  if p_seat_ids is null or array_length(p_seat_ids, 1) is distinct from p_party_size then
    raise exception 'seat count does not match party size';
  end if;

  if p_guest_phone is not null then
    select id into v_guest_id from guests where phone_number = p_guest_phone;
    if v_guest_id is null then
      insert into guests (phone_number, name) values (p_guest_phone, p_guest_name)
        returning id into v_guest_id;
    end if;
  else
    insert into guests (phone_number, name) values (null, p_guest_name)
      returning id into v_guest_id;
  end if;

  if v_service_type = 'pankti' then
    if v_round_id is null then
      v_round_id := ensure_bookable_round(p_event_id, p_party_size);
    end if;
    if v_round_id is null then
      raise exception 'no round available to book into';
    end if;

    perform 1 from seats s
      join tables t on t.id = s.table_id
     where s.id = any(p_seat_ids) and t.event_id = p_event_id
     for update of s;

    select count(*) into v_taken
      from booking_seats bs
      join bookings b on b.id = bs.booking_id
     where bs.seat_id = any(p_seat_ids)
       and b.status in ('requested', 'confirmed')
       and b.round_id = v_round_id;

    if v_taken > 0 then
      raise exception 'one or more selected seats are already taken for that round';
    end if;
  else
    select count(*) into v_taken
      from seats s
      join tables t on t.id = s.table_id
     where s.id = any(p_seat_ids)
       and t.event_id = p_event_id
       and s.status = 'available'
       and s.current_booking_id is null
     for update of s;

    if v_taken <> p_party_size then
      raise exception 'one or more selected seats are no longer available';
    end if;
  end if;

  insert into bookings (event_id, guest_id, round_id, party_size, status)
    values (p_event_id, v_guest_id, v_round_id, p_party_size, 'confirmed')
    returning id into v_booking_id;

  v_serving_now := v_service_type <> 'pankti'
    or exists (select 1 from rounds where id = v_round_id and status = 'current');

  if v_serving_now then
    update seats set status = 'booked', current_booking_id = v_booking_id
     where id = any(p_seat_ids)
       and status = 'available';
  end if;

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  return v_booking_id;
end;
$$;

revoke all on function host_assign_seats(uuid, uuid[], int, text, text, uuid) from public;
grant execute on function host_assign_seats(uuid, uuid[], int, text, text, uuid) to authenticated;

-- ── backfill ─────────────────────────────────────────────────────────────
-- Bookings already made into a running round are sitting in exactly the state
-- described above: real booking, no hold, invisible on every board. Give them
-- the hold they should have had. Only untouched seats are claimed, so nothing
-- that is occupied or mid-clean is disturbed.

update seats s
   set status = 'booked', current_booking_id = b.id
  from booking_seats bs
  join bookings b on b.id = bs.booking_id
  join rounds r on r.id = b.round_id
 where bs.seat_id = s.id
   and r.status = 'current'
   and b.status in ('requested', 'confirmed')
   and s.status = 'available'
   and s.current_booking_id is null;
