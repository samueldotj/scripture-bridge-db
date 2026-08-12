-- Canonical books, localised book names, and versification.
--
-- Requirements: DB §5.1, R-DATA-1/2, R-MIG-4 (reference data is seeded by
-- migration and versioned with the schema, not loaded by hand).
--
-- GENERATED FILE. The book, name, and verse-count rows below were emitted from
-- a validated source dataset, not typed by hand. If they need to change, change
-- the source and regenerate — a hand-edited verse count is exactly the error
-- this file exists to prevent, because it surfaces at export, after translation
-- work has been built on top of it.
--
-- The generated data is checked at the end of this migration: 66 books,
-- 1,189 chapters, 31,103 verses, and book_canon.chapter_count agreeing with
-- ref.versification row-for-row. The migration fails if any of that is false.

-- ---------------------------------------------------------------------------
-- Versification schemes
--
-- R-DATA-2: verse counts differ between schemes — Psalm superscriptions, the
-- Greek and Hebrew numbering of several Psalms, the ending of Malachi and Joel,
-- and 3 John. A project that picks the wrong one discovers it at export, after
-- translation.
-- ---------------------------------------------------------------------------

create table ref.versification_scheme (
  code        text primary key,
  name        text not null,
  description text not null
);

insert into ref.versification_scheme (code, name, description) values
  ('eng', 'Modern English',
   'Modern English versification. Identical to KJV in every book except 3 John, which has 15 verses rather than 14 — the critical-text split of v.14 that modern English translations follow. 31,103 verses in total against the KJV''s 31,102. Verified book by book; 3 John is the only difference.'),
  ('org', 'Original',
   'Hebrew and Greek versification. Differs from English in Psalm superscriptions, Malachi, Joel, and elsewhere. REGISTERED BUT NOT SEEDED — no ref.versification rows exist, so a project using it cannot materialise a book until the data is loaded.');

-- ---------------------------------------------------------------------------
-- Canonical books
--
-- Deuterocanonical books are not seeded. Whether they are in scope is an open
-- decision that depends on the partner organisation's publishing target. The
-- schema accommodates them via book_canon.canon_section; adding them is data,
-- not migration surgery.
-- ---------------------------------------------------------------------------

create table ref.book_canon (
  code          text primary key,
  name_en       text not null,
  sort_order    int  not null unique,
  testament     text not null check (testament in ('ot', 'nt')),
  canon_section text not null default 'protestant'
                  check (canon_section in ('protestant', 'deuterocanonical')),
  chapter_count int  not null check (chapter_count > 0)
);

comment on table ref.book_canon is
  'USFM three-letter book codes in canonical order.';

comment on column ref.book_canon.chapter_count is
  'Convenience count. ref.versification is authoritative and may differ by scheme; the check at the end of this migration keeps the two in agreement for the seeded scheme.';

