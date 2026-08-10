-- Row Level Security: tenant isolation (by caterer_id) and guest ownership.
-- Both hosts and guests are real auth.users identities (host: email/password,
-- guest: phone OTP), so every policy below keys off auth.uid().

-- ── Helper functions ─────────────────────────────────────────────────────
-- security definer + fixed search_path so these can't be hijacked and don't
-- recurse through the caller's own RLS grants when used inside policies.

create function auth_caterer_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from caterers where auth_user_id = auth.uid()
$$;

create function auth_guest_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from guests where auth_user_id = auth.uid()
$$;

revoke all on function auth_caterer_id() from public;
revoke all on function auth_guest_id() from public;
grant execute on function auth_caterer_id() to authenticated;
grant execute on function auth_guest_id() to authenticated;

-- ── Enable RLS everywhere ────────────────────────────────────────────────

alter table caterers enable row level security;
alter table events enable row level security;
alter table sections enable row level security;
alter table tables enable row level security;
alter table seats enable row level security;
alter table menu_items enable row level security;
alter table rounds enable row level security;
alter table guests enable row level security;
alter table bookings enable row level security;
alter table booking_seats enable row level security;
alter table reassignment_offers enable row level security;
alter table reassignment_offer_seats enable row level security;
alter table call_requests enable row level security;
alter table feedback_forms enable row level security;
alter table feedback_responses enable row level security;

-- ── caterers: self-service tenant profile ───────────────────────────────

create policy caterers_select_own on caterers for select
  to authenticated using (auth_user_id = auth.uid());

create policy caterers_insert_own on caterers for insert
  to authenticated with check (auth_user_id = auth.uid());

create policy caterers_update_own on caterers for update
  to authenticated using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- ── guests: self-service profile, plus host visibility into their own
-- event's guests (front desk needs to see who they're serving) ─────────

create policy guests_select_own on guests for select
  to authenticated using (auth_user_id = auth.uid());

create policy guests_select_by_host on guests for select
  to authenticated using (
    exists (
      select 1 from bookings b
      join events e on e.id = b.event_id
      where b.guest_id = guests.id
        and e.caterer_id = auth_caterer_id()
    )
  );

create policy guests_insert_own on guests for insert
  to authenticated with check (auth_user_id = auth.uid());

create policy guests_update_own on guests for update
  to authenticated using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- ── events: browsable by any signed-in user (host + guest), writable only
-- by the owning caterer ─────────────────────────────────────────────────

create policy events_select_all on events for select
  to authenticated using (true);

create policy events_insert_own on events for insert
  to authenticated with check (caterer_id = auth_caterer_id());

create policy events_update_own on events for update
  to authenticated using (caterer_id = auth_caterer_id())
  with check (caterer_id = auth_caterer_id());

create policy events_delete_own on events for delete
  to authenticated using (caterer_id = auth_caterer_id());

-- ── sections, tables, menu_items, rounds: same shape — event-scoped,
-- readable by all, writable only by the owning caterer ─────────────────

create policy sections_select_all on sections for select
  to authenticated using (true);
create policy sections_write_own on sections for all
  to authenticated
  using (exists (select 1 from events e where e.id = sections.event_id and e.caterer_id = auth_caterer_id()))
  with check (exists (select 1 from events e where e.id = sections.event_id and e.caterer_id = auth_caterer_id()));

create policy tables_select_all on tables for select
  to authenticated using (true);
create policy tables_write_own on tables for all
  to authenticated
  using (exists (select 1 from events e where e.id = tables.event_id and e.caterer_id = auth_caterer_id()))
  with check (exists (select 1 from events e where e.id = tables.event_id and e.caterer_id = auth_caterer_id()));

create policy menu_items_select_all on menu_items for select
  to authenticated using (true);
create policy menu_items_write_own on menu_items for all
  to authenticated
  using (exists (select 1 from events e where e.id = menu_items.event_id and e.caterer_id = auth_caterer_id()))
  with check (exists (select 1 from events e where e.id = menu_items.event_id and e.caterer_id = auth_caterer_id()));

create policy rounds_select_all on rounds for select
  to authenticated using (true);
