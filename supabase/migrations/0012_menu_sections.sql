-- Menu items were a flat list with a single `type` column, which held the
-- dietary tag ('veg'/'nonveg'). Hosts also need to group items into courses
-- — Starters, Mains, Desserts, Beverages — and order both the courses and
-- the items within them.
--
-- Course and dietary tag are separate dimensions: a Starter can be veg or
-- non-veg, and the guest menu shows both. So this adds courses alongside the
-- dietary tag rather than replacing it, and renames `type` to `dietary` now
-- that "type" would be ambiguous between the two.
--
-- The new table is `menu_sections`, not `sections`: `sections` already means
-- a *floor* seating zone (veg/nonveg/mixed areas that own tables), and
-- guest_floor_menu_screen.dart renders both on one screen. Reusing the bare
-- name there would be genuinely confusing.

create table menu_sections (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete cascade,
  name text not null,
  display_order int not null default 0
);

create index menu_sections_event_id_idx on menu_sections (event_id);

alter table menu_sections enable row level security;

-- Same shape as menu_items: event-scoped, readable by all (guests need it to
-- render the menu), writable only by the owning caterer.
create policy menu_sections_select_all on menu_sections for select
  to authenticated using (true);
create policy menu_sections_write_own on menu_sections for all
  to authenticated
  using (exists (select 1 from events e where e.id = menu_sections.event_id and e.caterer_id = auth_caterer_id()))
  with check (exists (select 1 from events e where e.id = menu_sections.event_id and e.caterer_id = auth_caterer_id()));

-- `on delete set null`, deliberately not cascade: deleting a course should
-- leave its dishes on the menu as uncategorised, never silently delete the
-- host's menu items along with the heading they happened to sit under.
alter table menu_items
  add column menu_section_id uuid references menu_sections (id) on delete set null,
  add column display_order int not null default 0;

create index menu_items_menu_section_id_idx on menu_items (menu_section_id);

alter table menu_items rename column type to dietary;
