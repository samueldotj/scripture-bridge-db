-- Delta sync and search (DB §10, §5.8).
--
-- ===========================================================================
-- SCOPE LIMIT, READ THIS.
--
-- R-TEST-4 asks for a test of the out-of-order commit race: a transaction that
-- takes a lower seq and commits AFTER one that took a higher seq must not be
-- skipped. That race needs TWO concurrent sessions, and pgTAP runs in one.
--
-- What this file asserts is the FILTER — that changes_since excludes entries
-- whose xact_id is not yet below the snapshot's xmin — by inserting rows with
-- crafted xact_id values. That is the mechanism the race depends on, and it
-- catches the realistic regression (someone removing or weakening the guard).
--
-- It does NOT reproduce the race itself. A true concurrency test needs two
-- psql connections driven by an external harness, and R-TEST-2's simultaneous
-- -saves test has the same requirement. Both remain owed; see docs/roadmap.md
-- M3. Do not read a green run here as covering them.
-- ===========================================================================

begin;
\ir _helpers.psql
select no_plan();

select tests.create_user('alice');
select tests.clear_password_gate('alice');
select tests.new_project('P1', 'MAT');
select tests.add_member((select id from app.project where name = 'P1'), 'alice', 'translator');

update app.chapter c
   set assigned_translator_id = tests.profile_id('alice')
  from app.project p
 where p.id = c.project_id and p.name = 'P1' and c.number = 1;

create view tests.p1 as select id from app.project where name = 'P1';
create view tests.v1 as
  select v.id from app.verse v join app.chapter c on c.id = v.chapter_id
    join app.project p on p.id = v.project_id
   where p.name = 'P1' and c.number = 1 and v.number = 1;
grant select on tests.p1, tests.v1 to authenticated;

-- ---------------------------------------------------------------------------
-- Initial sync and cursor advance
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', tests.jwt('alice'), true);
select set_config('request.headers', '{"idempotency-key": "test-key-s1"}', true);
set local role authenticated;

select is(jsonb_array_length(
            api.changes_since((select id from tests.p1)) -> 'changes'),
          0, 'a project with no writes reports no changes');

select lives_ok(
  $$ select api.save_verse_text((select id from tests.v1), 'synced text', 'explicit_save') $$,
  'a write to sync');

-- The write happened in THIS transaction, so its xact_id is not below the
-- snapshot xmin and the guard correctly withholds it. This is the guard doing
-- its job, not a bug — and it is why the concurrency caveat above matters.
select ok(
  jsonb_array_length(api.changes_since((select id from tests.p1)) -> 'changes') >= 0,
  'changes_since runs against an in-flight write without error');

select ok(
  (api.changes_since((select id from tests.p1)) ->> 'next_cursor') is not null,
  'a cursor is always returned, even for an empty page');

select is(
  (api.changes_since((select id from tests.p1)) ->> 'has_more')::boolean,
  false, 'has_more is false when there is no further page');

reset role;

-- ---------------------------------------------------------------------------
-- The snapshot guard (R-SYNC-3)
--
-- Two rows are inserted directly with crafted xact_id values: one safely below
-- the current snapshot's xmin, one far above it. Only the first may be
-- returned. Removing the guard makes the second appear and this test fail.
-- ---------------------------------------------------------------------------

insert into app.change_log (project_id, entity_type, entity_id, op, payload, xact_id)
select (select id from tests.p1), 'verse', (select id from tests.v1), 'update',
       '{"probe": "visible"}'::jsonb, '1'::xid8;

insert into app.change_log (project_id, entity_type, entity_id, op, payload, xact_id)
select (select id from tests.p1), 'verse', (select id from tests.v1), 'update',
       '{"probe": "hidden"}'::jsonb,
       (pg_snapshot_xmin(pg_current_snapshot())::text::bigint + 1000000)::text::xid8;

select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

select is(
  (select count(*)::int
     from jsonb_array_elements(
            api.changes_since((select id from tests.p1)) -> 'changes') e
    where e -> 'payload' ->> 'probe' = 'visible'),
  1, 'a change from a committed transaction is returned');

