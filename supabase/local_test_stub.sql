-- Stub of the Supabase-managed surface the migrations assume already exists.
--
-- Normally provided by the Supabase platform (GoTrue, its role setup), never
-- by app migrations — so the migrations rightly don't create any of it, and a
-- bare Postgres has none of it. This is just enough for them to have
-- something real to reference when testing locally.
--
-- Lived in a scratch directory until it had been silently deleted by /tmp
-- cleanup three times, taking an hour of rediscovery with it each time. It is
-- test scaffolding, not app schema: never apply it to a real project.
--
-- Usage (see CLAUDE.md → Local Postgres testing):
--
--   createdb cater_test
--   psql -d cater_test -c 'create schema extensions;
--                          create extension pgcrypto with schema extensions;'
--   psql -d cater_test -f supabase/local_test_stub.sql
--   for f in supabase/migrations/*.sql; do
--     PGOPTIONS='-c search_path=public,extensions' psql -d cater_test -f "$f"
--   done
--
-- The `extensions` schema and the search_path matter: Supabase installs
-- extensions there rather than in `public`, and reproducing that is what
-- catches the class of bug that broke every booking in production once.

create schema if not exists auth;

create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  created_at timestamptz not null default now()
);

-- Real auth.uid() reads a JWT claim via current_setting(); this reads a
-- session-local var instead, so a test can say "now I am user X":
--
--   set session authorization authenticated;
--   set request.jwt.claim.sub = '<uuid>';
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  -- The identity edge functions use. Real Supabase gives it BYPASSRLS, which
  -- is why the reminder sender can read its queue without a policy for it.
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

grant usage on schema auth to authenticated, anon, service_role;
grant select on auth.users to authenticated, anon, service_role;

-- Real Supabase provisions these roles with broad table-level grants on
-- `public` up front — RLS policies are the actual gatekeeper. App migrations
-- never declare them because they already exist. Replicating that here is
-- what makes access fail (or succeed) on RLS rather than a missing GRANT,
-- and is also what proves `revoke ... from public` alone does not lock an
-- RPC down.
grant usage on schema public to authenticated, anon, service_role;
alter default privileges in schema public grant all on tables to authenticated, anon, service_role;
alter default privileges in schema public grant all on sequences to authenticated, anon, service_role;
alter default privileges in schema public grant execute on functions to authenticated, anon, service_role;
