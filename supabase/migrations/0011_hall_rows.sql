-- A second way to build a section's layout, alongside configure_section_layout
-- (0009): instead of a grid of two-sided tables, a Pankti hall is often really
-- rows of individual seats — guests backed against a wall or against the row
-- behind them, with a serving aisle only where two rows face each other.
--
-- Each row is stored as an ordinary one-seat-deep table (tables.seat_count =
-- p_seats_per_row, one table per grid_row, grid_col always 0), reusing the
-- seating_side machinery from 0010 rather than adding new columns: rows
-- alternate 'far'/'near' in pairs (0,1), (2,3), ... so consecutive rows face
-- each other across the gap the widget draws between them, and every other
-- gap is the pair boundary where backs touch. See
-- lib/features/shared/widgets/floor_layout.dart (rowGap, showFacingLabels)
-- for the rendering side of this same pairing.

create function configure_hall_rows(
  p_section_id uuid,
  p_row_count int,
  p_seats_per_row int
) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_event_id uuid;
  v_in_use int;
  v_history int;
  v_next_number int;
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

  if p_row_count <= 0 or p_seats_per_row <= 0 then
    raise exception 'row count and seats per row must both be greater than zero';
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

  for i in 0 .. p_row_count - 1 loop
    insert into tables (
      event_id, section_id, table_number, seat_count, grid_row, grid_col, orientation, seating_side
    ) values (
      v_event_id, p_section_id, v_next_number + i + 1, p_seats_per_row,
      i, 0, 'horizontal', (case when i % 2 = 0 then 'far' else 'near' end)::seating_side
    ) returning id into v_table_id;

    insert into seats (table_id, seat_number, status)
      select v_table_id, gs, 'available' from generate_series(1, p_seats_per_row) as gs;
  end loop;

  update sections set grid_rows = p_row_count, default_orientation = 'horizontal'
   where id = p_section_id;

  return p_row_count * p_seats_per_row;
end;
$$;

revoke all on function configure_hall_rows(uuid, int, int) from public;
grant execute on function configure_hall_rows(uuid, int, int) to authenticated;
