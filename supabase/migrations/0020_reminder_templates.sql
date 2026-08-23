-- Reminders have to be sent as pre-approved templates, not free text.
--
-- Both channels reached the same conclusion from opposite directions:
--
--   * SMS to Indian numbers is governed by TRAI's DLT rules — every
--     commercial message must use a registered template and sender ID.
--     Twilio rejected our free text with "Trial accounts can only use
--     predefined SMS templates".
--   * WhatsApp rejected it with "ContentSid Required". A reminder sent five
--     minutes before a round is business-initiated by definition — the guest
--     has not messaged us — and Meta only permits approved templates there.
--     Re-opening a fresh 24-hour sandbox session changed nothing.
--
-- So composing a sentence at send time cannot ship. The message becomes a
-- template registered with the provider, and we supply the variables.
--
-- reminder_content_sid is nullable and the sender falls back to free text
-- when it is unset: buffet events, non-Indian numbers and local testing all
-- still work without registering anything. It is the India/WhatsApp path
-- that needs a template, not every path.
--
-- The variable contract is positional and fixed, so a registered template
-- can rely on it:
--
--   {{1}} guest name        e.g. "Asha"
--   {{2}} round number      e.g. "2"
--   {{3}} event name        e.g. "Sharma Wedding"
--   {{4}} minutes away      e.g. "5"
--   {{5}} cancel URL        e.g. "https://…/#/c/AbC…"
--
-- A template using fewer of them is fine; unused variables are ignored.

alter table events add column reminder_content_sid text;

comment on column events.reminder_content_sid is
  'Provider template id (Twilio Content SID, HX…). Null means send free text, '
  'which providers reject for business-initiated WhatsApp and for SMS to India.';

-- ── claim_due_round_reminders: hand the template id to the sender ────────
-- The return type gains a column, so this cannot be a create-or-replace.

drop function if exists claim_due_round_reminders(int);

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
  cancel_token text,
  content_sid text
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
         b.cancel_token,
         e.reminder_content_sid
    from marked m
    join bookings b on b.id = m.booking_id
    join rounds r on r.id = m.round_id
    join events e on e.id = b.event_id
    join guests g on g.id = b.guest_id;
end;
$$;

revoke all on function claim_due_round_reminders(int) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function claim_due_round_reminders(int) to service_role';
  end if;
end
$$;

-- ── a skipped reminder must not block the round forever ──────────────────
--
-- The unique (booking_id, round_id) guard is what stops a retried cron run
-- double-messaging a guest, and `on conflict do nothing` enforced it. But a
-- row retired as 'skipped' keeps occupying that slot, so once a reminder had
-- been skipped no further one could ever be queued for that booking and
-- round — a host who reschedules a round would silently never re-remind the
-- guests already queued for it.
--
-- Reviving the row instead is safe precisely because the insert's own WHERE
-- clause has to pass again first: an active booking, an upcoming round, and
-- a start time still ahead of us. A booking cancelled or a round already
-- run can never come back through here.

create or replace function enqueue_due_round_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_inserted int;
begin
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

  -- Anything queued for a round that has since started, for a booking that
  -- has since been cancelled or marked no-show, or whose start time has
  -- simply gone by while the row sat unsent, is now a lie.
  update round_reminders rr
     set status = 'skipped'
   where rr.status = 'pending'
     and exists (
       select 1
         from rounds r
         join bookings b on b.id = rr.booking_id
        where r.id = rr.round_id
          and (
            r.status <> 'upcoming'
            or b.status not in ('requested', 'confirmed')
            or r.scheduled_start_at is null
            or r.scheduled_start_at <= now()
          )
     );

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
     and g.phone_number is not null
  on conflict (booking_id, round_id) do update
     set status = 'pending',
         channel = excluded.channel,
         to_phone = excluded.to_phone,
         attempts = 0,
         error = null,
         claimed_at = null
     -- Only a retired row is revived. A row already pending, sending or sent
     -- is left exactly as it is, which is what keeps the double-send guard
     -- intact.
     where round_reminders.status in ('skipped', 'failed');

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

revoke all on function enqueue_due_round_reminders() from public, anon, authenticated;
