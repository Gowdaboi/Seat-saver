-- Floor design so far stored *how many* tables and seats, but nothing about
-- where anything sits. The guest seat picker could therefore only ever show a
-- flat list of tables — which is a poor stand-in for "walk in and find your
-- seat". This migration adds the geometry the spec's seat picker needs:
--
--   * tables are placed on a grid (grid_row, grid_col) within their section,
--   * each table has an orientation, so a long banquet table can run along
--     the hall (horizontal: seats on the near and far side) or across it
--     (vertical: seats on the left and right side).
--
-- Geometry is deliberately a coarse grid rather than free x/y pixels: hosts
-- are describing a seating plan, not drawing to scale, and a grid is what
-- both the host editor and the guest picker can render identically. The two
-- sides share one renderer (lib/features/shared/widgets/floor_layout.dart),
-- so what the host arranges is literally what the guest sees.

create type table_orientation as enum ('horizontal', 'vertical');

alter table sections
  add column grid_rows int not null default 1 check (grid_rows > 0),
  add column default_orientation table_orientation not null default 'horizontal';

alter table tables
  add column grid_row int not null default 0 check (grid_row >= 0),
  add column grid_col int not null default 0 check (grid_col >= 0),
  add column orientation table_orientation not null default 'horizontal';

-- Existing tables predate the grid and would otherwise all stack at (0,0).
-- Lay each section's tables out left-to-right in a single row, in the table
-- numbering the host already sees.
with placed as (
  select id, row_number() over (partition by section_id order by table_number) - 1 as col
    from tables
)
update tables t set grid_col = placed.col
  from placed where placed.id = t.id;

-- ── Bulk layout generator ────────────────────────────────────────────────
-- The host-facing shortcut from the spec: say how many tables and how many
-- seats each holds, and the floor is calculated. Capacity is *derived*
-- (tables x seats per table) rather than entered — a host-entered total that
-- disagreed with the table math would just be a second source of truth.
--
-- This is an RPC rather than client-side inserts for two reasons: it has to
-- be atomic (a half-generated floor is worse than none), and it has to be
-- able to refuse. Regenerating a section drops and recreates its tables, so
-- any seat that is already spoken for would take a live booking down with
-- it — hence the in-use guard below.
create function configure_section_layout(
  p_section_id uuid,
  p_table_count int,
  p_seats_per_table int,
  p_grid_rows int default 1,
  p_orientation table_orientation default 'horizontal'
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_in_use int;
  v_history int;
  v_next_number int;
  v_cols int;
  v_table_id uuid;
  i int;
begin
  select e.id into v_event_id
    from sections s
    join events e on e.id = s.event_id
   where s.id = p_section_id
     and e.caterer_id = auth_caterer_id();

  if v_event_id is null then
    raise exception 'not your section';
  end if;

  if p_table_count <= 0 or p_seats_per_table <= 0 or p_grid_rows <= 0 then
    raise exception 'tables, seats per table, and rows must all be greater than zero';
  end if;

  if p_grid_rows > p_table_count then
    raise exception 'cannot arrange % table(s) into % row(s)', p_table_count, p_grid_rows;
  end if;

  select count(*) into v_in_use
    from seats s
    join tables t on t.id = s.table_id
   where t.section_id = p_section_id
     and (s.status <> 'available' or s.current_booking_id is not null);

  if v_in_use > 0 then
    raise exception
      'cannot regenerate this section: % seat(s) are already booked, occupied or blocked', v_in_use;
  end if;

  -- The status check above isn't enough on its own. A cancelled or no-show
  -- booking leaves its seats back at 'available', but booking_seats still
  -- records which seats it held — and booking_seats.seat_id cascades on
  -- delete, so regenerating would erase that history out from under the
  -- past-events recap without anything visibly failing. Once a section has
  -- served anyone, rebuilding it in place is off the table; deleting the
  -- section outright is still available, and at least says what it does.
  select count(*) into v_history
    from booking_seats bs
    join seats s on s.id = bs.seat_id
    join tables t on t.id = s.table_id
   where t.section_id = p_section_id;

  if v_history > 0 then
    raise exception
      'cannot regenerate this section: % past booking(s) are recorded against its seats — '
      'delete the section instead if you want to start over', v_history;
  end if;

  delete from tables where section_id = p_section_id;

  -- table_number is unique per *event*, so continue past whatever the other
  -- sections are already using rather than restarting at 1.
  select coalesce(max(table_number), 0) into v_next_number
    from tables where event_id = v_event_id;

  v_cols := ceil(p_table_count::numeric / p_grid_rows)::int;

  for i in 0 .. p_table_count - 1 loop
    insert into tables (
      event_id, section_id, table_number, seat_count, grid_row, grid_col, orientation
    ) values (
      v_event_id, p_section_id, v_next_number + i + 1, p_seats_per_table,
      i / v_cols, i % v_cols, p_orientation
    ) returning id into v_table_id;

    insert into seats (table_id, seat_number, status)
      select v_table_id, gs, 'available' from generate_series(1, p_seats_per_table) as gs;
  end loop;

  update sections
     set grid_rows = p_grid_rows, default_orientation = p_orientation
   where id = p_section_id;

  return p_table_count * p_seats_per_table;
end;
$$;

revoke all on function configure_section_layout(uuid, int, int, int, table_orientation) from public;
grant execute on function configure_section_layout(uuid, int, int, int, table_orientation) to authenticated;

-- Re-flowing an existing section into a different number of rows keeps every
-- table (and therefore every booking) exactly as it is — only grid_row and
-- grid_col move. Safe to run on a live floor, unlike the generator above,
-- which is why it is a separate function with no in-use guard.
create function reflow_section_layout(p_section_id uuid, p_grid_rows int)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_count int;
  v_cols int;
begin
  if not exists (
    select 1 from sections s
      join events e on e.id = s.event_id
     where s.id = p_section_id and e.caterer_id = auth_caterer_id()
  ) then
    raise exception 'not your section';
  end if;

  if p_grid_rows <= 0 then
    raise exception 'rows must be greater than zero';
  end if;

  select count(*) into v_count from tables where section_id = p_section_id;
  if v_count = 0 then
    return;
  end if;

  if p_grid_rows > v_count then
    raise exception 'cannot arrange % table(s) into % row(s)', v_count, p_grid_rows;
  end if;

  v_cols := ceil(v_count::numeric / p_grid_rows)::int;

  with ordered as (
    select id, row_number() over (order by table_number) - 1 as idx
      from tables where section_id = p_section_id
  )
  update tables t
     set grid_row = ordered.idx / v_cols,
         grid_col = ordered.idx % v_cols
    from ordered
   where ordered.id = t.id;

  update sections set grid_rows = p_grid_rows where id = p_section_id;
end;
$$;

revoke all on function reflow_section_layout(uuid, int) from public;
grant execute on function reflow_section_layout(uuid, int) to authenticated;
