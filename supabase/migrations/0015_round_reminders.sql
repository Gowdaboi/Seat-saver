-- Round reminders: tell a guest a few minutes before their sitting starts,
-- and give them a one-tap way out that actually frees the seat.
--
-- Three things had to exist for that sentence to be true:
--
-- 1. A time to be five minutes before. Rounds only had started_at, stamped
--    when the host presses Start, so until now there was nothing to count
--    back from. rounds.scheduled_start_at is that plan. It is nullable —
--    an unscheduled round simply gets no reminders, which is the honest
--    behavior rather than guessing a time.
--
-- 2. A way for the guest to cancel from an SMS. They may be on a phone that
--    never logged in, so no session exists to authorise against. The link
--    carries an unguessable per-booking token instead: holding it proves
--    nothing about who you are, only that you were sent this booking's
--    message, and it can do exactly one thing to exactly one booking.
--
-- 3. A record of what was sent. round_reminders is a queue, not a fire-and-
--    forget call: unique per (booking, round) so a retried cron run cannot
--    double-message a guest, and stateful so a failed send is visible
--    afterwards instead of vanishing into an edge function's logs.
--
-- Deciding *what* to send is SQL on a cron (below). Actually sending it is
-- the round-reminders edge function, which owns the Twilio credentials —
-- no provider secret is stored in the database.

-- ── enums ────────────────────────────────────────────────────────────────

create type reminder_channel as enum ('sms', 'whatsapp');

-- 'sending' is a claim marker, not a wish: it is what stops two overlapping
-- cron runs from both handing the same row to Twilio.
create type reminder_status as enum ('pending', 'sending', 'sent', 'failed', 'skipped');

-- ── when a round is planned to start ─────────────────────────────────────

alter table rounds add column scheduled_start_at timestamptz;

-- Partial: the scheduler only ever asks about rounds that have a plan.
create index rounds_scheduled_start_at_idx on rounds (scheduled_start_at)
  where scheduled_start_at is not null;

-- ── per-event reminder settings ──────────────────────────────────────────
-- Same shape as no_show_timeout_minutes: a default that matches the agreed
-- behavior (5 minutes), stored per event so a caterer can tune it without
-- a code change.

alter table events add column reminder_lead_minutes int not null default 5
  check (reminder_lead_minutes > 0);
alter table events add column reminder_channel reminder_channel not null default 'sms';

-- ── cancel token ─────────────────────────────────────────────────────────
-- 24 random bytes rendered base64url — 32 chars, no padding, safe in a URL
-- and far past guessing. gen_random_bytes comes from pgcrypto (0001).
-- translate() with a shorter `to` string deletes the surplus characters,
-- which is how '=' padding is stripped in the general case.

create function new_cancel_token() returns text
language sql volatile as $$
  select translate(encode(gen_random_bytes(24), 'base64'), '+/=', '-_');
$$;

revoke all on function new_cancel_token() from public, anon, authenticated;

alter table bookings add column cancel_token text;
update bookings set cancel_token = new_cancel_token() where cancel_token is null;
alter table bookings alter column cancel_token set default new_cancel_token();
alter table bookings alter column cancel_token set not null;
create unique index bookings_cancel_token_uidx on bookings (cancel_token);

-- ── the queue ────────────────────────────────────────────────────────────

create table round_reminders (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings (id) on delete cascade,
  round_id uuid not null references rounds (id) on delete cascade,
  channel reminder_channel not null,
  status reminder_status not null default 'pending',
  -- Snapshotted rather than joined at send time: this is the number the
  -- message actually went to, which is the thing worth being able to answer
  -- later even if the guest edits their profile.
  to_phone text not null,
  body text,
  provider_sid text,
  error text,
  attempts int not null default 0,
  claimed_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  -- One reminder per guest per sitting. This is the whole double-send guard.
  unique (booking_id, round_id)
);

create index round_reminders_status_idx on round_reminders (status);
create index round_reminders_round_id_idx on round_reminders (round_id);

alter table round_reminders enable row level security;

-- Hosts can see what went out for their own events. Nobody writes these
-- from a client: every transition happens inside the security-definer
-- functions below, called by the scheduler and the sender.
create policy round_reminders_select_host on round_reminders for select
  to authenticated using (
    exists (
      select 1 from bookings b join events e on e.id = b.event_id
      where b.id = round_reminders.booking_id and e.caterer_id = auth_caterer_id()
    )
  );

-- ── enqueue: decide who is due ───────────────────────────────────────────
-- Runs on a plain SQL cron every minute. Deliberately holds no secrets and
-- talks to nothing external, so the queue keeps filling correctly even if
-- the sender is down or not deployed yet.

