-- host_assign_seats accepted a round belonging to a different event.
--
-- book_seats has always checked that the round it was handed belongs to the
-- event and is still open; host_assign_seats never did. Nothing exercised
-- it, because the host UI passed no round at all and let the RPC choose —
-- so a caller could create a booking on event A whose round_id pointed at
-- event B's round, which corrupts every per-round availability sum that
-- joins the two.
--
-- Found the moment a round picker was added to the assign dialog and the
-- parameter became reachable: a deliberately foreign round id was accepted
-- and a booking created.
--
-- The picker only ever offers rounds from the current event, so this is not
-- reachable through the app as written. It is still the RPC's job to refuse:
-- it is callable by any authenticated host, and a dialog left open across an
-- event switch could send a stale id in good faith.

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

    -- The check this function was missing. Same wording and same rule as
    -- book_seats, so a host and a guest are refused identically.
    if not exists (
      select 1 from rounds
       where id = v_round_id
         and event_id = p_event_id
         and status in ('upcoming', 'current')
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

  -- Hold the seat when the booking is for a sitting happening now (0017).
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

-- Repair anything the gap already let through: a booking whose round belongs
-- to another event has no meaning, and leaving it would keep skewing that
-- event's per-round counts. Detached rather than deleted — the booking and
-- its seats are real, only the round pointer was wrong, and a null round is
-- the same state a pre-0014 booking had.
update bookings b
   set round_id = null
  from rounds r
 where r.id = b.round_id
   and r.event_id <> b.event_id;
