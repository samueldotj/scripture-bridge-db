-- RLS policy tests (R-TEST-1).
--
-- Every policy needs a NEGATIVE test. Policies are the entire authorisation
-- model (R-RLS-4), so an untested policy is untested authorisation — and a
-- policy bug looks exactly like working software until the wrong person reads
-- the wrong project.
--
-- Note the role switching is done with bare statements, not helpers: Postgres
-- undoes SET performed inside a function at function exit, which would leave
-- these tests running as the owner and passing while asserting nothing.

begin;
\ir ../helpers.sql
select no_plan();

-- ---------------------------------------------------------------------------
-- Fixture: two projects with no overlap, plus a user still behind the
-- password gate.
-- ---------------------------------------------------------------------------

select tests.create_user('alice');     -- translator on P1
select tests.create_user('bob');       -- reviewer on P1
select tests.create_user('mallory');   -- member of P2 only
select tests.create_user('newbie');    -- member of P1, password not yet changed

select tests.clear_password_gate('alice');
select tests.clear_password_gate('bob');
select tests.clear_password_gate('mallory');
-- newbie deliberately left gated.

select tests.new_project('P1', 'MAT');
select tests.new_project('P2', 'MAT');

select tests.add_member((select id from app.project where name = 'P1'), 'alice',   'translator');
select tests.add_member((select id from app.project where name = 'P1'), 'bob',     'reviewer');
select tests.add_member((select id from app.project where name = 'P1'), 'newbie',  'translator');
select tests.add_member((select id from app.project where name = 'P2'), 'mallory', 'translator');

-- ---------------------------------------------------------------------------
-- A member reads their own project in full (R-RLS-11)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

select is((select count(*)::int from api.project), 1,
          'alice sees exactly one project');

select is((select name from api.project), 'P1',
          'alice sees P1');

select is((select my_role from api.project), 'translator',
          'api.project reports the caller''s role');

select is((select count(*)::int from api.verse), 1071,
          'a translator reads every verse in the project, not only assigned chapters');

reset role;

-- ---------------------------------------------------------------------------
-- A non-member sees nothing — the core negative test
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('mallory'), true);
set local role authenticated;

select is((select count(*)::int from api.verse v
             join app.project p on p.id = v.project_id where p.name = 'P1'),
          0, 'mallory cannot read any verse of P1');

select is((select count(*)::int from api.project where name = 'P1'), 0,
          'mallory cannot see P1 at all');

select is((select count(*)::int from api.chapter c
             join app.project p on p.id = c.project_id where p.name = 'P1'),
          0, 'mallory cannot read P1 chapters');

-- Membership of P2 is real, so this is not a test that passes because the
-- fixture is empty.
select is((select count(*)::int from api.project where name = 'P2'), 1,
          'mallory does see her own project');

reset role;

-- ---------------------------------------------------------------------------
-- The forced password change gates project data (R-AUTH-DB-8)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('newbie'), true);
set local role authenticated;

select is((select count(*)::int from api.project), 0,
          'a user behind the password gate sees no projects despite membership');

select is((select count(*)::int from api.verse), 0,
          'a user behind the password gate sees no verses');

-- ...but can still read their own identity, or the app cannot tell them to
-- change their password.
select is((api.me() ->> 'must_change_password')::boolean, true,
          'rpc/me still reports the flag while gated');

select is(jsonb_array_length(api.me() -> 'projects'), 0,
          'rpc/me withholds projects while gated');

reset role;

-- ---------------------------------------------------------------------------
-- No client write path exists (R-RLS-5)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

-- The four-argument form is used throughout: throws_ok(sql, errcode, errmsg,
-- description). A NULL errmsg skips the message check, which matters here
-- because permission-denied wording is not stable across versions. The
-- three-argument form is ambiguous between (sql, errcode, errmsg) and
-- (sql, errmsg, description), so it is avoided everywhere.
select throws_ok(
  $$ update app.verse set text = 'direct write' where number = 1 $$,
  '42501', NULL,
  'a client cannot write to app.verse directly');

select throws_ok(
  $$ insert into app.verse_revision (verse_id, project_id, rev, text)
     values (gen_random_uuid(), gen_random_uuid(), 1, 'forged') $$,
  '42501', NULL,
  'a client cannot forge revision history');

select throws_ok(
  $$ update app.project_member set role = 'admin' $$,
  '42501', NULL,
  'a client cannot escalate their own role');

reset role;

-- ---------------------------------------------------------------------------
-- Revisions are immutable even to the owner (R-FN-9)
--
-- Grants stop the client; the trigger is what stops a future migration or a
-- service-key script, which is the case that actually threatens history.
-- ---------------------------------------------------------------------------

insert into app.verse_revision (verse_id, project_id, rev, text, author_id)
select v.id, v.project_id, 1, 'original', tests.profile_id('alice')
  from app.verse v join app.project p on p.id = v.project_id
 where p.name = 'P1' limit 1;

select throws_ok(
  $$ update app.verse_revision set text = 'rewritten' $$,
  'PT409', 'append_only_table',
  'revision history cannot be rewritten, even by the owner');

select throws_ok(
  $$ delete from app.verse_revision $$,
  'PT409', 'append_only_table',
  'revision history cannot be deleted, even by the owner');

select * from finish();
rollback;