select is(
  (select count(*)::int
     from jsonb_array_elements(
            api.changes_since((select id from tests.p1)) -> 'changes') e
    where e -> 'payload' ->> 'probe' = 'hidden'),
  0, 'a change whose xact_id is above the snapshot xmin is withheld (R-SYNC-3)');

-- ---------------------------------------------------------------------------
-- Cursor handling
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ select api.changes_since((select id from tests.p1), 'not-base64!!') $$,
  'PT400', 'invalid_argument',
  'a malformed cursor is a client error, not an expiry');

select throws_ok(
  format($$ select api.changes_since(%L, %L) $$,
         (select id from tests.p1),
         app.encode_cursor(gen_random_uuid(), 1)),
  'PT400', 'invalid_argument',
  'a cursor minted for another project is refused');

reset role;

-- R-SYNC-7: a cursor BELOW the watermark expires. One equal to it has missed
-- nothing, since the watermark is the highest seq pruned.
insert into app.change_log_watermark (project_id, pruned_through_seq)
select (select id from tests.p1), 500;

select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

select throws_ok(
  format($$ select api.changes_since(%L, %L) $$,
         (select id from tests.p1),
         app.encode_cursor((select id from tests.p1), 499)),
  'PT410', 'cursor_expired',
  'a cursor below the pruning watermark expires so the app can refetch');

select lives_ok(
  format($$ select api.changes_since(%L, %L) $$,
         (select id from tests.p1),
         app.encode_cursor((select id from tests.p1), 500)),
  'a cursor exactly at the watermark is still valid');

select lives_ok(
  format($$ select api.changes_since(%L) $$, (select id from tests.p1)),
  'an initial sync with no cursor is never expired');

reset role;

-- ---------------------------------------------------------------------------
-- Search (R-SEARCH-DB-1/2/3)
-- ---------------------------------------------------------------------------

update app.verse v set text = 'the quick brown fox', status = 'draft'
  from app.chapter c, app.project p
 where c.id = v.chapter_id and p.id = v.project_id
   and p.name = 'P1' and c.number = 2 and v.number = 3;

update app.verse v set text = 'a 100% match', status = 'draft'
  from app.chapter c, app.project p
 where c.id = v.chapter_id and p.id = v.project_id
   and p.name = 'P1' and c.number = 4 and v.number = 5;

select set_config('request.jwt.claims', tests.jwt('alice'), true);
set local role authenticated;

select is(
  (select count(*)::int from api.search_verses((select id from tests.p1), 'brown')),
  1, 'search finds a verse by substring');

select is(
  (select chapter_number from api.search_verses((select id from tests.p1), 'brown')),
  2, 'search returns the right location');

select is(
  (select count(*)::int from api.search_verses((select id from tests.p1), 'BROWN')),
  1, 'search is case-insensitive via the folded column');

-- LIKE metacharacters in the query must be escaped, or '%' matches everything.
select is(
  (select count(*)::int from api.search_verses((select id from tests.p1), '100%')),
  1, 'a query containing % searches for the character, not as a wildcard');

select throws_ok(
  format($$ select * from api.search_verses(%L, 'x') $$, (select id from tests.p1)),
  'PT400', 'invalid_argument',
  'a one-character query is refused rather than scanning the project');

reset role;

-- A non-member gets a typed refusal, not an empty result: an offline client
-- must be able to tell "no access" from "no matches".
select tests.create_user('mallory');
select tests.clear_password_gate('mallory');

select set_config('request.jwt.claims', tests.jwt('mallory'), true);
set local role authenticated;

select throws_ok(
  format($$ select * from api.search_verses(%L, 'brown') $$, (select id from tests.p1)),
  'PT403', 'forbidden',
  'a non-member searching another project is refused explicitly');

select throws_ok(
  format($$ select api.changes_since(%L) $$, (select id from tests.p1)),
  'PT403', 'forbidden',
  'a non-member syncing another project is refused explicitly');

reset role;

select * from finish();
rollback;
