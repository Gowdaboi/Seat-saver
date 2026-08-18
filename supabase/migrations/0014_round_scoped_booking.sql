-- Seat availability becomes per-round for Pankti service.
--
-- Until now a seat had one global status, so seat 5 could not be free for
-- round 2 while taken for round 1 — the very thing multi-round service is.
-- Bookings got their round_id late, swept in when the host *started* a
-- round, because at booking time there was no round to point at.
--
-- The fix needs no new table: booking_seats already records which seats a
-- booking holds, and bookings.round_id records which sitting it is for.
-- Together they answer "is this seat taken for round R" directly. That
-- frees seats.status to mean only what is physically true right now:
--
--   available — nobody in it, nothing held against it for the live round
--   booked    — held for the round currently being served, guest not yet in
--   occupied  — someone is sitting in it
--   cleaning  — being turned around
--
-- 'blocked' is gone: taking a seat out of service is a fact about the floor
-- plan, not a live service state, so it belongs in Design floor (delete the
-- seat) rather than as a status the host toggles mid-shift.
--
-- Buffet has no rounds and keeps the status-based rule it always had: a
-- seat is bookable when it is available and unheld.

-- ── seat_status: drop 'blocked' ───────────────────────────────────────────
-- Postgres cannot remove a value from an enum in place, so the type is
-- rebuilt. Safe here: seat_status appears only on seats.status and in one
-- plpgsql local variable, never in a function signature.

update seats set status = 'available' where status = 'blocked';

-- host_pending_noshow_bookings reads seats.status, and a column's type
-- cannot change underneath a view. Dropped here and recreated unchanged
-- once the swap is done.
drop view host_pending_noshow_bookings;

alter table seats alter column status drop default;
create type seat_status_new as enum ('available', 'booked', 'occupied', 'cleaning');
alter table seats alter column status type seat_status_new using status::text::seat_status_new;
drop type seat_status;
alter type seat_status_new rename to seat_status;
alter table seats alter column status set default 'available';

create view host_pending_noshow_bookings
with (security_invoker = true) as
select
  b.id as booking_id,
  b.event_id,
  b.party_size,
  b.round_id,
  r.started_at as round_started_at,
  e.no_show_timeout_minutes
from bookings b
join rounds r on r.id = b.round_id
join events e on e.id = b.event_id
where b.status = 'confirmed'
  and r.status = 'current'
  and r.started_at + make_interval(mins => e.no_show_timeout_minutes) < now()
  and exists (
    select 1 from booking_seats bs
    join seats s on s.id = bs.seat_id
    where bs.booking_id = b.id and s.status <> 'occupied'
  );

-- ── round-scoped double-booking guard ────────────────────────────────────
-- The old trigger asked "is this seat non-available and held by someone
-- else", which is the right question only when there is one sitting. Now a
-- seat may legitimately be held by different guests in different rounds; a
-- clash is two *active* bookings for the same seat in the same round.
-- Cancelled and no-show bookings release their hold, so they are excluded.

create or replace function prevent_double_seat_booking() returns trigger as $$
declare
  v_round_id uuid;
  v_event_id uuid;
begin
  select round_id, event_id into v_round_id, v_event_id
    from bookings where id = new.booking_id;

  if exists (
    select 1
      from booking_seats bs
      join bookings b on b.id = bs.booking_id
     where bs.seat_id = new.seat_id
       and bs.booking_id <> new.booking_id
       and b.status in ('requested', 'confirmed')
       and b.round_id is not distinct from v_round_id
  ) then
    raise exception 'seat % is already taken for that round', new.seat_id;
  end if;

  -- Buffet (no round) additionally has to respect the live seat, since a
  -- seat there is reused within one event rather than across sittings.
  if v_round_id is null and exists (
    select 1 from seats s
     where s.id = new.seat_id
       and s.status <> 'available'
       and s.current_booking_id is distinct from new.booking_id
  ) then
    raise exception 'seat % is currently in use', new.seat_id;
  end if;

  return new;
