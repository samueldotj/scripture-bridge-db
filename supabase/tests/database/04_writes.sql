-- Write RPCs: revision capture, workflow rules, idempotency
-- (R-TEST-3, DB §8, §9).
--
-- Each write needs its own Idempotency-Key, or the second call returns the
-- first's stored response instead of doing anything — which is the behaviour
-- under test in the idempotency section, and an invisible no-op everywhere
-- else.

begin;
\ir _helpers.psql
select no_plan();

select tests.create_user('alice');    -- assigned translator
select tests.create_user('bob');      -- assigned reviewer
select tests.create_user('carol');    -- member, assigned nothing
select tests.clear_password_gate('alice');
select tests.clear_password_gate('bob');
select tests.clear_password_gate('carol');

select tests.new_project('P1', 'MAT');
select tests.add_member((select id from app.project where name = 'P1'), 'alice', 'translator');
select tests.add_member((select id from app.project where name = 'P1'), 'bob',   'reviewer');
select tests.add_member((select id from app.project where name = 'P1'), 'carol', 'translator');

-- Assign chapter 1 only. Chapter 2 stays unassigned to test not_assigned.
update app.chapter c
   set assigned_translator_id = tests.profile_id('alice'),
       assigned_reviewer_id   = tests.profile_id('bob')
  from app.project p
 where p.id = c.project_id and p.name = 'P1' and c.number = 1;

-- Owned by the test role, so it is readable after `set local role
-- authenticated` only if granted. Without the grant every later assertion
-- fails on permissions rather than on what it is testing.
create view tests.v1 as
  select v.id from app.verse v join app.chapter c on c.id = v.chapter_id
    join app.project p on p.id = v.project_id
   where p.name = 'P1' and c.number = 1 and v.number = 1;

grant select on tests.v1 to authenticated;

-- ---------------------------------------------------------------------------
-- The core save (DB §8.1)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-k1"}', true);
set local role authenticated;

select is(
  (api.save_verse_text((select id from tests.v1), 'first text', 'autosave') ->> 'rev')::int,
  1, 'the first accepted write sets rev to 1');

select is(
  (select status from api.verse where id = (select id from tests.v1)),
  'draft', 'a verse with text moves from empty to draft');

-- APP §8.1: the first verse edited moves the chapter off not_started.
select is(
  (select workflow_state from api.chapter c
     join app.project p on p.id = c.project_id
    where p.name = 'P1' and c.number = 1),
  'in_progress', 'the first edit moves the chapter to in_progress');

select is((select count(*)::int from api.verse_revision
            where verse_id = (select id from tests.v1)),
          1, 'the first write to a verse always captures a revision');

-- R-FN-4: byte-identical text is a no-op. Without it the outbox re-sending a
-- collapsed write (APP R-OFF-5) inflates rev and pollutes history.
select set_config('request.headers', '{"idempotency-key": "test-key-k2"}', true);
select is(
  (api.save_verse_text((select id from tests.v1), 'first text', 'autosave') ->> 'rev')::int,
  1, 'an identical write does not increment rev');

select is((select count(*)::int from api.verse_revision
            where verse_id = (select id from tests.v1)),
          1, 'an identical write captures no revision');

-- R-FN-6 / §8.2 rule 1: an autosave soon after, by the same author, does not
-- capture. This is the rule that keeps history readable.
select set_config('request.headers', '{"idempotency-key": "test-key-k3"}', true);
select is(
  (api.save_verse_text((select id from tests.v1), 'second text', 'autosave')
     ->> 'revision_captured')::boolean,
  false, 'a prompt autosave by the same author captures no revision');

select is((select rev from api.verse where id = (select id from tests.v1)), 2,
          'but the write is still applied and rev advances');

-- Rule 1: an explicit save is a commit point.
select set_config('request.headers', '{"idempotency-key": "test-key-k4"}', true);
select is(
  (api.save_verse_text((select id from tests.v1), 'third text', 'explicit_save')
     ->> 'revision_captured')::boolean,
  true, 'an explicit save captures a revision');

-- R-TEXT-DB-2: non-NFC is rejected, not silently normalised.
--
-- The literal below is 'e' + U+0301 COMBINING ACUTE ACCENT (bytes 65 CC 81),
-- which is NFD. DO NOT "tidy" it by retyping the accented character: an editor
-- or keyboard will produce precomposed U+00E9 (bytes C3 A9), which is already
-- NFC, and the write would then succeed — leaving a test that passes while
-- asserting nothing. Verify with `od -c` after touching this line.
select set_config('request.headers', '{"idempotency-key": "test-key-k5"}', true);
select throws_ok(
  $$ select api.save_verse_text((select id from tests.v1), e'éclair', 'autosave') $$,
  'PT422', 'text_not_normalized',
  'decomposed text is rejected rather than normalised on write');

-- ---------------------------------------------------------------------------
-- Idempotency (R-TEST-3, DB §9)
-- ---------------------------------------------------------------------------

select set_config('request.headers', '{"idempotency-key": "test-key-replay"}', true);
select lives_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'replayed', 'explicit_save') $$,
  'first call with a fresh key performs the write');

select is((select rev from api.verse where id = (select id from tests.v1)), 4,
          'rev after the replayed write');

-- Same key, same body: returns the stored response and does nothing.
select lives_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'replayed', 'explicit_save') $$,
  'replaying the same key succeeds');

select is((select rev from api.verse where id = (select id from tests.v1)), 4,
          'a replayed key does not increment rev again');

