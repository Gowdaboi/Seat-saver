-- Hosts can retire an event they are done with.
--
-- Events accumulate: a caterer running two functions a week has a hundred a
-- year, and every one of them stays in the picker at the top of Design floor,
-- Menu, Rounds and Manage seats forever. The list is ordered by date, so last
-- winter's wedding sits between this week's two — and picking the wrong one
-- means designing a floor or starting a round on somebody else's night.
--
-- Archiving is a *visibility* decision, not a deletion. Nothing is removed:
-- the floor, menu, bookings and past-event recap all stay exactly as they
-- were, and restoring is one tap. That matters because an event is the root
-- of a cascade — deleting one would take its sections, tables, seats and
-- booking history with it.
--
-- archived_at rather than a boolean: it answers "when did this get archived",
-- which is the question actually asked when something turns up in the
-- archive unexpectedly. Null means active.

-- Idempotent throughout: the Supabase SQL editor is not all-or-nothing —
-- a parse error partway leaves earlier statements committed — so applying
-- this twice, or after a half-finished attempt, has to be safe.
alter table events add column if not exists archived_at timestamptz;

comment on column events.archived_at is
  'When the host retired this event from the pickers. Null means active. '
  'Never set by deletion — the event and everything under it is preserved.';

-- Partial, because the only hot query is "this caterer''s active events",
-- which is what every event picker in the app runs on load.
create index if not exists events_active_idx on events (caterer_id, date)
  where archived_at is null;

-- ── don't archive an event that is being served ──────────────────────────
-- Archiving removes the event from every picker, so doing it while a round
-- is running strands the host mid-service: the Rounds screen they need is
-- reached through exactly the dropdown the event just vanished from. The UI
-- disables the action in that state, but the rule belongs here — a client
-- check is a courtesy, not a guarantee.

create or replace function prevent_archiving_live_event() returns trigger
language plpgsql as $$
begin
  if new.archived_at is not null
     and old.archived_at is null
     and exists (
       select 1 from rounds
        where event_id = new.id and status = 'current'
     ) then
    raise exception 'cannot archive an event while a round is running';
  end if;
  return new;
end;
$$;

drop trigger if exists events_prevent_archiving_live on events;
create trigger events_prevent_archiving_live
  before update of archived_at on events
  for each row execute function prevent_archiving_live_event();
