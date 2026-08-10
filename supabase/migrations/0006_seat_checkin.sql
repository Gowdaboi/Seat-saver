-- Host QR-scan check-in. The guest's confirmation QR encodes only their
-- booking_id (see guest_booking_confirmation_screen.dart) — seat_ids and
-- round_id are deliberately NOT embedded in the QR, because for Pankti
-- events a booking's round_id isn't set until the host starts a round
-- (well after the QR was generated at booking time — see project-spec.md
-- "Resolved decisions" on the round-start sweep). Baking round_id into the
-- QR would make it permanently stale. Instead, "does this match the round
-- happening right now" (core rule #3) is checked live, server-side, every
-- time the code is scanned.

create function check_in_booking(p_booking_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_round_id uuid;
  v_party_size int;
  v_service_type service_type;
  v_current_round_id uuid;
  v_guest_name text;
  v_seats jsonb;
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
  -- Buffet events have no rounds — nothing to check beyond ownership above.

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

revoke all on function check_in_booking(uuid) from public;
grant execute on function check_in_booking(uuid) to authenticated;
