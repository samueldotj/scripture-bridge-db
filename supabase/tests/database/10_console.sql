-- The console API (DB §13.6, R-AUTH-DB-12, R-FN-14).
--
-- These functions carry the operations no app user may perform. The most
-- important assertions here are the negative ones: that a signed-in project
-- admin cannot reach any of them. An admin who can reassign chapters or reopen
-- approved work through the app's own API is an escalation, and it would look
-- like a feature rather than a hole.

begin;
\ir _helpers.psql
select no_plan();

select tests.create_user('alice');
select tests.create_user('bob');
select tests.create_user('outsider');
select tests.clear_password_gate('alice');
select tests.clear_password_gate('bob');
select tests.clear_password_gate('outsider');

-- ---------------------------------------------------------------------------
-- Project creation
-- ---------------------------------------------------------------------------

select is(
  (api.create_project('Console Project', 'Test Language', 'xx', 'Latn',
                      'eng', 'ltr', array['MAT'], 'coordinator@example.test')
   ->> 'books_materialised')::int,
  1, 'create_project materialises the books it is given');

select is(
  (select count(*)::int from app.verse v
     join app.project p on p.id = v.project_id
    where p.name = 'Console Project'),
  1071, 'and the project is fully materialised, not an empty shell');

select throws_ok(
  $$ select api.create_project('Bad Scheme', 'L', 'xx', 'Latn', 'nonexistent') $$,
  'PT400', 'invalid_argument',
  'an unknown versification scheme is refused rather than stored');

-- A scheme with no data must fail loudly: the alternative is a project whose
-- verse counts are silently wrong, discovered at export (R-DATA-2).
select throws_ok(
  $$ select api.create_project('Org Scheme', 'L', 'xx', 'Latn', 'org', 'ltr', array['MAT']) $$,
  'PT422', 'versification_missing',
  'a scheme with no versification data cannot be used to create a project');

-- ---------------------------------------------------------------------------
-- Membership and assignment
-- ---------------------------------------------------------------------------

create view tests.proj as select id from app.project where name = 'Console Project';
create view tests.ch1 as
  select c.id from app.chapter c
   where c.project_id = (select id from app.project where name = 'Console Project')
     and c.number = 1;
grant select on tests.proj, tests.ch1 to authenticated;

select is(
  api.add_project_member((select id from tests.proj), tests.profile_id('alice'),
                         'translator', 'coordinator@example.test') ->> 'role',
  'translator', 'a member can be added');

select is(
  api.add_project_member((select id from tests.proj), tests.profile_id('alice'),
                         'admin', 'coordinator@example.test') ->> 'previous_role',
  'translator', 'and re-adding updates the role, reporting what it was');

select is(
  api.add_project_member((select id from tests.proj), tests.profile_id('bob'),
                         'reviewer', 'coordinator@example.test') ->> 'role',
  'reviewer', 'a reviewer can be added');

-- Assigning a non-member produces a chapter whose assignee cannot read it: the
-- app shows them nothing and the refusal looks like a bug, not a mis-assignment.
select throws_ok(
  format($$ select api.assign_chapter(%L, %L) $$,
         (select id from tests.ch1), tests.profile_id('outsider')),
  'PT400', 'invalid_argument',
  'assigning someone who is not a project member is refused');

select is(
  api.assign_chapter((select id from tests.ch1), tests.profile_id('alice'),
                     tests.profile_id('bob'), 'coordinator@example.test')
    ->> 'workflow_state',
  'not_started', 'assignment does not disturb the workflow state');

-- The raw-SQL version wrote no change-log entry, so an assignment never reached
-- the device: delta sync is the only way the app learns anything changed.
select is(
  (select count(*)::int from app.change_log
    where project_id = (select id from tests.proj)
      and entity_id = (select id from tests.ch1)),
  1, 'assignment writes a change-log entry so it reaches the translator''s device');

-- ---------------------------------------------------------------------------
-- Reopen (R-FN-14)
-- ---------------------------------------------------------------------------

select throws_ok(
  format($$ select api.reopen_chapter(%L) $$, (select id from tests.ch1)),
  'PT409', 'invalid_transition',
  'a chapter that is not approved cannot be reopened');

update app.chapter
   set workflow_state = 'approved', approved_at = now(),
       approved_by_id = tests.profile_id('bob')
 where id = (select id from tests.ch1);

select is(
  api.reopen_chapter((select id from tests.ch1), 'approved by mistake',
                     'coordinator@example.test') ->> 'workflow_state',
  'in_progress', 'an approved chapter can be reopened, which is the only way back');

select is(
  (select approved_at from app.chapter where id = (select id from tests.ch1)),
  null, 'and the approval is cleared rather than left behind');

-- ---------------------------------------------------------------------------
-- Audit (R-AUTH-DB-12)
-- ---------------------------------------------------------------------------

select is(
  (select actor_label from app.audit_log
    where action = 'chapter.reopen' order by occurred_at desc limit 1),
  'coordinator@example.test',
  'the operator is recorded, not merely that "a console" did it');

select is(
  (select actor_kind from app.audit_log
    where action = 'chapter.reopen' order by occurred_at desc limit 1),
  'console', 'as a console action rather than a user action');

select ok(
  (select before is not null and after is not null from app.audit_log
    where action = 'chapter.reopen' order by occurred_at desc limit 1),
  'with before and after state');

-- ---------------------------------------------------------------------------
-- No app user may reach any of this
--
-- The point of the whole file. A project admin is the most privileged app user
-- there is; if these are reachable at all, they are reachable by them.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

select throws_ok(
  format($$ select api.reopen_chapter(%L) $$, (select id from tests.ch1)),
  '42501', NULL,
  'a project admin cannot reopen a chapter through the app API');

select throws_ok(
  format($$ select api.assign_chapter(%L, %L) $$,
         (select id from tests.ch1), tests.profile_id('alice')),
  '42501', NULL,
  'nor reassign one');

select throws_ok(
  $$ select api.create_project('Sneaky', 'L', 'xx', 'Latn') $$,
  '42501', NULL,
  'nor create a project');

select throws_ok(
  format($$ select api.rearm_password_change(%L) $$, tests.profile_id('bob')),
  '42501', NULL,
  'nor force a colleague''s password to be reset');

reset role;

select * from finish();
rollback;
