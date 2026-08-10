-- Guest-facing pieces needed for a real, event-scoped guest flow:
-- 1. get_public_event_info() — lets the QR-landing page show the real event
--    name/venue before the guest has logged in at all. Deliberately narrow:
--    callable by anon, returns only display fields for ONE caller-specified
--    event id, no way to browse/enumerate other events. The alternative
--    (granting anon broad SELECT on `events`) would leak every tenant's
--    event names/dates to anyone, not just the one they scanned — not doing
--    that for a cosmetic landing-page improvement.
-- 2. book_seats() — atomic seat booking. Guests have no RLS write access to
--    `seats` (only hosts do — see 0002_rls.sql seats_write_own), so this has
--    to be security definer like the reassignment-offer functions. Locks
--    the requested seats, checks they're all still available, then creates
--    the booking + booking_seats + flips seat status in one transaction.

create function get_public_event_info(p_event_id uuid)
returns table(name text, venue_name text, date date, service_type service_type)
language sql stable security definer set search_path = public as $$
  select name, venue_name, date, service_type from events where id = p_event_id
$$;

revoke all on function get_public_event_info(uuid) from public;
grant execute on function get_public_event_info(uuid) to anon, authenticated;

create function book_seats(p_event_id uuid, p_seat_ids uuid[], p_party_size int) returns uuid
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

  -- lock the requested seats first (bare SELECT, no aggregate — FOR UPDATE
  -- can't be combined with an aggregate directly), then count how many of
  -- them were actually locked as still-available in the outer query.
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

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  update seats set status = 'booked' where id = any(p_seat_ids);

  return v_booking_id;
end;
$$;

revoke all on function book_seats(uuid, uuid[], int) from public;
grant execute on function book_seats(uuid, uuid[], int) to authenticated;
