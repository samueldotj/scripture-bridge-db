-- Index and plan verification at full-Bible scale (R-TEST-5, R-NFR-1/2).
--
-- Every other test runs against one book: 1,071 verses. A sequential scan over
-- 1,071 rows is instant and indistinguishable from an index scan, so nothing
-- so far can tell whether the indexes in DB §15 are actually used. This file
-- builds the whole canon - 66 books, 1,189 chapters, 31,103 verses - and
-- asserts the PLAN for each hot path.
--
-- Plans, not timings. Wall-clock in CI is noise: a slow shared runner would
-- fail a timing assertion that says nothing about the schema, and a fast one
-- would pass while doing a sequential scan. The plan is deterministic and is
-- what actually degrades as data grows.
--
-- R-NFR-2 asks for EXPLAIN output recorded in the repository. Asserting the
-- index by name here is that record, and a better one: a committed text file
-- goes stale silently, whereas this fails the build the day a plan changes.

begin;
\ir _helpers.psql
select no_plan();

-- ---------------------------------------------------------------------------
-- Fixture
--
-- Loaded set-based with the counter trigger off. The trigger fires per verse
-- and would issue ~31,000 updates against 1,189 chapter rows, which is slow and
-- adds no coverage - materialisation is already tested in 02_reference.sql.
-- Counters are then rebuilt by the reconciliation function, which doubles as a
-- check that it can repair a whole project.
-- ---------------------------------------------------------------------------

insert into app.project (name, language_name, language_code, script_code,
                         text_direction, versification_scheme)
values ('Scale', 'Test Language', 'xx', 'Latn', 'ltr', 'eng');

alter table app.verse disable trigger verse_maintain_counters;

insert into app.book (project_id, code, name, sort_order, chapter_count)
select (select id from app.project where name = 'Scale'),
       b.code, b.name_en, b.sort_order, b.chapter_count
  from ref.book_canon b;

insert into app.chapter (book_id, project_id, number, verse_count)
select bk.id, bk.project_id, v.chapter_number, v.verse_count
  from ref.versification v
  join app.book bk
    on bk.code = v.book_code
   and bk.project_id = (select id from app.project where name = 'Scale')
 where v.scheme_code = 'eng';

insert into app.verse (chapter_id, project_id, number)
select c.id, c.project_id, g.n
  from app.chapter c
 cross join lateral generate_series(1, c.verse_count) as g(n)
 where c.project_id = (select id from app.project where name = 'Scale');

alter table app.verse enable trigger verse_maintain_counters;

select is((select count(*)::int from app.verse
            where project_id = (select id from app.project where name = 'Scale')),
          31103, 'the scale fixture holds a full Bible: 31,103 verses');

select is((select count(*)::int from app.chapter
            where project_id = (select id from app.project where name = 'Scale')),
          1189, 'across 1,189 chapters');

-- Rebuilding counters for a whole project in one pass (R-PERF-4).
select is_empty(
  $$ select chapter_id::text from app.reconcile_chapter_counters(true) $$,
  'reconciliation rebuilds counters for 1,189 chapters and reports none left over');

-- Text on a slice, so the trigram index has something to find.
update app.verse
   set text = 'in the beginning was the word ' || number::text
 where project_id = (select id from app.project where name = 'Scale')
   and number <= 3;

-- Revision history, since DB §13.6 estimates 5-20 revisions per verse over a
-- project's life and the history read must stay indexed as that grows.
insert into app.verse_revision (verse_id, project_id, rev, text, author_id)
select v.id, v.project_id, g.n, 'revision ' || g.n::text, null
  from app.verse v
 cross join generate_series(1, 5) as g(n)
 where v.project_id = (select id from app.project where name = 'Scale')
   and v.number <= 3;

-- Two projects' worth of traffic, because a filter that matches every row is
-- not a filter: with a single project the planner correctly prefers a scan and
-- the index assertion below would fail while nothing was wrong.
insert into app.project (name, language_name, language_code, script_code,
                         text_direction, versification_scheme)
