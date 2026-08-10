-- Server-authoritative reassignment offer lifecycle: accept, reject, advance
-- to the next candidate, and expire on timeout. This is what makes the
-- guest-side accept/reject countdown trustworthy — the countdown UI reads
-- expires_at and reacts to status changes over Realtime, but the actual
-- expiry/advance decision always happens here, never on the client.
--
-- Scope note: this migration assumes reassignment_offers/reassignment_offer_seats
-- rows already exist for a freed seat-group (i.e. something has already
-- detected the no-show and queued candidates in order). That detection step
-- — "seat unconfirmed X minutes after round start" plus how a partially-arrived
-- group (some seats scanned, some not) should be treated — is a separate
-- piece of business logic, not yet designed. Flagged for a follow-up pass.

-- ── advance_reassignment_group: move to the next queued candidate, or open
-- the seats up generally if nobody's left in line ───────────────────────

create function advance_reassignment_group(p_seat_group_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_next_offer_id uuid;
  v_response_minutes int;
  v_any_seat_id uuid;
begin
  select id into v_next_offer_id
    from reassignment_offers
   where seat_group_id = p_seat_group_id and status = 'queued'
   order by queue_position asc
   limit 1;

  if v_next_offer_id is not null then
    select os.seat_id into v_any_seat_id
      from reassignment_offer_seats os
     where os.offer_id = v_next_offer_id
     limit 1;

    select e.reassignment_response_minutes into v_response_minutes
      from seats s join tables t on t.id = s.table_id join events e on e.id = t.event_id
     where s.id = v_any_seat_id;

    update reassignment_offers
       set status = 'offered',
           expires_at = now() + make_interval(mins => v_response_minutes)
     where id = v_next_offer_id;
  else
    -- nobody left in line for this group — open the seats up generally
    update seats
       set status = 'available'
     where id in (
       select seat_id from reassignment_offer_seats os
       join reassignment_offers o on o.id = os.offer_id
       where o.seat_group_id = p_seat_group_id
     )
     and status <> 'occupied';
  end if;
end;
$$;

revoke all on function advance_reassignment_group(uuid) from public;

-- ── expire_reassignment_offers: run on a schedule; expires anything whose
-- countdown has run out and advances that seat-group's queue ────────────

create function expire_reassignment_offers() returns void
language plpgsql security definer set search_path = public as $$
declare
  r record;
begin
  for r in
    select id, seat_group_id
      from reassignment_offers
     where status = 'offered' and expires_at < now()
  loop
    update reassignment_offers set status = 'expired' where id = r.id;
    perform advance_reassignment_group(r.seat_group_id);
  end loop;
end;
$$;

revoke all on function expire_reassignment_offers() from public;

-- ── accept_reassignment_offer: guest-callable RPC ────────────────────────

create function accept_reassignment_offer(p_offer_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_booking_id uuid;
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

  update reassignment_offers set status = 'accepted' where id = p_offer_id;

  insert into booking_seats (booking_id, seat_id)
  select v_booking_id, os.seat_id
    from reassignment_offer_seats os
   where os.offer_id = p_offer_id;

  update bookings set status = 'confirmed' where id = v_booking_id;

  update seats
     set status = 'booked'
   where id in (select seat_id from reassignment_offer_seats where offer_id = p_offer_id);
end;
$$;

revoke all on function accept_reassignment_offer(uuid) from public;
grant execute on function accept_reassignment_offer(uuid) to authenticated;

-- ── reject_reassignment_offer: guest-callable RPC ────────────────────────

create function reject_reassignment_offer(p_offer_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_seat_group_id uuid;
begin
  update reassignment_offers
     set status = 'rejected'
   where id = p_offer_id
     and offered_to_guest_id = auth_guest_id()
     and status = 'offered'
  returning seat_group_id into v_seat_group_id;

  if v_seat_group_id is null then
    raise exception 'no active offer % for current guest', p_offer_id;
  end if;

  perform advance_reassignment_group(v_seat_group_id);
end;
$$;

revoke all on function reject_reassignment_offer(uuid) from public;
grant execute on function reject_reassignment_offer(uuid) to authenticated;

-- ── Scheduled expiry ──────────────────────────────────────────────────────
-- Requires the pg_cron extension enabled for this project (Supabase:
-- Dashboard → Database → Extensions → pg_cron) before this migration will
-- apply cleanly; if it errors on permissions, enable the extension there
-- first and re-run just the cron.schedule() call below.

create extension if not exists pg_cron;

select cron.schedule(
  'expire-reassignment-offers',
  '*/15 * * * * *', -- every 15 seconds; well under the 1-minute default response window
  $$select expire_reassignment_offers();$$
);
