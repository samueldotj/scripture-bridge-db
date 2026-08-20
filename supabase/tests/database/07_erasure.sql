-- Erasure must not destroy translation history (APP R-LEGAL-2, R-COMPLY-2).
--
-- This is the test the profile indirection exists for. Content tables reference
-- app.profile rather than auth.users precisely so that deleting a person's
-- sign-in identity cannot cascade into their work (R-DATA-4). Until now that
-- was a design claim; here it is exercised.
--
-- It also closes DB 17 #10: confirm nothing Supabase manages cascades from an
-- auth.users deletion into data this schema depends on.

begin;
\ir _helpers.psql
select no_plan();

select tests.create_user('alice');     -- will be erased
select tests.create_user('bob');       -- reviewer, stays
select tests.clear_password_gate('alice');
select tests.clear_password_gate('bob');

select tests.new_project('P1', 'MAT');
select tests.add_member((select id from app.project where name = 'P1'), 'alice', 'translator');
select tests.add_member((select id from app.project where name = 'P1'), 'bob',   'reviewer');

update app.chapter c
   set assigned_translator_id = tests.profile_id('alice'),
       assigned_reviewer_id   = tests.profile_id('bob')
  from app.project p
 where p.id = c.project_id and p.name = 'P1' and c.number = 1;

create view tests.v1 as
  select v.id from app.verse v join app.chapter c on c.id = v.chapter_id
    join app.project p on p.id = v.project_id
   where p.name = 'P1' and c.number = 1 and v.number = 1;
grant select on tests.v1 to authenticated;

-- Alice does some work: text, a revision, and a comment.
select set_config('request.jwt.claims', tests.jwt('alice'), true);
select set_config('request.headers', '{"idempotency-key": "erase-key-0001"}', true);
set local role authenticated;

select lives_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'alice wrote this', 'explicit_save') $$,
  'the translator does some work before being erased');

select set_config('request.headers', '{"idempotency-key": "erase-key-0002"}', true);
select lives_ok(
  $$ select api.add_comment((select id from tests.v1), 'a note from alice') $$,
  'and leaves a comment');

reset role;

-- Capture what must survive.
create table tests.before as
  select tests.profile_id('alice')                                        as profile_id,
         (select id from tests.ids where name = 'alice')                  as auth_user_id,
         (select count(*) from app.verse_revision
           where author_id = tests.profile_id('alice'))::int              as revisions,
         (select count(*) from app.comment
           where author_id = tests.profile_id('alice'))::int              as comments,
         (select text from app.verse where id = (select id from tests.v1)) as verse_text;

select ok((select revisions from tests.before) >= 1, 'alice authored at least one revision');
select ok((select comments  from tests.before) >= 1, 'alice authored at least one comment');

-- ---------------------------------------------------------------------------
-- Erase
-- ---------------------------------------------------------------------------

select is(
  (api.anonymise_profile((select profile_id from tests.before)) ->> 'already')::boolean,
  false, 'anonymising a live profile reports it was not already done');

-- ---------------------------------------------------------------------------
-- What must be gone
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from auth.users where id = (select auth_user_id from tests.before)),
  0, 'the sign-in identity is deleted');

select is(
  (select display_name from app.profile where id = (select profile_id from tests.before)),
  null, 'the display name is erased');

select isnt(
  (select anonymised_at from app.profile where id = (select profile_id from tests.before)),
  null, 'the profile is tombstoned rather than deleted');

select is(
  (select auth_user_id from app.profile where id = (select profile_id from tests.before)),
  null, 'the link to the deleted auth user is nulled, not cascaded');

-- ---------------------------------------------------------------------------
-- What must survive - the point of the whole exercise
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from app.verse_revision
    where author_id = (select profile_id from tests.before)),
  (select revisions from tests.before),
  'every revision alice authored survives, still attributed to her profile');

select is(
  (select count(*)::int from app.comment
    where author_id = (select profile_id from tests.before)),
  (select comments from tests.before),
  'her comments survive');

select is(
  (select text from app.verse where id = (select id from tests.v1)),
  (select verse_text from tests.before),
  'the translated text is untouched');

select is(
  (select text from app.verse_revision
    where author_id = (select profile_id from tests.before) order by rev limit 1),
  'alice wrote this', 'the revision still carries its text');

-- R-DATA-5: views must not filter tombstoned authors out. A missing author is
-- worse than a tombstoned one - the app renders "Former contributor", and it
-- can only do that if the row still arrives with a null name.
select set_config('request.jwt.claims', tests.jwt('bob'), true);
set local role authenticated;

select is(
  (select count(*)::int from api.verse_revision
    where verse_id = (select id from tests.v1)),
  (select revisions from tests.before),
  'the revision is still returned by the API after erasure');

select is(
  (select author_name from api.verse_revision
    where verse_id = (select id from tests.v1) order by rev limit 1),
  null, 'it arrives with a null author name for the app to render as "Former contributor"');

select isnt(
  (select author_id from api.verse_revision
    where verse_id = (select id from tests.v1) order by rev limit 1),
  null, 'the author id is retained, so distinct former contributors stay distinct');

reset role;

-- ---------------------------------------------------------------------------
-- Repeatability and audit
-- ---------------------------------------------------------------------------

select is(
  (api.anonymise_profile((select profile_id from tests.before)) ->> 'already')::boolean,
  true, 'anonymising again is idempotent rather than an error');

select is(
  (select count(*)::int from app.audit_log
    where action = 'profile.anonymise'
      and target_id = (select profile_id from tests.before)),
  1, 'the erasure is audited exactly once');

select is_empty(
  $$ select 1 from app.audit_log where action = 'profile.anonymise'
      and after::text like '%alice%' $$,
  'the audit entry does not record the name being erased');

select * from finish();
rollback;
