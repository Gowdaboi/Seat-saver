-- Every table so far seats guests on both its near and far side (a banana-leaf
-- row down the middle of the hall). Real halls also have tables against a
-- wall or a stage where only one side is usable. This adds a seating_side
-- setting -- 'both' (default), 'near', or 'far' -- following the same
-- section-default + per-table-override pattern as orientation (0009):
-- configure_section_layout sets a default for the whole layout, and the host
-- can flip individual tables afterward without touching anyone else's.
--
-- 'near'/'far' rather than an explicit side name because the meaning is
-- already orientation-relative in the renderer (near = top for a horizontal
-- table, left for a vertical one) -- see lib/features/shared/widgets/floor_layout.dart.
-- A single-sided table simply gets all of its seats on that one side instead
-- of split evenly; seat_count / total capacity is unaffected either way.

create type seating_side as enum ('both', 'near', 'far');

alter table sections add column default_seating_side seating_side not null default 'both';
alter table tables add column seating_side seating_side not null default 'both';

-- Replacing rather than overloading configure_section_layout: a second
-- 6-argument version left the old 5-argument one callable too, silently
-- skipping the new setting for anyone (or any cached client) still calling
-- the old signature.
drop function if exists configure_section_layout(uuid, int, int, int, table_orientation);

create function configure_section_layout(
  p_section_id uuid,
  p_table_count int,
  p_seats_per_table int,
  p_grid_rows int default 1,
  p_orientation table_orientation default 'horizontal',
  p_seating_side seating_side default 'both'
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

  select count(*) into v_history
    from booking_seats bs
    join seats s on s.id = bs.seat_id
    join tables t on t.id = s.table_id
   where t.section_id = p_section_id;

  if v_history > 0 then
    raise exception
      'cannot regenerate this section: % past booking(s) are recorded against its seats -- '
      'delete the section instead if you want to start over', v_history;
  end if;

  delete from tables where section_id = p_section_id;

  select coalesce(max(table_number), 0) into v_next_number
    from tables where event_id = v_event_id;

  v_cols := ceil(p_table_count::numeric / p_grid_rows)::int;

  for i in 0 .. p_table_count - 1 loop
    insert into tables (
      event_id, section_id, table_number, seat_count, grid_row, grid_col, orientation, seating_side
    ) values (
      v_event_id, p_section_id, v_next_number + i + 1, p_seats_per_table,
      i / v_cols, i % v_cols, p_orientation, p_seating_side
    ) returning id into v_table_id;

    insert into seats (table_id, seat_number, status)
      select v_table_id, gs, 'available' from generate_series(1, p_seats_per_table) as gs;
  end loop;

  update sections
     set grid_rows = p_grid_rows, default_orientation = p_orientation, default_seating_side = p_seating_side
   where id = p_section_id;

  return p_table_count * p_seats_per_table;
end;
$$;

revoke all on function configure_section_layout(uuid, int, int, int, table_orientation, seating_side) from public;
grant execute on function configure_section_layout(uuid, int, int, int, table_orientation, seating_side) to authenticated;