create function enqueue_due_round_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_inserted int;
begin
  -- A claim that never came back (sender crashed, deploy landed mid-send)
  -- would otherwise sit in 'sending' forever. Give it back a couple of
  -- times, then let it fail visibly rather than retry without end.
  update round_reminders
     set status = 'pending'
   where status = 'sending'
     and claimed_at < now() - interval '5 minutes'
     and attempts < 3;

  update round_reminders
     set status = 'failed',
         error = coalesce(error, 'sender did not report back after 3 attempts')
   where status = 'sending'
     and claimed_at < now() - interval '5 minutes'
     and attempts >= 3;

  -- Anything queued for a round that has since started, or for a booking
  -- that has since been cancelled or marked no-show, is now a lie. Drop it
  -- before it can be claimed.
  update round_reminders rr
     set status = 'skipped'
   where rr.status = 'pending'
     and exists (
       select 1
         from rounds r
         join bookings b on b.id = rr.booking_id
        where r.id = rr.round_id
          and (r.status <> 'upcoming' or b.status not in ('requested', 'confirmed'))
     );

  -- The window is strictly *before* the round: once scheduled_start_at has
  -- passed, "your round starts in 5 minutes" is false, and a late reminder
  -- is worse than none. A missed window therefore stays missed.
  insert into round_reminders (booking_id, round_id, channel, to_phone)
  select b.id, r.id, e.reminder_channel, g.phone_number
    from bookings b
    join rounds r on r.id = b.round_id
    join events e on e.id = b.event_id
    join guests g on g.id = b.guest_id
   where b.status in ('requested', 'confirmed')
     and r.status = 'upcoming'
     and r.scheduled_start_at is not null
     and r.scheduled_start_at > now()
     and r.scheduled_start_at <= now() + make_interval(mins => e.reminder_lead_minutes)
     -- Walk-ins the host seated without a phone number simply have nowhere
     -- to send to; they are not an error.
     and g.phone_number is not null
  on conflict (booking_id, round_id) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

-- REVOKE FROM PUBLIC IS NOT ENOUGH HERE. Supabase grants anon,
-- authenticated and service_role EXECUTE on new functions in `public` by
-- default privilege, which is a grant to those roles directly — dropping
-- PUBLIC's grant leaves it untouched. The other RPCs in this schema survive
-- that because they gate on auth_guest_id()/auth_caterer_id() internally and
-- an anon caller simply fails the check; the queue functions have no such
-- inner guard, so the grant *is* the guard and it has to name the roles.
revoke all on function enqueue_due_round_reminders() from public, anon, authenticated;

-- ── claim: hand work to the sender ───────────────────────────────────────
-- Returns the facts a message is composed from, never a composed message:
-- the wording and the cancel URL depend on deployment (which host, which
-- domain), which is the edge function's business, not the database's.

create function claim_due_round_reminders(p_limit int default 50)
returns table (
  reminder_id uuid,
  to_phone text,
  channel reminder_channel,
  guest_name text,
  event_name text,
  venue_name text,
  round_number int,
  scheduled_start_at timestamptz,
  lead_minutes int,
  party_size int,
  cancel_token text
)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform enqueue_due_round_reminders();

  return query
  with claimed as (
    select rr.id
      from round_reminders rr
     where rr.status = 'pending'
     order by rr.created_at
     limit p_limit
     -- skip locked so a slow run never blocks the next one; the two just
     -- divide the queue between them.
     for update skip locked
  ),
  marked as (
    update round_reminders rr
       set status = 'sending',
           attempts = rr.attempts + 1,
           claimed_at = now()
      from claimed c
     where rr.id = c.id
    returning rr.id as reminder_id, rr.booking_id, rr.round_id,
              rr.channel, rr.to_phone
  )
  select m.reminder_id,
         m.to_phone,
         m.channel,
         g.name,
         e.name,
         e.venue_name,
         r.round_number,
         r.scheduled_start_at,
         e.reminder_lead_minutes,
         b.party_size,
         b.cancel_token
    from marked m
    join bookings b on b.id = m.booking_id
    join rounds r on r.id = m.round_id
    join events e on e.id = b.event_id
    join guests g on g.id = b.guest_id;
end;
$$;

revoke all on function claim_due_round_reminders(int) from public, anon, authenticated;

create function mark_round_reminder_sent(
  p_reminder_id uuid,
  p_provider_sid text,
  p_body text
) returns void
language sql security definer set search_path = public as $$
  update round_reminders
     set status = 'sent',
         provider_sid = p_provider_sid,
         body = p_body,
         error = null,
         sent_at = now()
   where id = p_reminder_id;
$$;

revoke all on function mark_round_reminder_sent(uuid, text, text) from public, anon, authenticated;

-- A refusal from the provider is usually transient (rate limit, blip), so
-- the row goes back in the queue — but only while there is still time
-- before the round, which enqueue_due_round_reminders enforces on the way
-- back out. After three tries it stops and stays visible as failed.
create function mark_round_reminder_failed(p_reminder_id uuid, p_error text) returns void
language sql security definer set search_path = public as $$
  update round_reminders
     set status = case when attempts >= 3 then 'failed'::reminder_status
                       else 'pending'::reminder_status end,
         error = p_error
   where id = p_reminder_id;
$$;

revoke all on function mark_round_reminder_failed(uuid, text) from public, anon, authenticated;

-- The sender authenticates as service_role, which is the only identity
-- allowed to move rows through this queue.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function claim_due_round_reminders(int) to service_role';
    execute 'grant execute on function mark_round_reminder_sent(uuid, text, text) to service_role';
    execute 'grant execute on function mark_round_reminder_failed(uuid, text) to service_role';
  end if;
