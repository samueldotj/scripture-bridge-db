-- Statement timeout and font storage (R-API-DB-5, R-STORE-1/2).
--
-- Both are configuration rather than schema, and configuration is exactly what
-- drifts silently: nothing in ordinary use notices a missing timeout until one
-- pathological query degrades the API for everyone on the instance.

begin;
\ir _helpers.psql
select no_plan();

-- ---------------------------------------------------------------------------
-- Statement timeout (R-API-DB-5)
--
-- Asserted rather than assumed because the mechanism is subtle: PostgREST
-- connects as `authenticator` and assumes `authenticated` with SET ROLE, so
-- whether a per-role setting takes effect depends on Postgres applying role
-- GUCs on role assumption and not only at login. If it does not, this fails
-- here rather than silently leaving the API unbounded.
-- ---------------------------------------------------------------------------

select is(
  (select setting from pg_db_role_setting s
     join pg_roles r on r.oid = s.setrole
    cross join lateral unnest(s.setconfig) as setting
    where r.rolname = 'authenticated' and setting like 'statement_timeout=%'),
  'statement_timeout=8s',
  'the authenticated role carries a statement timeout');

select ok(
  exists (
    select 1 from pg_db_role_setting s
      join pg_roles r on r.oid = s.setrole
     cross join lateral unnest(s.setconfig) as setting
     where r.rolname = 'anon' and setting like 'statement_timeout=%'),
  'the anon role carries one too');

-- The catalogue assertions above only prove the setting is RECORDED on the
-- role. What matters is whether it takes EFFECT the way PostgREST arrives:
-- connected as `authenticator`, then assuming `authenticated` via SET ROLE.
-- Per-role settings are documented as applied at login, so if Postgres did not
-- also apply them on assumption the API would be silently unbounded while the
-- catalogue looked correctly configured.
set local role authenticated;

select is(current_setting('statement_timeout'), '8s',
          'and the timeout actually takes effect when the role is assumed, which is how PostgREST arrives');

reset role;

-- ---------------------------------------------------------------------------
-- Font storage (R-STORE-1/2)
--
-- Skipped where the storage schema is absent, which is the database-only CI
-- job. The e2e job runs the full stack and exercises it.
-- ---------------------------------------------------------------------------

create function tests.storage_present() returns boolean
language sql as $$ select to_regclass('storage.buckets') is not null $$;

select case when tests.storage_present()
  then ok((select not public from storage.buckets where id = 'fonts'),
          'the fonts bucket exists and is private')
  else pass('storage schema absent; font bucket assertions skipped')
end;

select case when tests.storage_present()
  then ok(exists (select 1 from pg_policies
                   where schemaname = 'storage' and tablename = 'objects'
                     and policyname = 'fonts_readable_by_project_members'),
          'members of a project referencing the font can read it')
  else pass('storage schema absent; font policy assertions skipped')
end;

-- R-STORE-2: the app verifies the hash it was given, so it must never be able
-- to replace the object it is checking. No write policy may exist for
-- `authenticated` on the fonts bucket.
select case when tests.storage_present()
  then is((select count(*)::int from pg_policies
            where schemaname = 'storage' and tablename = 'objects'
              and cmd in ('INSERT', 'UPDATE', 'DELETE')
              and 'authenticated' = any(roles)
              and qual like '%fonts%'),
          0, 'no write policy lets a client replace a font asset')
  else pass('storage schema absent; font write assertions skipped')
end;

-- ---------------------------------------------------------------------------
-- The font metadata table backs the integrity check the app performs.
-- ---------------------------------------------------------------------------

select has_column('app', 'font', 'sha256', 'app.font records a hash for the app to verify');

select throws_ok(
  $$ insert into app.font (name, script_code, storage_path, file_size_bytes,
                           sha256, license, version)
     values ('Bad', 'Latn', 'fonts/bad.ttf', 1, 'not-a-hash', 'OFL', '1.0') $$,
  '23514', NULL,
  'a malformed hash is rejected, so the app cannot be handed an unverifiable font');

select * from finish();
rollback;