end;
$$ language plpgsql;

-- ── helpers ──────────────────────────────────────────────────────────────

-- How many seats in this event are still free for a given round.
create function free_seat_count_for_round(p_event_id uuid, p_round_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
    from seats s
    join tables t on t.id = s.table_id
   where t.event_id = p_event_id
     and not exists (
       select 1
         from booking_seats bs
         join bookings b on b.id = bs.booking_id
        where bs.seat_id = s.id
          and b.status in ('requested', 'confirmed')
          and b.round_id = p_round_id
     );
$$;

-- The round a party of p_party_size should book into: the earliest one
-- that still has room. When every planned round is full a new one is
-- created, which is what "the host will have to take the next available
-- round" means in practice — the sitting after the ones already filled.
--
-- security definer because guests have no insert rights on rounds, and
-- this is the one path allowed to add one.
create function ensure_bookable_round(p_event_id uuid, p_party_size int) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_round record;
  v_next_number int;
  v_round_id uuid;
begin
  if not exists (select 1 from events where id = p_event_id and service_type = 'pankti') then
    return null; -- buffet has no rounds
  end if;

  for v_round in
    select id from rounds
     where event_id = p_event_id and status in ('upcoming', 'current')
     order by round_number
  loop
    if free_seat_count_for_round(p_event_id, v_round.id) >= p_party_size then
      return v_round.id;
    end if;
  end loop;

  select coalesce(max(round_number), 0) + 1 into v_next_number
    from rounds where event_id = p_event_id;

  -- Two guests can reach this at once; unique (event_id, round_number)
  -- decides it and the loser adopts the round the winner created rather
  -- than failing the booking.
  insert into rounds (event_id, round_number, status)
    values (p_event_id, v_next_number, 'upcoming')
    on conflict (event_id, round_number) do nothing
    returning id into v_round_id;

  if v_round_id is null then
    select id into v_round_id
      from rounds where event_id = p_event_id and round_number = v_next_number;
  end if;

  return v_round_id;
end;
$$;

-- Seats for one section with their availability *for a given round*, which
-- a plain PostgREST select on `seats` cannot express. p_round_id null means
-- buffet, where live status is the answer.
create function seats_for_round(p_section_id uuid, p_round_id uuid)
returns table (
  seat_id uuid,
  seat_number int,
  table_id uuid,
  table_number int,
  grid_row int,
  grid_col int,
  orientation table_orientation,
  seating_side seating_side,
  status seat_status,
  is_free boolean
)
language sql stable security definer set search_path = public as $$
  select s.id, s.seat_number, t.id, t.table_number, t.grid_row, t.grid_col,
         t.orientation, t.seating_side, s.status,
         case
           when p_round_id is null
             then s.status = 'available' and s.current_booking_id is null
           else not exists (
             select 1
               from booking_seats bs
               join bookings b on b.id = bs.booking_id
              where bs.seat_id = s.id
                and b.status in ('requested', 'confirmed')
                and b.round_id = p_round_id
           )
         end
    from seats s
    join tables t on t.id = s.table_id
   where t.section_id = p_section_id
   order by t.grid_row, t.grid_col, s.seat_number;
$$;

-- ── book_seats, now round-aware ──────────────────────────────────────────

drop function if exists book_seats(uuid, uuid[], int);

create function book_seats(
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

    -- Lock the seats so two guests cannot pass this check at once, then
    -- confirm none is already spoken for in this round.
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
    -- Buffet: the live seat is the reservation.
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

  -- Pankti seats are only *reserved* for a future sitting, so the physical
  -- seat is untouched until that round starts (see start_round). Buffet
  -- holds the seat immediately, because the guest is arriving now.
  if v_service_type <> 'pankti' then
    update seats set status = 'booked', current_booking_id = v_booking_id
     where id = any(p_seat_ids);
  end if;

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  return v_booking_id;
end;
$$;

revoke all on function book_seats(uuid, uuid[], int, uuid) from public;
grant execute on function book_seats(uuid, uuid[], int, uuid) to authenticated;
revoke all on function ensure_bookable_round(uuid, int) from public;
grant execute on function ensure_bookable_round(uuid, int) to authenticated;
revoke all on function free_seat_count_for_round(uuid, uuid) from public;
grant execute on function free_seat_count_for_round(uuid, uuid) to authenticated;
revoke all on function seats_for_round(uuid, uuid) from public;
grant execute on function seats_for_round(uuid, uuid) to authenticated;

-- ── host_assign_seats: no "seat them now" toggle ─────────────────────────
-- A host assigning a seat on someone's behalf is making a booking, not
-- deciding whether the guest is already sitting down — that is what
-- check-in is for. The toggle let the two be set independently and get out
-- of step. Same round rules as a guest booking.

drop function if exists host_assign_seats(uuid, uuid[], int, text, text, boolean);

create function host_assign_seats(
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

  if v_service_type <> 'pankti' then
    update seats set status = 'booked', current_booking_id = v_booking_id
     where id = any(p_seat_ids);
  end if;

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  return v_booking_id;
end;
$$;

revoke all on function host_assign_seats(uuid, uuid[], int, text, text, uuid) from public;
grant execute on function host_assign_seats(uuid, uuid[], int, text, text, uuid) to authenticated;

-- ── start_round ──────────────────────────────────────────────────────────
-- Replaces the client-side "complete current, insert next, sweep bookings"
-- sequence. The sweep existed only because bookings had no round until the
-- round began; they carry one from the outset now, so starting a round
-- instead *materialises* its reservations onto the physical seats — which
-- is what makes a held seat show as booked on the live board exactly while
-- that sitting is being served.

create function start_round(p_event_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_round_id uuid;
begin
  if not exists (select 1 from events where id = p_event_id and caterer_id = auth_caterer_id()) then
    raise exception 'not your event';
  end if;

  -- Finishing a sitting releases its seats; anything still occupied is left
  -- for the host to turn around rather than being silently wiped.
  update seats s set status = 'available', current_booking_id = null
   from tables t
   where t.id = s.table_id
     and t.event_id = p_event_id
     and s.status = 'booked';

  update rounds set status = 'completed'
   where event_id = p_event_id and status = 'current';

  select id into v_round_id
    from rounds
   where event_id = p_event_id and status = 'upcoming'
   order by round_number
   limit 1;

  if v_round_id is null then
    insert into rounds (event_id, round_number, status, started_at)
      select p_event_id, coalesce(max(round_number), 0) + 1, 'current', now()
        from rounds where event_id = p_event_id
      returning id into v_round_id;
  else
    update rounds set status = 'current', started_at = now() where id = v_round_id;
  end if;

  -- Hold the seats this round's guests reserved, so the board shows them as
  -- spoken for while the sitting runs.
  update seats s set status = 'booked', current_booking_id = b.id
    from booking_seats bs
    join bookings b on b.id = bs.booking_id
   where bs.seat_id = s.id
     and b.round_id = v_round_id
     and b.status in ('requested', 'confirmed')
     and s.status = 'available';

  return v_round_id;
end;
$$;

revoke all on function start_round(uuid) from public;
grant execute on function start_round(uuid) to authenticated;

-- ── backfill ─────────────────────────────────────────────────────────────
-- Pankti bookings made under the old model may have no round. Put them in
-- the earliest round of their event so they are not invisible to the new
-- per-round availability checks.

update bookings b
   set round_id = r.id
  from events e
  join lateral (
    select id from rounds where event_id = e.id order by round_number limit 1
  ) r on true
 where b.event_id = e.id
   and e.service_type = 'pankti'
   and b.round_id is null;
