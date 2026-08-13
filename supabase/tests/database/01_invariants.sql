-- Structural invariants (R-TEST-6).
--
-- These are the checks that catch the two highest-severity mistakes available
-- in this design: a table that reaches production without RLS, and a
-- SECURITY DEFINER function without a pinned search_path. Both are mechanical,
-- both are silent, and both are why this file runs first.

begin;
\ir ../helpers.sql
select no_plan();

-- ---------------------------------------------------------------------------
-- R-RLS-1: every table in app and ref has RLS enabled AND forced.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select n.nspname || '.' || c.relname
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname in ('app', 'ref') and c.relkind = 'r'
        and not (c.relrowsecurity and c.relforcerowsecurity) $$,
  'every table in app and ref has row level security enabled and forced');

-- ---------------------------------------------------------------------------
-- R-RLS-5: authenticated holds NO write privilege on any table, anywhere.
-- This is what makes "all writes go through RPCs" true rather than intended.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select table_schema || '.' || table_name || ' ' || privilege_type
       from information_schema.role_table_grants
      where grantee = 'authenticated'
        and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE') $$,
  'authenticated has no INSERT/UPDATE/DELETE/TRUNCATE on any table');

-- ---------------------------------------------------------------------------
-- R-RLS-2: anon reaches nothing.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select table_schema || '.' || table_name
       from information_schema.role_table_grants
      where grantee = 'anon' and table_schema in ('app', 'api', 'ref') $$,
  'anon has no table or view privileges in app, api, or ref');

-- ---------------------------------------------------------------------------
-- R-RLS-7: every SECURITY DEFINER function pins search_path.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select n.nspname || '.' || p.proname
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('app', 'api')
        and p.prosecdef
        and not exists (
          select 1 from unnest(coalesce(p.proconfig, '{}')) cfg
           where cfg like 'search_path=%') $$,
  'every SECURITY DEFINER function in app and api pins search_path');

-- ---------------------------------------------------------------------------
-- R-RLS-13: every api view is security_invoker.
--
-- Without it a view runs as its owner and returns every row to every caller —
-- a hole straight through the policies.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select c.relname
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'api' and c.relkind = 'v'
        and not coalesce(
              (select option_value::boolean
                 from pg_options_to_table(c.reloptions)
                where option_name = 'security_invoker'), false) $$,
  'every view in api is security_invoker');

-- ---------------------------------------------------------------------------
-- The write RPCs can only write to FORCE-RLS tables because their owner
-- bypasses RLS. This assumption is documented in migration 0007; here it is
-- asserted, because if it stops holding every write fails at once.
-- ---------------------------------------------------------------------------

select ok(
  (select r.rolsuper or r.rolbypassrls
     from pg_proc p
     join pg_roles r on r.oid = p.proowner
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = 'save_verse_text'),
  'the owner of api.save_verse_text can bypass RLS');

-- ---------------------------------------------------------------------------
-- R-SCHEMA-3: public stays empty, so anything landing there is visible.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select c.relname
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'v', 'm') $$,
  'the public schema contains no tables or views');

-- ---------------------------------------------------------------------------
-- Append-only guards (R-FN-9, R-AUDIT-2), and the deliberate exception:
-- change_log must permit DELETE or retention is impossible.
-- ---------------------------------------------------------------------------

select ok(
  exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
           where c.relname = 'verse_revision' and not t.tgisinternal),
  'app.verse_revision has an append-only trigger');

select ok(
  not exists (
    select 1 from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
     where c.relname = 'change_log' and not t.tgisinternal
       and (t.tgtype & 8) <> 0),          -- 8 = DELETE
  'app.change_log does NOT block DELETE, so pruning can run');

select * from finish();
rollback;