values ('Scale Neighbour', 'Test Language', 'xx', 'Latn', 'ltr', 'eng');

insert into app.change_log (project_id, entity_type, entity_id, op, payload)
select v.project_id, 'verse', v.id, 'update', '{}'::jsonb
  from app.verse v
 where v.project_id = (select id from app.project where name = 'Scale')
   and v.number <= 2;

insert into app.change_log (project_id, entity_type, entity_id, op, payload)
select (select id from app.project where name = 'Scale Neighbour'),
       'verse', v.id, 'update', '{}'::jsonb
  from app.verse v
 where v.project_id = (select id from app.project where name = 'Scale')
   and v.number <= 2;

-- A rare token, so search selectivity resembles a translator looking for a
-- term rather than matching a tenth of the Bible.
update app.verse
   set text = text || ' zzqx-rare-token'
 where project_id = (select id from app.project where name = 'Scale')
   and number = 1
   and chapter_id in (select id from app.chapter
                       where project_id = (select id from app.project where name = 'Scale')
                       limit 5);

-- Without stats the planner has no reason to prefer an index, and every
-- assertion below would fail for the wrong reason.
analyze app.verse;
analyze app.verse_revision;
analyze app.change_log;
analyze app.chapter;

-- ---------------------------------------------------------------------------
-- Plan capture
-- ---------------------------------------------------------------------------

create function tests.plan_of(q text)
returns text
language plpgsql
as $$
declare
  r record;
  out text := '';
begin
  for r in execute 'explain (costs off) ' || q loop
    out := out || r."QUERY PLAN" || E'\n';
  end loop;
  return out;
end;
$$;

create function tests.uses_index(q text, idx text)
returns boolean
language sql
as $$ select tests.plan_of(q) like '%' || idx || '%' $$;

create view tests.scale as select id from app.project where name = 'Scale';

-- ---------------------------------------------------------------------------
-- The hot paths (DB §15)
-- ---------------------------------------------------------------------------

select ok(
  tests.uses_index(
    'select id from app.verse where chapter_id = (select id from app.chapter
       where project_id = (select id from tests.scale) limit 1) order by number',
    'verse_chapter_number_idx'),
  'reading a chapter''s verses uses verse_chapter_number_idx, not a scan of 31,103 rows');

select ok(
  tests.uses_index(
    'select id from app.verse_revision where verse_id = (select id from app.verse
       where project_id = (select id from tests.scale) limit 1) order by rev desc limit 20',
    'verse_revision_verse_rev_idx'),
  'a verse''s history uses verse_revision_verse_rev_idx');

select ok(
  tests.uses_index(
    'select seq from app.change_log where project_id = (select id from tests.scale)
       and seq > (select max(seq) - 50 from app.change_log) order by seq limit 500',
    'change_log_project_seq_idx'),
  'a delta-sync page uses change_log_project_seq_idx');

select ok(
  tests.uses_index(
    'select id from app.verse where project_id = (select id from tests.scale)
       and text_folded like ''%zzqx-rare-token%''',
    'verse_text_folded_idx'),
  'project-wide search uses the trigram index rather than reading every verse');

-- R-PERF-1: progress is served from chapter counters. If a plan change ever
-- pulls app.verse into this query it stops being a hundreds-of-rows aggregate
-- and becomes a tens-of-thousands one, on a screen the app polls.
select ok(
  tests.plan_of(
    'select * from api.project_progress where project_id = (select id from tests.scale)'
  ) not like '%on verse%',
  'progress aggregates chapter counters and never touches app.verse');

-- ---------------------------------------------------------------------------
-- Storage footprint (R-PLAT-DB-6 / APP R-PLAT-6 is the device-side budget; this
-- is the server side of the same estimate in DB §13.6)
-- ---------------------------------------------------------------------------

select ok(
  pg_total_relation_size('app.verse') < 64 * 1024 * 1024,
  'a full Bible of verses fits well inside the sizing estimate');

select * from finish();
rollback;