insert into ref.book_canon (code, name_en, sort_order, testament, chapter_count) values
  ('GEN',  'Genesis',           1,  'ot',   50),
  ('EXO',  'Exodus',            2,  'ot',   40),
  ('LEV',  'Leviticus',         3,  'ot',   27),
  ('NUM',  'Numbers',           4,  'ot',   36),
  ('DEU',  'Deuteronomy',       5,  'ot',   34),
  ('JOS',  'Joshua',            6,  'ot',   24),
  ('JDG',  'Judges',            7,  'ot',   21),
  ('RUT',  'Ruth',              8,  'ot',    4),
  ('1SA',  '1 Samuel',          9,  'ot',   31),
  ('2SA',  '2 Samuel',          10, 'ot',   24),
  ('1KI',  '1 Kings',           11, 'ot',   22),
  ('2KI',  '2 Kings',           12, 'ot',   25),
  ('1CH',  '1 Chronicles',      13, 'ot',   29),
  ('2CH',  '2 Chronicles',      14, 'ot',   36),
  ('EZR',  'Ezra',              15, 'ot',   10),
  ('NEH',  'Nehemiah',          16, 'ot',   13),
  ('EST',  'Esther',            17, 'ot',   10),
  ('JOB',  'Job',               18, 'ot',   42),
  ('PSA',  'Psalms',            19, 'ot',  150),
  ('PRO',  'Proverbs',          20, 'ot',   31),
  ('ECC',  'Ecclesiastes',      21, 'ot',   12),
  ('SNG',  'Song of Solomon',   22, 'ot',    8),
  ('ISA',  'Isaiah',            23, 'ot',   66),
  ('JER',  'Jeremiah',          24, 'ot',   52),
  ('LAM',  'Lamentations',      25, 'ot',    5),
  ('EZK',  'Ezekiel',           26, 'ot',   48),
  ('DAN',  'Daniel',            27, 'ot',   12),
  ('HOS',  'Hosea',             28, 'ot',   14),
  ('JOL',  'Joel',              29, 'ot',    3),
  ('AMO',  'Amos',              30, 'ot',    9),
  ('OBA',  'Obadiah',           31, 'ot',    1),
  ('JON',  'Jonah',             32, 'ot',    4),
  ('MIC',  'Micah',             33, 'ot',    7),
  ('NAM',  'Nahum',             34, 'ot',    3),
  ('HAB',  'Habakkuk',          35, 'ot',    3),
  ('ZEP',  'Zephaniah',         36, 'ot',    3),
  ('HAG',  'Haggai',            37, 'ot',    2),
  ('ZEC',  'Zechariah',         38, 'ot',   14),
  ('MAL',  'Malachi',           39, 'ot',    4),
  ('MAT',  'Matthew',           40, 'nt',   28),
  ('MRK',  'Mark',              41, 'nt',   16),
  ('LUK',  'Luke',              42, 'nt',   24),
  ('JHN',  'John',              43, 'nt',   21),
  ('ACT',  'Acts',              44, 'nt',   28),
  ('ROM',  'Romans',            45, 'nt',   16),
  ('1CO',  '1 Corinthians',     46, 'nt',   16),
  ('2CO',  '2 Corinthians',     47, 'nt',   13),
  ('GAL',  'Galatians',         48, 'nt',    6),
  ('EPH',  'Ephesians',         49, 'nt',    6),
  ('PHP',  'Philippians',       50, 'nt',    4),
  ('COL',  'Colossians',        51, 'nt',    4),
  ('1TH',  '1 Thessalonians',   52, 'nt',    5),
  ('2TH',  '2 Thessalonians',   53, 'nt',    3),
  ('1TI',  '1 Timothy',         54, 'nt',    6),
  ('2TI',  '2 Timothy',         55, 'nt',    4),
  ('TIT',  'Titus',             56, 'nt',    3),
  ('PHM',  'Philemon',          57, 'nt',    1),
  ('HEB',  'Hebrews',           58, 'nt',   13),
  ('JAS',  'James',             59, 'nt',    5),
  ('1PE',  '1 Peter',           60, 'nt',    5),
  ('2PE',  '2 Peter',           61, 'nt',    3),
  ('1JN',  '1 John',            62, 'nt',    5),
  ('2JN',  '2 John',            63, 'nt',    1),
  ('3JN',  '3 John',            64, 'nt',    1),
  ('JUD',  'Jude',              65, 'nt',    1),
  ('REV',  'Revelation',        66, 'nt',   22);

-- Localised book names are deliberately NOT modelled here.
--
-- APP R-L10N-1/3 means a project should not start with English book names its
-- translators cannot read — but app.book.name is already per-project and
-- editable from the console, which covers it. A ref table keyed by language
-- would today hold 66 English rows duplicating book_canon.name_en, i.e. a
-- second source of truth for the same string and nothing else. Add it when a
-- cohort language is actually known, with actual data in it.

-- ---------------------------------------------------------------------------
-- Versification: verse counts per chapter, per scheme
--
-- Stored one row per chapter. The array form below is a compact way to write
-- 1,189 rows without a wall of tuples; unnest WITH ORDINALITY turns each array
-- position into its chapter number.
-- ---------------------------------------------------------------------------

create table ref.versification (
  scheme_code    text not null references ref.versification_scheme(code),
  book_code      text not null references ref.book_canon(code),
  chapter_number int  not null check (chapter_number > 0),
  verse_count    int  not null check (verse_count > 0),
  primary key (scheme_code, book_code, chapter_number)
);

comment on table ref.versification is
  'Authoritative verse counts. Project materialisation (R-DATA-3) reads this, so a book cannot be added to a project until its rows exist here.';