create policy rounds_write_own on rounds for all
  to authenticated
  using (exists (select 1 from events e where e.id = rounds.event_id and e.caterer_id = auth_caterer_id()))
  with check (exists (select 1 from events e where e.id = rounds.event_id and e.caterer_id = auth_caterer_id()));

-- ── seats: one join deeper (seat → table → event) ───────────────────────

create policy seats_select_all on seats for select
  to authenticated using (true);
create policy seats_write_own on seats for all
  to authenticated
  using (
    exists (
      select 1 from tables t join events e on e.id = t.event_id
      where t.id = seats.table_id and e.caterer_id = auth_caterer_id()
    )
  )
  with check (
    exists (
      select 1 from tables t join events e on e.id = t.event_id
      where t.id = seats.table_id and e.caterer_id = auth_caterer_id()
    )
  );

-- ── bookings: guest owns their own booking; host manages bookings for
-- their events (including manual walk-in/VIP assignment) ───────────────

create policy bookings_select_own_guest on bookings for select
  to authenticated using (guest_id = auth_guest_id());
create policy bookings_select_own_host on bookings for select
  to authenticated using (
    exists (select 1 from events e where e.id = bookings.event_id and e.caterer_id = auth_caterer_id())
  );

create policy bookings_insert_guest on bookings for insert
  to authenticated with check (guest_id = auth_guest_id());
create policy bookings_insert_host on bookings for insert
  to authenticated with check (
    exists (select 1 from events e where e.id = bookings.event_id and e.caterer_id = auth_caterer_id())
  );

create policy bookings_update_own_guest on bookings for update
  to authenticated using (guest_id = auth_guest_id())
  with check (guest_id = auth_guest_id());
create policy bookings_update_own_host on bookings for update
  to authenticated using (
    exists (select 1 from events e where e.id = bookings.event_id and e.caterer_id = auth_caterer_id())
  )
  with check (
    exists (select 1 from events e where e.id = bookings.event_id and e.caterer_id = auth_caterer_id())
  );

-- ── booking_seats: mirrors bookings ownership one join deeper ──────────

create policy booking_seats_select_guest on booking_seats for select
  to authenticated using (
    exists (select 1 from bookings b where b.id = booking_seats.booking_id and b.guest_id = auth_guest_id())
  );
create policy booking_seats_select_host on booking_seats for select
  to authenticated using (
    exists (
      select 1 from bookings b join events e on e.id = b.event_id
      where b.id = booking_seats.booking_id and e.caterer_id = auth_caterer_id()
    )
  );

create policy booking_seats_insert_guest on booking_seats for insert
  to authenticated with check (
    exists (select 1 from bookings b where b.id = booking_seats.booking_id and b.guest_id = auth_guest_id())
  );
create policy booking_seats_insert_host on booking_seats for insert
  to authenticated with check (
    exists (
      select 1 from bookings b join events e on e.id = b.event_id
      where b.id = booking_seats.booking_id and e.caterer_id = auth_caterer_id()
    )
  );

-- ── reassignment_offers / reassignment_offer_seats: guest sees/responds to
-- their own offers; host sees and manages the queue for their own events.
-- Note: accepting/rejecting an offer isn't a bare RLS-gated UPDATE — it also
-- has to cascade (advance the queue, touch bookings/seats), so in practice
-- guests call the accept_reassignment_offer()/reject_reassignment_offer()
-- RPCs (see the reassignment-engine migration) rather than updating these
-- rows directly. The policies below still bound what those security-definer
-- functions and any direct reads are allowed to touch.
--
-- reassignment_offers and reassignment_offer_seats each have a policy that
-- needs to look up rows in the *other* table (host ownership check on one
-- side, guest ownership check on the other). Two RLS-protected tables whose
-- policies query each other directly deadlocks Postgres with "infinite
-- recursion detected in policy" the moment both sides are exercised in the
-- same query. This helper is security definer (like auth_caterer_id() and
-- auth_guest_id() above) specifically so the reassignment_offers host
-- policy's lookup into reassignment_offer_seats runs as the function owner
-- and doesn't re-trigger reassignment_offer_seats' own RLS — breaking the
-- cycle at exactly one side of it.

