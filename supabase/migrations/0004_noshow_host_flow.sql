-- Host-mediated no-show detection: the X-minute no-show timeout does NOT
-- auto-release seats. It's the threshold past which a booking with at least
-- one unconfirmed seat becomes visible to the host as a no-show candidate;
-- the host explicitly marks it, which (per core rule #1) releases the whole
-- group atomically — not just the specific seat that wasn't scanned.

-- ── Host-facing view: bookings past the timeout with an unconfirmed seat ──

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

-- security_invoker means this view is subject to the querying host's own
-- RLS grants (via bookings_select_own_host) — no separate grant needed
-- beyond normal table access.

-- ── mark_booking_no_show: host-callable RPC ──────────────────────────────

create function mark_booking_no_show(p_booking_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_party_size int;
  v_seat_group_id uuid := gen_random_uuid();
  v_pos int := 0;
  v_offer_id uuid;
  v_candidate record;
begin
  select b.event_id, b.party_size into v_event_id, v_party_size
    from bookings b
    join events e on e.id = b.event_id
   where b.id = p_booking_id
     and e.caterer_id = auth_caterer_id()
     and b.status = 'confirmed'
   for update of b;

  if v_event_id is null then
    raise exception 'booking % not found, not yours, or not eligible for no-show', p_booking_id;
  end if;

  update bookings set status = 'no_show' where id = p_booking_id;

  -- FIFO among other bookings for this event still waiting for a seat of
  -- the same party size (see project-spec.md "Resolved decisions" for why
  -- FIFO-by-created_at is the v1 default, flagged as revisitable)
  for v_candidate in
    select guest_id
      from bookings
     where event_id = v_event_id
       and party_size = v_party_size
       and status = 'requested'
     order by created_at asc
  loop
    v_pos := v_pos + 1;

    insert into reassignment_offers (seat_group_id, offered_to_guest_id, queue_position, status)
    values (v_seat_group_id, v_candidate.guest_id, v_pos, 'queued')
    returning id into v_offer_id;

    insert into reassignment_offer_seats (offer_id, seat_id)
    select v_offer_id, bs.seat_id
      from booking_seats bs
     where bs.booking_id = p_booking_id;
  end loop;

  if v_pos = 0 then
    -- nobody waiting for this party size — open the seats up immediately,
    -- same end state as an exhausted reassignment queue
    update seats
       set status = 'available'
     where id in (select seat_id from booking_seats where booking_id = p_booking_id)
       and status <> 'occupied';
  else
    perform advance_reassignment_group(v_seat_group_id);
  end if;
end;
$$;

revoke all on function mark_booking_no_show(uuid) from public;
grant execute on function mark_booking_no_show(uuid) to authenticated;