insert into ref.versification (scheme_code, book_code, chapter_number, verse_count)
select 'eng', b.code, u.ord::int, u.cnt
  from (values
  ('GEN',  array[31,25,24,26,32,22,24,22,29,32,32,20,18,24,21,16,27,33,38,18,34,24,20,67,34,35,46,22,35,43,55,32,20,31,29,43,36,30,23,23,57,38,34,34,28,34,31,22,33,26]),
  ('EXO',  array[22,25,22,31,23,30,25,32,35,29,10,51,22,31,27,36,16,27,25,26,36,31,33,18,40,37,21,43,46,38,18,35,23,35,35,38,29,31,43,38]),
  ('LEV',  array[17,16,17,35,19,30,38,36,24,20,47,8,59,57,33,34,16,30,37,27,24,33,44,23,55,46,34]),
  ('NUM',  array[54,34,51,49,31,27,89,26,23,36,35,16,33,45,41,50,13,32,22,29,35,41,30,25,18,65,23,31,40,16,54,42,56,29,34,13]),
  ('DEU',  array[46,37,29,49,33,25,26,20,29,22,32,32,18,29,23,22,20,22,21,20,23,30,25,22,19,19,26,68,29,20,30,52,29,12]),
  ('JOS',  array[18,24,17,24,15,27,26,35,27,43,23,24,33,15,63,10,18,28,51,9,45,34,16,33]),
  ('JDG',  array[36,23,31,24,31,40,25,35,57,18,40,15,25,20,20,31,13,31,30,48,25]),
  ('RUT',  array[22,23,18,22]),
  ('1SA',  array[28,36,21,22,12,21,17,22,27,27,15,25,23,52,35,23,58,30,24,42,15,23,29,22,44,25,12,25,11,31,13]),
  ('2SA',  array[27,32,39,12,25,23,29,18,13,19,27,31,39,33,37,23,29,33,43,26,22,51,39,25]),
  ('1KI',  array[53,46,28,34,18,38,51,66,28,29,43,33,34,31,34,34,24,46,21,43,29,53]),
  ('2KI',  array[18,25,27,44,27,33,20,29,37,36,21,21,25,29,38,20,41,37,37,21,26,20,37,20,30]),
  ('1CH',  array[54,55,24,43,26,81,40,40,44,14,47,40,14,17,29,43,27,17,19,8,30,19,32,31,31,32,34,21,30]),
  ('2CH',  array[17,18,17,22,14,42,22,18,31,19,23,16,22,15,19,14,19,34,11,37,20,12,21,27,28,23,9,27,36,27,21,33,25,33,27,23]),
  ('EZR',  array[11,70,13,24,17,22,28,36,15,44]),
  ('NEH',  array[11,20,32,23,19,19,73,18,38,39,36,47,31]),
  ('EST',  array[22,23,15,17,14,14,10,17,32,3]),
  ('JOB',  array[22,13,26,21,27,30,21,22,35,22,20,25,28,22,35,22,16,21,29,29,34,30,17,25,6,14,23,28,25,31,40,22,33,37,16,33,24,41,30,24,34,17]),
  ('PSA',  array[6,12,8,8,12,10,17,9,20,18,7,8,6,7,5,11,15,50,14,9,13,31,6,10,22,12,14,9,11,12,24,11,22,22,28,12,40,22,13,17,13,11,5,26,17,11,9,14,20,23,19,9,6,7,23,13,11,11,17,12,8,12,11,10,13,20,7,35,36,5,24,20,28,23,10,12,20,72,13,19,16,8,18,12,13,17,7,18,52,17,16,15,5,23,11,13,12,9,9,5,8,28,22,35,45,48,43,13,31,7,10,10,9,8,18,19,2,29,176,7,8,9,4,8,5,6,5,6,8,8,3,18,3,3,21,26,9,8,24,13,10,7,12,15,21,10,20,14,9,6]),
  ('PRO',  array[33,22,35,27,23,35,27,36,18,32,31,28,25,35,33,33,28,24,29,30,31,29,35,34,28,28,27,28,27,33,31]),
  ('ECC',  array[18,26,22,16,20,12,29,17,18,20,10,14]),
  ('SNG',  array[17,17,11,16,16,13,13,14]),
  ('ISA',  array[31,22,26,6,30,13,25,22,21,34,16,6,22,32,9,14,14,7,25,6,17,25,18,23,12,21,13,29,24,33,9,20,24,17,10,22,38,22,8,31,29,25,28,28,25,13,15,22,26,11,23,15,12,17,13,12,21,14,21,22,11,12,19,12,25,24]),
  ('JER',  array[19,37,25,31,31,30,34,22,26,25,23,17,27,22,21,21,27,23,15,18,14,30,40,10,38,24,22,17,32,24,40,44,26,22,19,32,21,28,18,16,18,22,13,30,5,28,7,47,39,46,64,34]),
  ('LAM',  array[22,22,66,22,22]),
  ('EZK',  array[28,10,27,17,17,14,27,18,11,22,25,28,23,23,8,63,24,32,14,49,32,31,49,27,17,21,36,26,21,26,18,32,33,31,15,38,28,23,29,49,26,20,27,31,25,24,23,35]),
  ('DAN',  array[21,49,30,37,31,28,28,27,27,21,45,13]),
  ('HOS',  array[11,23,5,19,15,11,16,14,17,15,12,14,16,9]),
  ('JOL',  array[20,32,21]),
  ('AMO',  array[15,16,15,13,27,14,17,14,15]),
  ('OBA',  array[21]),
  ('JON',  array[17,10,10,11]),
  ('MIC',  array[16,13,12,13,15,16,20]),
  ('NAM',  array[15,13,19]),
  ('HAB',  array[17,20,19]),
  ('ZEP',  array[18,15,20]),
  ('HAG',  array[15,23]),
  ('ZEC',  array[21,13,10,14,11,15,14,23,17,12,17,14,9,21]),
  ('MAL',  array[14,17,18,6]),
  ('MAT',  array[25,23,17,25,48,34,29,34,38,42,30,50,58,36,39,28,27,35,30,34,46,46,39,51,46,75,66,20]),
  ('MRK',  array[45,28,35,41,43,56,37,38,50,52,33,44,37,72,47,20]),
  ('LUK',  array[80,52,38,44,39,49,50,56,62,42,54,59,35,35,32,31,37,43,48,47,38,71,56,53]),
  ('JHN',  array[51,25,36,54,47,71,53,59,41,42,57,50,38,31,27,33,26,40,42,31,25]),
  ('ACT',  array[26,47,26,37,42,15,60,40,43,48,30,25,52,28,41,40,34,28,41,38,40,30,35,27,27,32,44,31]),
  ('ROM',  array[32,29,31,25,21,23,25,39,33,21,36,21,14,23,33,27]),
  ('1CO',  array[31,16,23,21,13,20,40,13,27,33,34,31,13,40,58,24]),
  ('2CO',  array[24,17,18,18,21,18,16,24,15,18,33,21,14]),
  ('GAL',  array[24,21,29,31,26,18]),
  ('EPH',  array[23,22,21,32,33,24]),
  ('PHP',  array[30,30,21,23]),
  ('COL',  array[29,23,25,18]),
  ('1TH',  array[10,20,13,18,28]),
  ('2TH',  array[12,17,18]),
  ('1TI',  array[20,15,16,16,25,21]),
  ('2TI',  array[18,26,17,22]),
  ('TIT',  array[16,15,15]),
  ('PHM',  array[25]),
  ('HEB',  array[14,18,19,16,14,20,28,13,28,39,40,29,25]),
  ('JAS',  array[27,26,18,17,20]),
  ('1PE',  array[25,25,22,19,14]),
  ('2PE',  array[21,22,18]),
  ('1JN',  array[10,29,24,21,21]),
  ('2JN',  array[13]),
  ('3JN',  array[15]),
  ('JUD',  array[25]),
  ('REV',  array[20,29,22,11,14,17,17,13,21,11,19,17,18,20,8,21,18,24,21,15,27,21])
  ) as b(code, counts)
 cross join lateral unnest(b.counts) with ordinality as u(cnt, ord);

