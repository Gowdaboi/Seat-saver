-- Host capability from the original spec that was never built: "Manually
-- block/assign seats (walk-ins, VIP holds, guests without the app)".
--
-- Blocking a seat needs no new plumbing — hosts already have direct RLS
-- write access to `seats` (seats_write_own, 0002_rls.sql), so
-- available <-> blocked is just a plain update from the client.
--
-- Assigning a seat is the real work: a walk-in guest has no phone-OTP
-- Supabase Auth identity by definition, so `guests.auth_user_id` (NOT NULL
-- until now) has to become optional, and phone_number along with it, since
-- a host may not have — or the guest may not want to give — a phone
-- number at all. host_assign_seats() mirrors book_seats() (atomic lock,
-- create booking + booking_seats, set seat ownership) but is host-driven:
-- it finds-or-creates the guest record itself rather than assuming the
-- caller already has a verified guest identity.

alter table guests alter column auth_user_id drop not null;
alter table guests alter column phone_number drop not null;

-- Hosts can create guest records directly (for walk-ins) — low-risk, since
-- the real access boundary is on bookings/booking_seats, which stay scoped
-- to the host's own events via the existing RLS.
create policy guests_insert_by_host on guests for insert
  to authenticated with check (auth_caterer_id() is not null);

create function host_assign_seats(
  p_event_id uuid,
  p_seat_ids uuid[],
  p_party_size int,
  p_guest_name text,
  p_guest_phone text,
  p_mark_occupied boolean default false
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_guest_id uuid;
  v_booking_id uuid;
  v_locked_count int;
  v_seat_status seat_status;
begin
  if not exists (select 1 from events where id = p_event_id and caterer_id = auth_caterer_id()) then
    raise exception 'not your event';
  end if;

  if p_seat_ids is null or array_length(p_seat_ids, 1) is distinct from p_party_size then
    raise exception 'seat count does not match party size';
  end if;

  if p_guest_phone is not null then
    select id into v_guest_id from guests where phone_number = p_guest_phone;
    if v_guest_id is null then
      insert into guests (phone_number, name) values (p_guest_phone, p_guest_name) returning id into v_guest_id;
    end if;
  else
    insert into guests (phone_number, name) values (null, p_guest_name) returning id into v_guest_id;
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

  v_seat_status := case when p_mark_occupied then 'occupied' else 'booked' end;

  -- ownership set before booking_seats insert (see prevent_double_seat_booking, 0007)
  update seats
     set status = v_seat_status, current_booking_id = v_booking_id
   where id = any(p_seat_ids);

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, seat_id from unnest(p_seat_ids) as seat_id;

  return v_booking_id;
end;
$$;

revoke all on function host_assign_seats(uuid, uuid[], int, text, text, boolean) from public;
grant execute on function host_assign_seats(uuid, uuid[], int, text, text, boolean) to authenticated;
