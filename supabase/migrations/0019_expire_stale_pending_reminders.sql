-- A queued reminder whose moment has passed must never be sent.
--
-- enqueue_due_round_reminders() only ever *inserts* rows for rounds still in
-- the future, and the comment in 0015 claimed a missed window therefore stays
-- missed. That was only half true: it guards the insert, not the row's later
-- life. A reminder queued at T-5min sits `pending` until something claims it,
-- and if nothing does — the sender was down, misconfigured, returning 403 —
-- it stays queued indefinitely. The moment the sender starts working, days
-- later, that row goes out announcing a sitting that finished long ago.
--
-- Found exactly that way: the edge function was rejecting every cron call
-- with 403, so a reminder from the previous day was still sitting `pending`,
-- primed to fire the instant the sender was fixed.
--
-- So the same "strictly before the round" rule that governs the insert now
-- governs the queue: once scheduled_start_at is behind us, the row is
-- skipped. Between T-lead and T it remains sendable, which is the whole
-- point of the window.

create or replace function enqueue_due_round_reminders() returns int
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

  -- Anything queued for a round that has since started, for a booking that
  -- has since been cancelled or marked no-show, or whose start time has
  -- simply gone by while the row sat unsent, is now a lie. Drop it before it
  -- can be claimed.
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
            -- The round has begun, or its plan was cleared out from under
            -- the reminder. Either way there is nothing truthful to send.
            or r.scheduled_start_at is null
            or r.scheduled_start_at <= now()
          )
     );

  -- Runs after the skip pass, so a row inserted here is never skipped in the
  -- same call — it is inserted only while the round is still ahead of us.
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

revoke all on function enqueue_due_round_reminders() from public, anon, authenticated;