end
$$;

-- ── cancel by token ──────────────────────────────────────────────────────
-- Both functions are callable by anon on purpose: the guest tapping the
-- link has no session. The token is the entire authorisation, and it can
-- only ever reach the one booking it was minted for.

create function get_booking_by_cancel_token(p_token text)
returns table (
  event_name text,
  venue_name text,
  event_date date,
  guest_name text,
  round_number int,
  scheduled_start_at timestamptz,
  party_size int,
  seat_labels text[],
  booking_status booking_status,
  cancellable boolean
)
language sql stable security definer set search_path = public as $$
  select
    e.name,
    e.venue_name,
    e.date,
    g.name,
    r.round_number,
    r.scheduled_start_at,
    b.party_size,
    coalesce(
      (select array_agg('Table ' || t.table_number || ' · Seat ' || s.seat_number
                        order by t.table_number, s.seat_number)
         from booking_seats bs
         join seats s on s.id = bs.seat_id
         join tables t on t.id = s.table_id
        where bs.booking_id = b.id),
      '{}'::text[]
    ),
    b.status,
    b.status in ('requested', 'confirmed')
      and coalesce(r.status, 'upcoming'::round_status) <> 'completed'
      and not exists (
        select 1 from booking_seats bs join seats s on s.id = bs.seat_id
         where bs.booking_id = b.id and s.status = 'occupied'
      )
  from bookings b
  join events e on e.id = b.event_id
  join guests g on g.id = b.guest_id
  left join rounds r on r.id = b.round_id
  where p_token is not null
    and p_token <> ''
    and b.cancel_token = p_token;
$$;

revoke all on function get_booking_by_cancel_token(text) from public;
grant execute on function get_booking_by_cancel_token(text) to anon, authenticated;

-- Returns an outcome code rather than raising, so the public page can render
-- a calm sentence for every case instead of parsing a Postgres error string.
-- 'not_found' is also what an expired or mistyped link gets — there is
-- nothing to distinguish, and nothing worth distinguishing.
create function cancel_booking_by_token(p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_booking_id uuid;
  v_status booking_status;
  v_round_status round_status;
begin
  if p_token is null or p_token = '' then
    return 'not_found';
  end if;

  select b.id, b.status, r.status
    into v_booking_id, v_status, v_round_status
    from bookings b
    left join rounds r on r.id = b.round_id
   where b.cancel_token = p_token
   for update of b;

  if v_booking_id is null then
    return 'not_found';
  end if;

  if v_status = 'cancelled' then
    return 'already_cancelled';
  end if;

  -- Already eaten, already sat down, or already written off as a no-show:
  -- past the point where cancelling means anything.
  if v_status = 'no_show'
     or v_round_status = 'completed'
     or exists (
       select 1 from booking_seats bs join seats s on s.id = bs.seat_id
        where bs.booking_id = v_booking_id and s.status = 'occupied'
     ) then
    return 'too_late';
  end if;

  update bookings set status = 'cancelled' where id = v_booking_id;

  -- Release only the seats this booking physically holds. For a booking in
  -- a future sitting that is none of them — the seats belong to whoever is
  -- being served right now, and per-round availability frees them the
  -- moment the booking above went to 'cancelled'. Blanket-freeing every
  -- seat in booking_seats would have thrown the current sitting out of
  -- their chairs.
  --
  -- current_booking_id is nulled with the status, never after it: it is
  -- what check_in_booking() tests to decide a scanned QR still holds the
  -- seat, so a stale value lets a cancelled guest walk in and re-take it.
  update seats s
     set status = 'available',
         current_booking_id = null
    from booking_seats bs
   where bs.seat_id = s.id
     and bs.booking_id = v_booking_id
     and s.current_booking_id = v_booking_id
     and s.status <> 'occupied';

  -- Don't tell someone to be ready for a round they just cancelled out of.
  update round_reminders
     set status = 'skipped'
   where booking_id = v_booking_id
     and status in ('pending', 'sending');

  return 'cancelled';
end;
$$;

revoke all on function cancel_booking_by_token(text) from public;
grant execute on function cancel_booking_by_token(text) to anon, authenticated;

-- ── schedule ─────────────────────────────────────────────────────────────
-- Only the enqueue half is scheduled here. Draining the queue means calling
-- Twilio, which means provider credentials — those live in the
-- round-reminders edge function's secrets and never touch Postgres. That
-- function is scheduled separately (Supabase Dashboard → Integrations →
-- Cron → Supabase Edge Function), which needs the pg_net extension enabled.
--
-- Note what that scheduling does put in the database: the dashboard builds
-- the job as a net.http_post() call with the service-role key inline in its
-- headers, so the key is stored in cron.job.command. That is readable by
-- postgres/superuser through the SQL editor — not by anon or authenticated,
-- and not by any client — but it is not "out of the database", and rotating
-- the service-role key means editing the cron job too.

select cron.schedule(
  'enqueue-round-reminders',
  '* * * * *',
  $$select enqueue_due_round_reminders();$$
);
