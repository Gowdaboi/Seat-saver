-- The rest of the tenant-wide reads, finishing what 0018 started.
--
-- sections, tables, seats, menu_items, menu_sections, rounds and
-- feedback_forms were all `select ... using (true)` for any authenticated
-- user. 0018 stopped event *names* being enumerable, but not these: a plain
-- `GET /menu_items` still returned every caterer's menu, `GET /tables` every
-- floor plan, `GET /rounds` every schedule — with no event id needed, so
-- unguessable uuids were no protection at all.
--
-- The obstacle to scoping them was the guest flow: someone who has scanned a
-- QR but not yet booked has no row tying them to the event, and they must
-- still be able to look at the floor and the menu before choosing a seat.
--
-- Same answer as get_public_event_info in 0005: route those reads through
-- security-definer functions that take one event id. Naming the event you
-- were given becomes the access rule, and it cannot be used to browse —
-- which is exactly the grant a QR code is meant to confer. The tables
-- themselves then belong to the caterer and to guests holding a booking.

-- ── guest-facing reads, by explicit event id ─────────────────────────────
-- Deliberately narrow, like get_public_event_info: display fields only, for
-- ONE caller-named event, with no way to list events or reach anything else.

create function public_event_menu(p_event_id uuid)
returns table (name text, dietary menu_item_type)
language sql stable security definer set search_path = public as $$
  select name, dietary from menu_items where event_id = p_event_id order by name
$$;

revoke all on function public_event_menu(uuid) from public;
grant execute on function public_event_menu(uuid) to anon, authenticated;

-- Capacity is summed here rather than shipped as nested table rows, so the
-- guest screen no longer needs to read `tables` at all to render a section.
create function public_event_sections(p_event_id uuid)
returns table (id uuid, name text, type section_type, capacity int)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.type,
         coalesce((select sum(t.seat_count)::int from tables t where t.section_id = s.id), 0)
    from sections s
   where s.event_id = p_event_id
   order by s.display_order
$$;

revoke all on function public_event_sections(uuid) from public;
grant execute on function public_event_sections(uuid) to anon, authenticated;

-- The seat picker shows "Round 3" for the round ensure_bookable_round just
-- handed it. That is the only thing it needs `rounds` for.
create function public_round_number(p_round_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select round_number from rounds where id = p_round_id
$$;

revoke all on function public_round_number(uuid) from public;
grant execute on function public_round_number(uuid) to anon, authenticated;

-- ── helper: a guest's claim on a seat ────────────────────────────────────
-- seats reach their event two joins away. Definer so the policy resolves it
-- in one hop instead of nesting RLS evaluation through tables and events.

create function guest_has_booking_for_seat(p_seat_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from seats s
      join tables t on t.id = s.table_id
      join bookings b on b.event_id = t.event_id
     where s.id = p_seat_id
       and b.guest_id = auth_guest_id()
  )
$$;

revoke all on function guest_has_booking_for_seat(uuid) from public, anon;
grant execute on function guest_has_booking_for_seat(uuid) to authenticated;

-- ── replace the open policies ────────────────────────────────────────────
-- Each table gets the same pair: the owning caterer, and a guest holding a
-- booking on that event. guest_has_booking_for_event is the definer helper
-- from 0018, which is also what keeps bookings and events from recursing.

drop policy sections_select_all on sections;
create policy sections_select_own_host on sections for select to authenticated using (
  exists (select 1 from events e where e.id = sections.event_id and e.caterer_id = auth_caterer_id())
);
create policy sections_select_booked_guest on sections for select to authenticated using (
  guest_has_booking_for_event(sections.event_id)
);

drop policy tables_select_all on tables;
create policy tables_select_own_host on tables for select to authenticated using (
  exists (select 1 from events e where e.id = tables.event_id and e.caterer_id = auth_caterer_id())
);
create policy tables_select_booked_guest on tables for select to authenticated using (
  guest_has_booking_for_event(tables.event_id)
);

drop policy menu_items_select_all on menu_items;
create policy menu_items_select_own_host on menu_items for select to authenticated using (
  exists (select 1 from events e where e.id = menu_items.event_id and e.caterer_id = auth_caterer_id())
);
create policy menu_items_select_booked_guest on menu_items for select to authenticated using (
  guest_has_booking_for_event(menu_items.event_id)
);

drop policy menu_sections_select_all on menu_sections;
create policy menu_sections_select_own_host on menu_sections for select to authenticated using (
  exists (select 1 from events e where e.id = menu_sections.event_id and e.caterer_id = auth_caterer_id())
);
create policy menu_sections_select_booked_guest on menu_sections for select to authenticated using (
  guest_has_booking_for_event(menu_sections.event_id)
);

drop policy rounds_select_all on rounds;
create policy rounds_select_own_host on rounds for select to authenticated using (
  exists (select 1 from events e where e.id = rounds.event_id and e.caterer_id = auth_caterer_id())
);
create policy rounds_select_booked_guest on rounds for select to authenticated using (
  guest_has_booking_for_event(rounds.event_id)
);

drop policy feedback_forms_select_all on feedback_forms;
create policy feedback_forms_select_own_host on feedback_forms for select to authenticated using (
  exists (select 1 from events e where e.id = feedback_forms.event_id and e.caterer_id = auth_caterer_id())
);
create policy feedback_forms_select_booked_guest on feedback_forms for select to authenticated using (
  guest_has_booking_for_event(feedback_forms.event_id)
);

drop policy seats_select_all on seats;
create policy seats_select_own_host on seats for select to authenticated using (
  exists (
    select 1 from tables t join events e on e.id = t.event_id
     where t.id = seats.table_id and e.caterer_id = auth_caterer_id()
  )
);
create policy seats_select_booked_guest on seats for select to authenticated using (
  guest_has_booking_for_seat(seats.id)
);
