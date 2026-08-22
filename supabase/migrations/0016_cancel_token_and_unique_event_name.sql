-- Two fixes from the 2026-08-19 QA pass.
--
-- ── 1. Bookings were impossible to create in production ──────────────────
--
-- 0015 gave bookings.cancel_token a default of new_cancel_token(), whose
-- body called gen_random_bytes() — a pgcrypto function. 0001 does enable
-- pgcrypto, so this worked locally, where `create extension` installs into
-- `public`. Supabase installs extensions into a separate `extensions`
-- schema instead, and every security-definer function here pins
-- `set search_path = public`. So:
--
--   * At migration time the statement ran fine, because the SQL editor's
--     own connection has `extensions` on its search_path. Nothing looked
--     wrong, and the post-apply checks passed.
--   * At run time, inserting a booking evaluates the column default inside
--     book_seats()/host_assign_seats(), whose search_path is `public`
--     alone. new_cancel_token() carried no search_path of its own, so it
--     inherited that one, and gen_random_bytes resolved to nothing.
--
-- The result was 42883 on *every* booking — guest self-service through
-- book_seats() as much as host assignment, since both insert into bookings.
--
-- The fix is to stop depending on an extension at all. gen_random_uuid() is
-- core Postgres (pg_catalog) as of 13, so it resolves under any search_path
-- whatsoever; two of them concatenated, minus the dashes, give the same
-- 32-character URL-safe shape the token already had. A v4 UUID carries 122
-- bits of CSPRNG-backed randomness, so halving that to 16 bytes of hex here
-- still leaves a token far past guessing.
--
-- The function is also pinned to `set search_path = pg_catalog` so it can
-- never again inherit a caller's idea of where its functions live.

create or replace function new_cancel_token() returns text
language sql volatile
set search_path = pg_catalog
as $$
  select substr(replace(gen_random_uuid()::text, '-', '') ||
                replace(gen_random_uuid()::text, '-', ''), 1, 32);
$$;

revoke all on function new_cancel_token() from public, anon, authenticated;

-- Any booking created between 0015 and this migration failed outright, so
-- there should be nothing to repair — but a null token would silently break
-- that guest's cancel link, so make sure of it.
update bookings set cancel_token = new_cancel_token() where cancel_token is null;

-- ── 2. One host cannot reuse an event name ───────────────────────────────
--
-- Event pickers show the name alone, so a caterer with two events called
-- "Marriage" has no way to tell which is which — and picking the wrong one
-- means designing a floor or starting a round on the wrong event. Scoped to
-- the caterer, not global: two different caterers both running a "Reception"
-- is normal and none of each other's business.
--
-- Compared case-insensitively and ignoring surrounding whitespace, since
-- "Marriage" and "marriage " are exactly as confusing as an exact repeat.

-- Trim first. The index compares on btrim(), so " Marriage " and "Marriage"
-- are already one name as far as the constraint is concerned — but leaving
-- the padding in the stored value means the host sees a name with invisible
-- whitespace they cannot edit away by eye, and the rename below would build
-- on top of it.
update events set name = btrim(name) where name <> btrim(name);

-- Existing duplicates have to go before the index can exist. Renaming rather
-- than deleting: the host can tidy the names afterwards, and an event owns
-- floor layout, menu and bookings that must not be destroyed to satisfy a
-- constraint. Loops because a generated name can itself collide with one
-- already in the table ("A" and "A (2)" both present); each pass makes names
-- strictly longer, so it terminates.
do $$
declare
  v_renamed int;
begin
  loop
    with ranked as (
      select id,
             row_number() over (
               partition by caterer_id, lower(btrim(name))
               order by created_at, id
             ) as rn
        from events
    )
    update events e
       set name = e.name || ' (' || r.rn || ')'
      from ranked r
     where r.id = e.id
       and r.rn > 1;

    get diagnostics v_renamed = row_count;
    exit when v_renamed = 0;
  end loop;
end
$$;

create unique index events_caterer_name_uidx on events (caterer_id, lower(btrim(name)));
