-- Counter reconciliation and retention jobs (R-PERF-4, R-IDEM-5, R-SYNC-6/7,
-- R-OPS-6/7).
--
-- These paths run on a schedule, months apart from the code that depends on
-- them. A pruning job that silently stops presents much later as a table that
-- grew without bound or a cursor that never expires; drifted counters present
-- as a chapter approved on a stale count. Neither is visible in ordinary use,
-- so neither has any coverage except here.

begin;
\ir _helpers.psql
select no_plan();

select tests.create_user('alice');
select tests.clear_password_gate('alice');
select tests.new_project('P1', 'MAT');
select tests.add_member((select id from app.project where name = 'P1'), 'alice', 'translator');

create view tests.p1 as select id from app.project where name = 'P1';
grant select on tests.p1 to authenticated;

-- ---------------------------------------------------------------------------
-- Counter reconciliation (R-PERF-4)
--
-- Counters are trigger-maintained denormalisation (R-PERF-2). Drift is not a
-- question of if but of whether it is detectable.
-- ---------------------------------------------------------------------------

select is_empty(
  $$ select chapter_id::text from app.reconcile_chapter_counters(false) $$,
  'a freshly materialised project reconciles with zero drift');

-- Corrupt one counter behind the trigger's back, the way a bad migration or a
-- service-key script would.
update app.chapter c
   set verses_empty = c.verses_empty - 5
  from app.project p
 where p.id = c.project_id and p.name = 'P1' and c.number = 1;

select isnt_empty(
  $$ select chapter_id::text from app.reconcile_chapter_counters(false) $$,
  'reconciliation detects a counter that disagrees with the verse rows');

select is(
  (select column_name from app.reconcile_chapter_counters(false) limit 1),
  'verses_empty', 'it names the column that drifted');

select is_empty(
  $$ select chapter_id::text from app.reconcile_chapter_counters(true) $$,
  'reconciliation with p_fix repairs the drift and reports none remaining');

select is(
  (select c.verses_empty from app.chapter c
     join app.project p on p.id = c.project_id
    where p.name = 'P1' and c.number = 1),
  25, 'the repaired counter matches the chapter''s verse count again');

-- ---------------------------------------------------------------------------
-- Idempotency-key retention (R-IDEM-5)
--
-- The window must comfortably exceed the longest realistic offline period for
-- a queued write (APP §2.3).
-- ---------------------------------------------------------------------------

insert into app.idempotency_key (profile_id, key, operation, request_hash, response, created_at)
values (tests.profile_id('alice'), 'old-key-000001', 'save_verse_text', 'hash', '{}'::jsonb,
        now() - interval '30 days'),
       (tests.profile_id('alice'), 'new-key-000001', 'save_verse_text', 'hash', '{}'::jsonb,
        now());

select is((select app.prune_idempotency_keys(7))::int, 1,
          'pruning removes exactly the keys past the retention window');

select is((select count(*)::int from app.idempotency_key where key = 'old-key-000001'), 0,
          'the expired key is gone');
select is((select count(*)::int from app.idempotency_key where key = 'new-key-000001'), 1,
          'a recent key is kept, so a retry in flight still deduplicates');

-- ---------------------------------------------------------------------------
-- Change-log retention and cursor expiry (R-SYNC-6/7)
--
-- Pruning and cursor_expired are one mechanism: the watermark written here is
-- what lets changes_since tell "you missed nothing" from "you missed data and
-- must refetch". Tested together because testing either alone proves little.
-- ---------------------------------------------------------------------------

insert into app.change_log (project_id, entity_type, entity_id, op, payload, created_at)
select (select id from tests.p1), 'verse', gen_random_uuid(), 'update',
       '{"probe":"stale"}'::jsonb, now() - interval '200 days'
  from generate_series(1, 3);

insert into app.change_log (project_id, entity_type, entity_id, op, payload)
values ((select id from tests.p1), 'verse', gen_random_uuid(), 'update',
        '{"probe":"fresh"}'::jsonb);

-- This also confirms the append-only trigger permits DELETE. Blocking it, as
-- the first version did, would make retention impossible.
select is((select app.prune_change_log(90))::int, 3,
          'pruning removes the entries past the retention window');

select is((select count(*)::int from app.change_log
            where payload->>'probe' = 'stale'), 0, 'stale entries are gone');
select is((select count(*)::int from app.change_log
            where payload->>'probe' = 'fresh'), 1, 'recent entries are kept');

select ok(
  (select pruned_through_seq from app.change_log_watermark
    where project_id = (select id from tests.p1)) > 0,
  'the watermark records how far pruning reached');

-- A cursor below the watermark must now expire rather than return an empty
-- page, which would read as "nothing changed" and leave the device silently
-- stale forever.
select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

select throws_ok(
  format($$ select api.changes_since(%L, %L) $$,
         (select id from tests.p1),
         app.encode_cursor((select id from tests.p1),
                           (select pruned_through_seq - 1 from app.change_log_watermark
                             where project_id = (select id from tests.p1)))),
  'PT410', 'cursor_expired',
  'a cursor stranded by pruning expires so the app falls back to a full fetch');

reset role;

-- ---------------------------------------------------------------------------
-- Job bookkeeping (R-OPS-7)
-- ---------------------------------------------------------------------------

select is((select count(*)::int from app.job_run where job_name = 'prune_change_log'), 1,
          'the pruning job recorded a run');

select ok(
  (select ok and finished_at is not null and rows_affected = 3
     from app.job_run where job_name = 'prune_change_log' order by started_at desc limit 1),
  'the run records its outcome and row count for an operator to query');

select * from finish();
rollback;
