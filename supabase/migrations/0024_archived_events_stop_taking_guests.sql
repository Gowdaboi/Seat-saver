-- An archived event stops taking guests.
--
-- 0023 hid archived events from the host's pickers, but left every guest path
-- open: an old QR code still reached the landing page, the floor, the menu and
-- the seat picker, and still produced a booking. A caterer who tidied away
-- last month's wedding had no reason to expect it was still accepting people.
--
-- The rule this establishes, and the one to keep applying:
--
--   **Archiving blocks new commitments. It never blocks completions or
--   releases.**
--
-- So booking is refused, but cancelling a booking, checking in with a QR at
-- the door, and the no-show/reassignment machinery all keep working. Someone
-- who already holds a seat must never be trapped by an administrative action
-- taken after they booked — and a guest cancelling frees a seat, which is
-- something we want to keep being possible for as long as the booking exists.

-- ── the write side: one trigger, not a check in each RPC ─────────────────
-- Deliberately a trigger on `bookings` rather than an added condition inside
-- book_seats and host_assign_seats. Those are two long functions that would
-- both need editing, and any third booking path added later would silently
-- miss the rule. INSERT-only is what makes this express "no new commitments"
-- exactly: updating a booking to 'cancelled' or 'no_show' is untouched.

create or replace function prevent_booking_archived_event() returns trigger
language plpgsql as $$
begin
  if exists (
    select 1 from events
     where id = new.event_id and archived_at is not null
  ) then
    raise exception 'this event is closed and is not taking bookings';
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_prevent_archived_event on bookings;
create trigger bookings_prevent_archived_event
  before insert on bookings
  for each row execute function prevent_booking_archived_event();

-- ── the read side: say what happened, rather than nothing ────────────────
-- Returning no rows would make the landing page fall back to "This QR code
-- doesn't match a known event", which reads as a broken code and sends people
-- to find staff. The event is perfectly real and simply finished, so the page
-- is told that and can say so.

drop function if exists get_public_event_info(uuid);

create function get_public_event_info(p_event_id uuid)
returns table (
  name text,
  venue_name text,
  date date,
  service_type service_type,
  is_archived boolean
)
language sql stable security definer set search_path = public as $$
  select name, venue_name, date, service_type, archived_at is not null
    from events
   where id = p_event_id
$$;

revoke all on function get_public_event_info(uuid) from public;
grant execute on function get_public_event_info(uuid) to anon, authenticated;

-- The browse RPCs go quiet instead, since the landing page is the screen that
-- explains things and these are only reached through it. A guest who deep
-- links past it gets an empty floor rather than a bookable one.

create or replace function public_event_menu(p_event_id uuid)
returns table (name text, dietary menu_item_type)
language sql stable security definer set search_path = public as $$
  select m.name, m.dietary
    from menu_items m
    join events e on e.id = m.event_id
   where m.event_id = p_event_id
     and e.archived_at is null
   order by m.name
$$;

create or replace function public_event_sections(p_event_id uuid)
returns table (id uuid, name text, type section_type, capacity int)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.type,
         coalesce((select sum(t.seat_count)::int from tables t where t.section_id = s.id), 0)
    from sections s
    join events e on e.id = s.event_id
   where s.event_id = p_event_id
     and e.archived_at is null
   order by s.display_order
$$;

create or replace function seats_for_round(p_section_id uuid, p_round_id uuid)
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
    join events e on e.id = t.event_id
   where t.section_id = p_section_id
     and e.archived_at is null
   order by t.grid_row, t.grid_col, s.seat_number;
$$;

revoke all on function seats_for_round(uuid, uuid) from public;
grant execute on function seats_for_round(uuid, uuid) to authenticated;