select is((select count(*)::int from api.verse_revision
            where verse_id = (select id from tests.v1) and text = 'replayed'),
          1, 'a replayed key creates no second revision (APP R-OFF-4)');

-- R-IDEM-3: same key, different body.
select throws_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'different', 'explicit_save') $$,
  'PT409', 'idempotency_key_reuse',
  'reusing a key for a different request is refused rather than answered');

-- R-IDEM-6: no key at all.
select set_config('request.headers', '{}', true);
select throws_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'keyless', 'autosave') $$,
  'PT400', 'idempotency_key_required',
  'a write without an idempotency key is refused');

reset role;

-- ---------------------------------------------------------------------------
-- Authorisation on writes (R-RLS-12)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('carol'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-carol-1"}', true);
set local role authenticated;

select throws_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'not mine', 'autosave') $$,
  'PT403', 'not_assigned',
  'a project member who is not assigned the chapter cannot write to it');

reset role;

-- ---------------------------------------------------------------------------
-- Workflow rules (R-FN-11, R-FN-13)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-submit-1"}', true);
set local role authenticated;

-- R-WF-1: 1,070 of the 1,071 verses are still empty.
select throws_ok(
  $$ select api.submit_chapter(
       (select c.id from app.chapter c join app.project p on p.id = c.project_id
         where p.name = 'P1' and c.number = 1)) $$,
  'PT422', 'chapter_not_ready',
  'a chapter with empty verses cannot be submitted');

reset role;

-- Fill the chapter so submission can proceed.
update app.verse v
   set text = 'filled', status = 'draft'
  from app.chapter c, app.project p
 where c.id = v.chapter_id and p.id = v.project_id
   and p.name = 'P1' and c.number = 1 and v.text = '';

select set_config('request.jwt.claims', tests.jwt('alice'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-submit-2"}', true);
set local role authenticated;

select is(
  (api.submit_chapter((select c.id from app.chapter c
     join app.project p on p.id = c.project_id
    where p.name = 'P1' and c.number = 1)) ->> 'workflow_state'),
  'in_review', 'a complete chapter submits to in_review');

-- R-FN-13: submitting again is a typed error, not a silent no-op. An offline
-- client acting on stale state lands here.
select set_config('request.headers', '{"idempotency-key": "test-key-submit-3"}', true);
select throws_ok(
  $$ select api.submit_chapter(
       (select c.id from app.chapter c join app.project p on p.id = c.project_id
         where p.name = 'P1' and c.number = 1)) $$,
  'PT409', 'invalid_transition',
  'submitting an already-submitted chapter is refused with a typed error');

reset role;

-- ---------------------------------------------------------------------------
-- Review: flags block approval (R-WF-2, R-REVIEW-2)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('bob'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-flag-0"}', true);
set local role authenticated;

select throws_ok(
  $$ select api.flag_verse((select id from tests.v1), '  ') $$,
  'PT422', 'comment_required',
  'flagging without a comment is refused (a reviewer must say why)');

select set_config('request.headers', '{"idempotency-key": "test-key-flag-1"}', true);
select lives_ok(
  $$ select api.flag_verse((select id from tests.v1), 'Consider a clearer word.') $$,
  'a reviewer can flag a verse with a comment');

select is((select status from api.verse where id = (select id from tests.v1)),
          'flagged', 'flagging sets the verse status');

select set_config('request.headers', '{"idempotency-key": "test-key-approve-1"}', true);
select throws_ok(
  $$ select api.review_chapter(
       (select c.id from app.chapter c join app.project p on p.id = c.project_id
         where p.name = 'P1' and c.number = 1), 'approve') $$,
  'PT422', 'chapter_has_flags',
  'a chapter with flagged verses cannot be approved');

-- Return it instead.
select set_config('request.headers', '{"idempotency-key": "test-key-return-1"}', true);
select is(
  (api.review_chapter((select c.id from app.chapter c
     join app.project p on p.id = c.project_id
    where p.name = 'P1' and c.number = 1), 'return', 'needs work') ->> 'workflow_state'),
  'in_progress',
  'a returned chapter goes back to in_progress, not a separate state');

reset role;

-- ---------------------------------------------------------------------------
-- Resolving a flag, and restore (R-REVIEW-3, R-REV-5)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-resolve-1"}', true);
set local role authenticated;

select lives_ok(
  $$ select api.resolve_comment(
       (select id from api.comment where verse_id = (select id from tests.v1)
         order by created_at limit 1)) $$,
  'the translator resolves the reviewer''s comment');

select is((select status from api.verse where id = (select id from tests.v1)),
          'draft',
          'resolving the last comment clears the flag back to draft, not done');

-- R-REV-5: restore is forward-only. The counter is never rewound and no
-- revision is removed.
select set_config('request.headers', '{"idempotency-key": "test-key-restore-1"}', true);
select is(
  (api.restore_revision(
     (select id from tests.v1),
     (select id from api.verse_revision
       where verse_id = (select id from tests.v1) order by rev limit 1)) ->> 'text'),
  'first text',
  'restoring the first revision brings its text back');

select ok(
  (select rev from api.verse where id = (select id from tests.v1)) > 4,
  'restore advances the counter rather than rewinding it');

select ok(
  (select restored_from_revision_id is not null from api.verse_revision
    where verse_id = (select id from tests.v1) order by rev desc limit 1),
  'the restoring revision records what it was restored from');

reset role;

select * from finish();
rollback;
