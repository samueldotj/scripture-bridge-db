-- Books, chapters, verses, revisions, and comments.
--
-- Requirements: DB §5.4, §5.5, §5.7, R-DATA-10/11/12, R-TEXT-DB-1..4,
-- R-PERF-1/2, R-FN-9, R-NFR-1.

-- ---------------------------------------------------------------------------
-- Books
-- ---------------------------------------------------------------------------

create table app.book (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references app.project(id) on delete restrict,
  code          text not null references ref.book_canon(code),

  -- Vernacular book name. Seeded from ref.book_canon.name_en at materialisation
  -- and editable from the console: translators do not necessarily read English.
  name          text not null,

  sort_order    int  not null,
  chapter_count int  not null check (chapter_count > 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (project_id, code),

  -- Target for the composite foreign keys below. Redundant as a constraint
  -- (id is already unique) but required to reference (id, project_id).
  unique (id, project_id)
);

create index book_project_sort_idx on app.book (project_id, sort_order);

create trigger book_set_updated_at
  before update on app.book
  for each row execute function app.set_updated_at();

alter table app.book enable row level security;
alter table app.book force row level security;

-- ---------------------------------------------------------------------------
-- Chapters — the unit of assignment, submission, and approval
--
-- APP §8.1: assignment is orthogonal to workflow state. A chapter stays
-- assigned as it moves through drafting and review, so assignment columns and
-- workflow_state are independent.
-- ---------------------------------------------------------------------------

create table app.chapter (
  id                    uuid primary key default gen_random_uuid(),
  book_id               uuid not null references app.book(id) on delete restrict,

  -- Denormalised from book. See the note above app.verse.project_id.
  project_id            uuid not null,

  number                int  not null check (number > 0),
  verse_count           int  not null check (verse_count > 0),

  assigned_translator_id uuid references app.profile(id),
  assigned_reviewer_id   uuid references app.profile(id),

  workflow_state        text not null default 'not_started'
                          check (workflow_state in
                            ('not_started', 'in_progress', 'in_review', 'approved')),

  submitted_at          timestamptz,
  approved_at           timestamptz,
  approved_by_id        uuid references app.profile(id),

  -- R-PERF-2: maintained by trigger, in the same transaction as the write.
  -- A full-Bible project is ~31,000 verse rows; aggregating them on every
  -- progress render from a metered device is the query that would eventually
  -- dominate the instance's load (R-PERF-1).
  verses_empty          int not null default 0 check (verses_empty   >= 0),
  verses_draft          int not null default 0 check (verses_draft   >= 0),
  verses_done           int not null default 0 check (verses_done    >= 0),
  verses_flagged        int not null default 0 check (verses_flagged >= 0),

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (book_id, number),
  unique (id, project_id),

  -- The engine guarantees the denormalised project_id agrees with the book's.
  foreign key (book_id, project_id)
    references app.book (id, project_id) on delete restrict,

  constraint chapter_approved_has_approver
    check ((workflow_state = 'approved') = (approved_at is not null and approved_by_id is not null))
);

create index chapter_book_number_idx  on app.chapter (book_id, number);
create index chapter_translator_idx   on app.chapter (assigned_translator_id)
  where assigned_translator_id is not null;
create index chapter_reviewer_idx     on app.chapter (assigned_reviewer_id)
  where assigned_reviewer_id is not null;
create index chapter_review_queue_idx on app.chapter (assigned_reviewer_id, workflow_state)
  where workflow_state = 'in_review';

create trigger chapter_set_updated_at
  before update on app.chapter
  for each row execute function app.set_updated_at();

alter table app.chapter enable row level security;
alter table app.chapter force row level security;

-- ---------------------------------------------------------------------------
-- Verses — the unit of editing
-- ---------------------------------------------------------------------------

create table app.verse (
  id          uuid primary key default gen_random_uuid(),
  chapter_id  uuid not null references app.chapter(id) on delete restrict,

  -- Denormalised project_id, carried on every content table.
  --
  -- RLS is the only authorisation mechanism in this system (R-RLS-4), which
  -- makes policy legibility a security property, not a performance one. With
  -- this column a policy is `project_id = any(<my projects>)` — one equality
  -- against a per-statement cached array, reviewable at a glance. Without it,
  -- every policy on this table is a three-level join through chapter and book,
  -- re-derived per row and re-stated in each policy.
  --
  -- The redundancy is safe because it cannot drift: the composite foreign key
  -- below makes the engine reject any row whose project_id disagrees with its
  -- chapter's, and a verse never moves between projects.
  project_id  uuid not null,

  number      int  not null check (number > 0),

  -- R-DATA-12: defaults to empty string, never NULL. Three-valued logic on the
  -- most-read column in the system buys nothing; status = 'empty' carries that
  -- meaning explicitly.
  text        text not null default '',

  -- R-SEARCH-DB-2: folded form for trigram search. Generated, so it cannot
  -- drift from the text it indexes.
  text_folded text generated always as (app.fold_text(text)) stored,

  -- R-DATA-10: a per-verse write counter, incremented inside save_verse_text.
  -- Not a sequence, not a transaction id, not global, and explicitly neither a
  -- concurrency token nor a history sequence number (APP §5.1).
  rev         int not null default 0 check (rev >= 0),

  -- R-DATA-11: maintained only by the write functions. No other code path may
  -- set it.
  status      text not null default 'empty'
                check (status in ('empty', 'draft', 'done', 'flagged')),

  last_modified_by_id      uuid references app.profile(id),
  last_modified_at         timestamptz,
  unresolved_comment_count int not null default 0 check (unresolved_comment_count >= 0),

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (chapter_id, number),
  unique (id, project_id),

  foreign key (chapter_id, project_id)
    references app.chapter (id, project_id) on delete restrict,

  -- R-TEXT-DB-1: APP R-TEXT-1 requires NFC end to end and requires a round trip
  -- to be a no-op. A database that silently accepts NFD makes that promise
  -- unverifiable. R-TEXT-DB-2: the API rejects non-NFC rather than normalising,
  -- because normalising on write means a read returns text that differs from
  -- what was just sent, breaking the client's dirty-state tracking.
  constraint verse_text_nfc    check (text is nfc normalized),

  -- R-TEXT-DB-4: not a linguistic limit. A bound on what a malfunctioning
  -- client can push into a row that is copied into history on every write.
  constraint verse_text_length check (length(text) <= 4000)
);

create index verse_chapter_number_idx on app.verse (chapter_id, number);
create index verse_project_idx        on app.verse (project_id);
create index verse_text_folded_idx    on app.verse using gin (text_folded extensions.gin_trgm_ops);

create trigger verse_set_updated_at
  before update on app.verse
  for each row execute function app.set_updated_at();

alter table app.verse enable row level security;
alter table app.verse force row level security;

-- ---------------------------------------------------------------------------
-- Revisions — append-only (APP R-REV-1)
-- ---------------------------------------------------------------------------

create table app.verse_revision (
  id                        uuid primary key default gen_random_uuid(),
  verse_id                  uuid not null references app.verse(id) on delete restrict,
  project_id                uuid not null,

  -- R-FN-8: the counter value AFTER the increment, so a revision's rev
  -- identifies the write it snapshots. Revisions are a subset of writes, so
  -- these values are non-contiguous; the UI presents ordinals (APP §5.1).
  rev                       int  not null check (rev > 0),

  -- APP §5.1: a revision carries only the resulting text, never
  -- previous-and-new. The prior version is the preceding revision; storing both
  -- would create two sources of truth that can disagree.
  text                      text not null,

  author_id                 uuid references app.profile(id),
  note                      text,
  restored_from_revision_id uuid references app.verse_revision(id),

  -- R-DATA-15: client-asserted, for display and diagnostics only. Never used in
  -- a comparison (R-API-3).
  client_created_at         timestamptz,

  created_at                timestamptz not null default now(),
  unique (verse_id, rev),

  foreign key (verse_id, project_id)
    references app.verse (id, project_id) on delete restrict,

  constraint verse_revision_text_nfc check (text is nfc normalized)
);

-- Newest-first history reads (APP §13.4, paginated).
create index verse_revision_verse_rev_idx on app.verse_revision (verse_id, rev desc);

alter table app.verse_revision enable row level security;
alter table app.verse_revision force row level security;

-- R-FN-9: grants stop `authenticated`; this trigger stops a future migration, a
-- console feature, or a service_role script. APP R-REV-1 makes immutability a
-- property of the system, and the service key bypasses grants but not triggers.
create trigger verse_revision_append_only
  before update or delete on app.verse_revision
  for each row execute function app.forbid_mutation();

-- ---------------------------------------------------------------------------
-- Comments (APP §9)
-- ---------------------------------------------------------------------------

create table app.comment (
  id             uuid primary key default gen_random_uuid(),
  verse_id       uuid not null references app.verse(id) on delete restrict,
  project_id     uuid not null,
  author_id      uuid references app.profile(id),
  body           text not null check (length(btrim(body)) > 0),
  resolved_at    timestamptz,
  resolved_by_id uuid references app.profile(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  foreign key (verse_id, project_id)
    references app.verse (id, project_id) on delete restrict,

  constraint comment_resolved_has_resolver
    check ((resolved_at is null) = (resolved_by_id is null))
);

create index comment_verse_idx on app.comment (verse_id);
create index comment_unresolved_idx on app.comment (verse_id) where resolved_at is null;

create trigger comment_set_updated_at
  before update on app.comment
  for each row execute function app.set_updated_at();

alter table app.comment enable row level security;
alter table app.comment force row level security;

-- ---------------------------------------------------------------------------
-- Counter maintenance (R-PERF-2)
-- ---------------------------------------------------------------------------

create or replace function app.bump_chapter_counter(
  p_chapter_id uuid, p_status text, p_delta int)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update app.chapter
     set verses_empty   = verses_empty   + case when p_status = 'empty'   then p_delta else 0 end,
         verses_draft   = verses_draft   + case when p_status = 'draft'   then p_delta else 0 end,
         verses_done    = verses_done    + case when p_status = 'done'    then p_delta else 0 end,
         verses_flagged = verses_flagged + case when p_status = 'flagged' then p_delta else 0 end
   where id = p_chapter_id;
end;
$$;

create or replace function app.maintain_chapter_counters()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform app.bump_chapter_counter(new.chapter_id, new.status, 1);
  elsif tg_op = 'DELETE' then
    perform app.bump_chapter_counter(old.chapter_id, old.status, -1);
  elsif new.status is distinct from old.status
     or new.chapter_id is distinct from old.chapter_id then
    perform app.bump_chapter_counter(old.chapter_id, old.status, -1);
    perform app.bump_chapter_counter(new.chapter_id, new.status, 1);
  end if;
  return null;
end;
$$;

create trigger verse_maintain_counters
  after insert or delete or update of status, chapter_id on app.verse
  for each row execute function app.maintain_chapter_counters();

create or replace function app.maintain_unresolved_comment_count()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and new.resolved_at is null then
    update app.verse set unresolved_comment_count = unresolved_comment_count + 1
     where id = new.verse_id;
  elsif tg_op = 'DELETE' and old.resolved_at is null then
    update app.verse set unresolved_comment_count = unresolved_comment_count - 1
     where id = old.verse_id;
  elsif tg_op = 'UPDATE' and (old.resolved_at is null) is distinct from (new.resolved_at is null) then
    update app.verse
       set unresolved_comment_count = unresolved_comment_count
             + case when new.resolved_at is null then 1 else -1 end
     where id = new.verse_id;
  end if;
  return null;
end;
$$;

create trigger comment_maintain_verse_count
  after insert or delete or update of resolved_at on app.comment
  for each row execute function app.maintain_unresolved_comment_count();

-- ---------------------------------------------------------------------------
-- Reconciliation (R-PERF-4)
--
-- Counters drift; the question is only whether drift is detectable. Runs in CI
-- against the seeded fixture and is available to operators.
-- ---------------------------------------------------------------------------

create or replace function app.reconcile_chapter_counters(p_fix boolean default false)
returns table (chapter_id uuid, column_name text, stored int, actual int)
language plpgsql
set search_path = ''
as $$
begin
  if p_fix then
    update app.chapter c
       set verses_empty   = k.n_empty,
           verses_draft   = k.n_draft,
           verses_done    = k.n_done,
           verses_flagged = k.n_flagged
      from (
        select ch.id as chapter_id,
               count(*) filter (where v.status = 'empty')   ::int as n_empty,
               count(*) filter (where v.status = 'draft')   ::int as n_draft,
               count(*) filter (where v.status = 'done')    ::int as n_done,
               count(*) filter (where v.status = 'flagged') ::int as n_flagged
          from app.chapter ch
          left join app.verse v on v.chapter_id = ch.id
         group by ch.id
      ) k
     where k.chapter_id = c.id;
  end if;

  return query
  with counted as (
    select ch.id as chapter_id,
           count(*) filter (where v.status = 'empty')   ::int as n_empty,
           count(*) filter (where v.status = 'draft')   ::int as n_draft,
           count(*) filter (where v.status = 'done')    ::int as n_done,
           count(*) filter (where v.status = 'flagged') ::int as n_flagged
      from app.chapter ch
      left join app.verse v on v.chapter_id = ch.id
     group by ch.id
  )
  select c.id, x.col_name, x.stored_value, x.actual_value
    from app.chapter c
    join counted k on k.chapter_id = c.id
   cross join lateral (values
      ('verses_empty',   c.verses_empty,   k.n_empty),
      ('verses_draft',   c.verses_draft,   k.n_draft),
      ('verses_done',    c.verses_done,    k.n_done),
      ('verses_flagged', c.verses_flagged, k.n_flagged)
   ) as x(col_name, stored_value, actual_value)
   where x.stored_value is distinct from x.actual_value;
end;
$$;

-- ---------------------------------------------------------------------------
-- Project materialisation (R-DATA-3)
--
-- Creating a project writes books, chapters, and empty verse rows from the
-- chosen versification scheme, so a verse row exists before anyone types into
-- it. The app never creates a verse; it only writes text into one. This makes
-- APP R-WF-1 ("no empty verses") a counting query rather than an
-- absence-of-row inference.
--
-- Console operation, run with the service key. Not exposed in `api`.
-- ---------------------------------------------------------------------------

create or replace function app.materialise_book(p_project_id uuid, p_book_code text)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_scheme        text;
  v_book_id       uuid;
  v_chapter_id    uuid;
  v_chapter_count int;
  v_chapter       record;
begin
  select versification_scheme into v_scheme
    from app.project where id = p_project_id;

  if v_scheme is null then
    raise exception 'project_not_found'
      using errcode = 'PT404', detail = format('{"project_id": "%s"}', p_project_id);
  end if;

  select count(*) into v_chapter_count
    from ref.versification
   where scheme_code = v_scheme and book_code = p_book_code;

  -- A book cannot be added until its versification rows exist. Only Matthew is
  -- seeded; the rest must come from an authoritative source (see migration
  -- 20260811000002).
  if v_chapter_count = 0 then
    raise exception 'versification_missing'
      using errcode = 'PT422',
            detail  = format('{"scheme": "%s", "book": "%s"}', v_scheme, p_book_code);
  end if;

  -- Seeded from the English canonical name. app.book.name is per-project and
  -- editable from the console, which is where a vernacular name is set
  -- (APP R-L10N-1).
  insert into app.book (project_id, code, name, sort_order, chapter_count)
  select p_project_id, b.code, b.name_en, b.sort_order, v_chapter_count
    from ref.book_canon b
   where b.code = p_book_code
  returning id into v_book_id;

  for v_chapter in
    select chapter_number, verse_count
      from ref.versification
     where scheme_code = v_scheme and book_code = p_book_code
     order by chapter_number
  loop
    insert into app.chapter (book_id, project_id, number, verse_count)
    values (v_book_id, p_project_id, v_chapter.chapter_number, v_chapter.verse_count)
    returning id into v_chapter_id;

    -- Counters are maintained by the trigger as these rows land, so there is
    -- one source of truth for them even at materialisation.
    insert into app.verse (chapter_id, project_id, number)
    select v_chapter_id, p_project_id, generate_series(1, v_chapter.verse_count);
  end loop;

  return v_book_id;
end;
$$;