create function offer_belongs_to_caterer(p_offer_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from reassignment_offer_seats os
    join seats s on s.id = os.seat_id
    join tables t on t.id = s.table_id
    join events e on e.id = t.event_id
    where os.offer_id = p_offer_id and e.caterer_id = auth_caterer_id()
  )
$$;

revoke all on function offer_belongs_to_caterer(uuid) from public;
grant execute on function offer_belongs_to_caterer(uuid) to authenticated;

create policy reassignment_offers_select_guest on reassignment_offers for select
  to authenticated using (offered_to_guest_id = auth_guest_id());
create policy reassignment_offers_select_host on reassignment_offers for select
  to authenticated using (offer_belongs_to_caterer(id));

create policy reassignment_offers_update_guest on reassignment_offers for update
  to authenticated using (offered_to_guest_id = auth_guest_id())
  with check (offered_to_guest_id = auth_guest_id());

create policy reassignment_offers_write_host on reassignment_offers for all
  to authenticated
  using (offer_belongs_to_caterer(id))
  with check (offer_belongs_to_caterer(id));

create policy reassignment_offer_seats_select_guest on reassignment_offer_seats for select
  to authenticated using (
    exists (
      select 1 from reassignment_offers o
      where o.id = reassignment_offer_seats.offer_id and o.offered_to_guest_id = auth_guest_id()
    )
  );
create policy reassignment_offer_seats_select_host on reassignment_offer_seats for select
  to authenticated using (
    exists (
      select 1 from seats s join tables t on t.id = s.table_id join events e on e.id = t.event_id
      where s.id = reassignment_offer_seats.seat_id and e.caterer_id = auth_caterer_id()
    )
  );
create policy reassignment_offer_seats_write_host on reassignment_offer_seats for all
  to authenticated
  using (
    exists (
      select 1 from seats s join tables t on t.id = s.table_id join events e on e.id = t.event_id
      where s.id = reassignment_offer_seats.seat_id and e.caterer_id = auth_caterer_id()
    )
  )
  with check (
    exists (
      select 1 from seats s join tables t on t.id = s.table_id join events e on e.id = t.event_id
      where s.id = reassignment_offer_seats.seat_id and e.caterer_id = auth_caterer_id()
    )
  );

-- ── call_requests: guest creates/sees their own; host sees/updates for
-- their events ───────────────────────────────────────────────────────────

create policy call_requests_select_guest on call_requests for select
  to authenticated using (guest_id = auth_guest_id());
create policy call_requests_select_host on call_requests for select
  to authenticated using (
    exists (select 1 from events e where e.id = call_requests.event_id and e.caterer_id = auth_caterer_id())
  );

create policy call_requests_insert_guest on call_requests for insert
  to authenticated with check (guest_id = auth_guest_id());

create policy call_requests_update_host on call_requests for update
  to authenticated using (
    exists (select 1 from events e where e.id = call_requests.event_id and e.caterer_id = auth_caterer_id())
  )
  with check (
    exists (select 1 from events e where e.id = call_requests.event_id and e.caterer_id = auth_caterer_id())
  );

-- ── feedback_forms: readable by all (guest fills it out), writable only
-- by the owning caterer ──────────────────────────────────────────────────

create policy feedback_forms_select_all on feedback_forms for select
  to authenticated using (true);
create policy feedback_forms_write_own on feedback_forms for all
  to authenticated
  using (exists (select 1 from events e where e.id = feedback_forms.event_id and e.caterer_id = auth_caterer_id()))
  with check (exists (select 1 from events e where e.id = feedback_forms.event_id and e.caterer_id = auth_caterer_id()));

-- ── feedback_responses: guest owns their own response; host reads
-- responses to their own event's forms ──────────────────────────────────

create policy feedback_responses_select_guest on feedback_responses for select
  to authenticated using (guest_id = auth_guest_id());
create policy feedback_responses_select_host on feedback_responses for select
  to authenticated using (
    exists (
      select 1 from feedback_forms f join events e on e.id = f.event_id
      where f.id = feedback_responses.form_id and e.caterer_id = auth_caterer_id()
    )
  );

create policy feedback_responses_insert_guest on feedback_responses for insert
  to authenticated with check (guest_id = auth_guest_id());