-- ---------------------------------------------------------------------------
-- Self-check
--
-- This migration generates ~1,300 rows of reference data. Asserting its shape
-- here means a regeneration that goes wrong fails at migration time, in CI,
-- rather than months later at export.
-- ---------------------------------------------------------------------------

do $$
declare
  v_books    int;
  v_chapters int;
  v_verses   int;
  v_mismatch int;
begin
  select count(*) into v_books from ref.book_canon;

  select count(*), coalesce(sum(verse_count), 0)
    into v_chapters, v_verses
    from ref.versification where scheme_code = 'eng';

  -- book_canon.chapter_count must agree with the number of versification rows
  -- for every book, or materialisation produces a book with missing chapters.
  select count(*) into v_mismatch
    from ref.book_canon b
    left join (
      select book_code, count(*)::int as n
        from ref.versification where scheme_code = 'eng' group by book_code
    ) v on v.book_code = b.code
   where coalesce(v.n, 0) <> b.chapter_count;

  if v_books <> 66 then
    raise exception 'reference data check failed: % books, expected 66', v_books;
  end if;
  if v_chapters <> 1189 then
    raise exception 'reference data check failed: % chapters, expected 1189', v_chapters;
  end if;
  if v_verses <> 31103 then
    raise exception 'reference data check failed: % verses, expected 31103 (KJV is 31102; 3 John has 15 verses in this scheme)', v_verses;
  end if;
  if v_mismatch <> 0 then
    raise exception 'reference data check failed: % books where chapter_count disagrees with versification', v_mismatch;
  end if;

  raise notice 'Reference data: % books, % chapters, % verses (scheme eng)',
    v_books, v_chapters, v_verses;
end;
$$;
