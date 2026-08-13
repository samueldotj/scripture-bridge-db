-- Reference data and project materialisation (R-DATA-1/2/3).
--
-- The migration already asserts the totals at apply time; repeating them here
-- means a later data-only change is caught by the test suite too.

begin;
\ir _helpers.psql
select no_plan();

-- ---------------------------------------------------------------------------
-- Canon and versification
-- ---------------------------------------------------------------------------

select is((select count(*)::int from ref.book_canon), 66,
          '66 canonical books');

select is((select count(*)::int from ref.versification where scheme_code = 'eng'),
          1189, '1,189 chapters in the eng scheme');

select is((select sum(verse_count)::int from ref.versification where scheme_code = 'eng'),
          31103, '31,103 verses in the eng scheme');

-- The one book that differs from KJV totals. Asserted explicitly so that a
-- future versification import cannot quietly change the scheme's identity.
select is((select verse_count from ref.versification
            where scheme_code = 'eng' and book_code = '3JN' and chapter_number = 1),
          15, '3 John has 15 verses — modern English, not KJV''s 14');

select is_empty(
  $$ select b.code
       from ref.book_canon b
       left join (select book_code, count(*)::int n from ref.versification
                   where scheme_code = 'eng' group by book_code) v
         on v.book_code = b.code
      where coalesce(v.n, 0) <> b.chapter_count $$,
  'book_canon.chapter_count agrees with versification for every book');

-- The org scheme is registered but deliberately unseeded, so a project using it
-- fails loudly rather than materialising wrong verse counts.
select is((select count(*)::int from ref.versification where scheme_code = 'org'),
          0, 'the org scheme has no versification rows yet');

-- ---------------------------------------------------------------------------
-- Materialisation
-- ---------------------------------------------------------------------------

-- Fixture ids are looked up by subquery rather than carried in psql variables:
-- \gset plus format(%L) double-quotes the literal, and the failure mode is a
-- test that errors for reasons unrelated to what it claims to check.
select tests.create_user('alice');
select tests.new_project('P1', 'MAT');

select is((select b.chapter_count from app.book b
             join app.project p on p.id = b.project_id where p.name = 'P1'),
          28, 'Matthew materialised with 28 chapters');

select is((select count(*)::int from app.verse v
             join app.project p on p.id = v.project_id where p.name = 'P1'),
          1071, 'Matthew materialised with 1,071 verses');

select is((select count(*)::int from app.verse v
             join app.project p on p.id = v.project_id
            where p.name = 'P1' and v.status <> 'empty'),
          0, 'every materialised verse starts empty');

-- R-DATA-3: a verse row exists before anyone types into it, which is what makes
-- R-WF-1 a counting query rather than an absence-of-row inference.
select is((select c.verses_empty from app.chapter c
             join app.project p on p.id = c.project_id
            where p.name = 'P1' and c.number = 1),
          25, 'chapter counters are populated by trigger during materialisation');

select is((select sum(c.verses_empty)::int from app.chapter c
             join app.project p on p.id = c.project_id where p.name = 'P1'),
          1071, 'counters across the book sum to the verse count');

-- R-DATA-8: versification is immutable once a project exists.
select throws_ok(
  $$ update app.project set versification_scheme = 'org' where name = 'P1' $$,
  'PT409', 'versification_immutable',
  'the versification scheme cannot be changed after project creation');

-- A book with no versification rows cannot be materialised.
--
-- This used to try GEN against the eng scheme, from when only Matthew was
-- seeded. Every book now has eng versification, so the missing-data case is a
-- SCHEME with none: org is registered but deliberately unseeded, precisely so
-- that selecting it fails loudly instead of producing wrong verse counts.
insert into app.project (name, language_name, language_code, script_code,
                         text_direction, versification_scheme)
values ('P-org', 'Test Language', 'xx', 'Latn', 'ltr', 'org');

select throws_ok(
  $$ select app.materialise_book(
       (select id from app.project where name = 'P-org'), 'MAT') $$,
  'PT422', 'versification_missing',
  'materialising against a scheme with no versification data is refused');

select * from finish();
rollback;
