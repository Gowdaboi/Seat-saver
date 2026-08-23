-- Events were readable by every signed-in user, of every tenant.
--
-- `events_select_all ... using (true)` meant any authenticated account —
-- and anyone can create one, a guest needs only a phone OTP — could list
-- every caterer's event names, venues and dates. That is the customer list
-- of every business on the platform. It was survivable while the app ran on
-- localhost; it is not now that it is on a public URL.
--
-- Scoped instead to the two parties with a reason to see an event:
--   * the caterer who owns it;
--   * a guest who holds a booking on it.
--
-- Guests earlier in the flow are unaffected. Nothing on the guest side ever
-- reads `events` directly: the QR landing page uses get_public_event_info(),
-- a security-definer RPC that returns display fields for one caller-named
-- event and cannot be used to browse (0005), and the floor/menu screens read
-- `sections`, `menu_items` and `rounds`, whose policies are untouched here.

-- ── breaking the policy cycle ────────────────────────────────────────────
-- `bookings_select_own_host` already queries `events`. An `events` policy
-- that queries `bookings` back would close the loop, and Postgres answers
-- that with "infinite recursion detected in policy" the moment both sides
-- are exercised in one query.
--
-- Same fix as offer_belongs_to_caterer() in 0002: security definer, so this
-- lookup runs as the owner and does not re-trigger bookings' own RLS,
-- cutting the cycle at exactly one side. Fixed search_path so it cannot be
-- hijacked.

create function guest_has_booking_for_event(p_event_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from bookings
     where event_id = p_event_id
       and guest_id = auth_guest_id()
  )
$$;

revoke all on function guest_has_booking_for_event(uuid) from public, anon;
grant execute on function guest_has_booking_for_event(uuid) to authenticated;

-- ── the policies ─────────────────────────────────────────────────────────

drop policy events_select_all on events;

create policy events_select_own_host on events for select
  to authenticated using (caterer_id = auth_caterer_id());

create policy events_select_booked_guest on events for select
  to authenticated using (guest_has_booking_for_event(id));
