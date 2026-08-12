-- The read API: views in `api`, plus rpc/me.
--
-- Requirements: DB §3.2 (operation mapping), R-TRANSPORT-5, R-RLS-13/14,
-- R-API-DB-3, R-DATA-5.
--
-- ===========================================================================
-- EVERY view here is created WITH (security_invoker = true).
--
-- Without it, a view over an RLS-protected table runs as the view's OWNER and
-- returns every row in the table to every caller — a hole straight through the
-- policies in migration 0007, and the single most consequential detail in this
-- schema. It is not optional and it is not a performance setting.
--
-- Author columns are LEFT JOINed to app.profile, never inner-joined, so a row
-- whose author is anonymised (R-DATA-5) or no longer readable still appears
-- with a null name. The app renders "Former contributor" (APP R-LEGAL-2). A
-- missing author is worse than a tombstoned one.
--
-- Columns are enumerated, never `*` (R-API-DB-3), so that adding a column to a
-- base table is not a silent bandwidth regression on metered connections, and
-- internal bookkeeping (folded search text, counters, xact ids) stays internal.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

create view api.project with (security_invoker = true) as
select p.id,
       p.name,
       p.language_name,
       p.language_code,
       p.script_code,
       p.text_direction,
       p.font_id,
       p.font_size_sp,
       p.line_height_multiplier,
       app.role_in_project(p.id) as my_role
  from app.project p
 where p.archived_at is null;

comment on view api.project is 'APP §13.4 GET /projects and /projects/{id}.';

-- ---------------------------------------------------------------------------
-- Books, with per-book progress (APP §8.3 — precomputed, R-PERF-3)
--
-- Aggregates over chapter counters: hundreds of rows per project, not tens of
-- thousands of verses.
-- ---------------------------------------------------------------------------

create view api.book with (security_invoker = true) as
select b.id,
       b.project_id,
       b.code,
       b.name,
       b.sort_order,
       b.chapter_count,
       coalesce(sum(c.verse_count), 0)::int                                     as verse_count,
       coalesce(sum(c.verses_done), 0)::int                                     as verses_done,
       coalesce(sum(c.verses_empty), 0)::int                                    as verses_empty,
       coalesce(sum(c.verses_flagged), 0)::int                                  as verses_flagged,
       count(c.id) filter (where c.workflow_state = 'approved')::int            as chapters_approved,
       count(c.id) filter (where c.workflow_state = 'in_review')::int           as chapters_in_review
  from app.book b
  left join app.chapter c on c.book_id = b.id
 group by b.id, b.project_id, b.code, b.name, b.sort_order, b.chapter_count;

comment on view api.book is 'APP §13.4 GET /projects/{id}/books.';

-- ---------------------------------------------------------------------------
-- Chapters
--
-- Assignment is exposed as id + display name rather than a nested object: the
-- app's API-client module builds the domain Author type (R-TRANSPORT-3), and a
-- flat view keeps PostgREST column selection and filtering usable.
-- ---------------------------------------------------------------------------

create view api.chapter with (security_invoker = true) as
select c.id,
       c.book_id,
       c.project_id,
       c.number,
       c.verse_count,
       c.workflow_state,
       c.assigned_translator_id,
       tr.display_name as assigned_translator_name,
       c.assigned_reviewer_id,
       rv.display_name as assigned_reviewer_name,
       c.submitted_at,
       c.approved_at,
       c.approved_by_id,
       ap.display_name as approved_by_name,
       c.verses_flagged as flagged_verse_count,
       c.verses_empty,
       c.verses_draft,
       c.verses_done
  from app.chapter c
  left join app.profile tr on tr.id = c.assigned_translator_id
  left join app.profile rv on rv.id = c.assigned_reviewer_id
  left join app.profile ap on ap.id = c.approved_by_id;

comment on view api.chapter is 'APP §13.4 GET /books/{id}/chapters.';

-- ---------------------------------------------------------------------------
-- Verses
-- ---------------------------------------------------------------------------

create view api.verse with (security_invoker = true) as
select v.id,
       v.chapter_id,
       v.project_id,
       v.number,
       v.text,
       v.rev,
       v.status,
       v.last_modified_by_id,
       lm.display_name as last_modified_by_name,
       v.last_modified_at,
       v.unresolved_comment_count
  from app.verse v
  left join app.profile lm on lm.id = v.last_modified_by_id;

comment on view api.verse is
  'APP §13.4 GET /chapters/{id}/verses. last_modified_by_* drives the editor attribution of APP R-CON-3 / R-UI-4 — the only signal a translator gets that someone else has been in the verse.';

-- ---------------------------------------------------------------------------
-- Revisions
--
-- `ordinal` is computed here so the app never derives it from `rev`. Revisions
-- are a subset of writes, so rev values are non-contiguous (APP §5.1) and the
-- UI must present "Version 1, 2, 3…". Computing it server-side means a
-- paginated history page cannot number itself wrongly.
--
-- The window partitions by verse_id, which is also how the app filters, so
-- Postgres can push the filter below the window rather than numbering the
-- whole table first. Changing the PARTITION BY without changing how this view
-- is queried would quietly turn every history read into a full scan.
-- ---------------------------------------------------------------------------

create view api.verse_revision with (security_invoker = true) as
select r.id,
       r.verse_id,
       r.project_id,
       r.rev,
       (row_number() over (partition by r.verse_id order by r.rev))::int as ordinal,
       r.text,
       r.author_id,
       au.display_name as author_name,
       r.note,
       r.restored_from_revision_id,
       r.created_at
  from app.verse_revision r
  left join app.profile au on au.id = r.author_id;

comment on view api.verse_revision is
  'APP §13.4 GET /verses/{id}/revisions and /revisions/{id}. Order newest-first at the client with rev.desc.';

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------

create view api.comment with (security_invoker = true) as
select k.id,
       k.verse_id,
       k.project_id,
       k.body,
       k.author_id,
       au.display_name as author_name,
       k.created_at,
       k.resolved_at,
       k.resolved_by_id,
       rs.display_name as resolved_by_name
  from app.comment k
  left join app.profile au on au.id = k.author_id
  left join app.profile rs on rs.id = k.resolved_by_id;

comment on view api.comment is 'APP §13.4 GET /verses/{id}/comments.';

-- ---------------------------------------------------------------------------
-- My assignments (APP §13.4 GET /assignments)
--
-- Carries enough book and project context to render "Matthew 5" without a
-- second round trip — the app's first screen after sign-in, on a connection
-- worth economising (APP §2.3).
-- ---------------------------------------------------------------------------

create view api.assignment with (security_invoker = true) as
select c.id           as chapter_id,
       c.number       as chapter_number,
       c.workflow_state,
       c.verse_count,
       c.verses_empty,
       c.verses_draft,
       c.verses_done,
       c.verses_flagged as flagged_verse_count,
       c.submitted_at,
       b.id           as book_id,
       b.code         as book_code,
       b.name         as book_name,
       b.sort_order   as book_sort_order,
       p.id           as project_id,
       p.name         as project_name
  from app.chapter c
  join app.book b    on b.id = c.book_id
  join app.project p on p.id = c.project_id
 where c.assigned_translator_id = (select app.current_profile_id())
   and p.archived_at is null;

comment on view api.assignment is
  'Chapters assigned to the caller as translator, across projects. Group by workflow_state in the UI (APP §10.1).';

-- ---------------------------------------------------------------------------
-- Review queue (APP §13.4 GET /review-queue)
-- ---------------------------------------------------------------------------

create view api.review_queue with (security_invoker = true) as
select c.id           as chapter_id,
       c.number       as chapter_number,
       c.verse_count,
       c.verses_flagged as flagged_verse_count,
       c.submitted_at,
       c.assigned_translator_id,
       tr.display_name as assigned_translator_name,
       b.id           as book_id,
       b.code         as book_code,
       b.name         as book_name,
       b.sort_order   as book_sort_order,
       p.id           as project_id,
       p.name         as project_name
  from app.chapter c
  join app.book b    on b.id = c.book_id
  join app.project p on p.id = c.project_id
  left join app.profile tr on tr.id = c.assigned_translator_id
 where c.assigned_reviewer_id = (select app.current_profile_id())
   and c.workflow_state = 'in_review'
   and p.archived_at is null;

comment on view api.review_queue is 'Chapters awaiting this caller''s review.';

-- ---------------------------------------------------------------------------
-- Project progress (APP §13.4 GET /projects/{id}/progress, §8.3)
-- ---------------------------------------------------------------------------

create view api.project_progress with (security_invoker = true) as
select p.id as project_id,
       count(distinct b.id)::int                                      as book_count,
       count(c.id)::int                                               as chapter_count,
       count(c.id) filter (where c.workflow_state = 'approved')::int   as chapters_approved,
       count(c.id) filter (where c.workflow_state = 'in_review')::int  as chapters_in_review,
       count(c.id) filter (where c.workflow_state = 'in_progress')::int as chapters_in_progress,
       count(c.id) filter (where c.workflow_state = 'not_started')::int as chapters_not_started,
       coalesce(sum(c.verse_count), 0)::int                            as verse_count,
       coalesce(sum(c.verses_done), 0)::int                            as verses_done,
       coalesce(sum(c.verses_draft), 0)::int                           as verses_draft,
       coalesce(sum(c.verses_empty), 0)::int                           as verses_empty,
       coalesce(sum(c.verses_flagged), 0)::int                         as verses_flagged
  from app.project p
  left join app.book b    on b.project_id = p.id
  left join app.chapter c on c.book_id = b.id
 where p.archived_at is null
 group by p.id;

comment on view api.project_progress is
  'Served from maintained counters, never by aggregating verse rows (R-PERF-1).';

-- ---------------------------------------------------------------------------
-- rpc/me (APP §13.2 GET /me)
--
-- One round trip for identity, the must-change-password flag, and every
-- project membership with its role and display settings — the app needs all of
-- it before it can render anything.
--
-- SECURITY DEFINER, deliberately: the caller must be able to read their own
-- identity and the password flag BEFORE the R-AUTH-DB-8 gate opens, or the app
-- cannot tell them to change their password. The projects list is withheld
-- until the flag clears, so the gate still holds for project data.
-- ---------------------------------------------------------------------------

create or replace function api.me()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'profile_id',           p.id,
    'display_name',         p.display_name,
    'must_change_password', p.must_change_password,
    'anonymised',           p.anonymised_at is not null,
    'projects',
      case when p.must_change_password then '[]'::jsonb
      else coalesce((
        select jsonb_agg(
                 jsonb_build_object(
                   'project_id',             pr.id,
                   'name',                   pr.name,
                   'role',                   m.role,
                   'language_name',          pr.language_name,
                   'language_code',          pr.language_code,
                   'script_code',            pr.script_code,
                   'text_direction',         pr.text_direction,
                   'font_id',                pr.font_id,
                   'font_size_sp',           pr.font_size_sp,
                   'line_height_multiplier', pr.line_height_multiplier
                 ) order by pr.name)
          from app.project_member m
          join app.project pr on pr.id = m.project_id
         where m.profile_id = p.id
           and pr.archived_at is null
      ), '[]'::jsonb)
      end
  )
    from app.profile p
   where p.auth_user_id = (select auth.uid());
$$;

comment on function api.me() is
  'Identity, must-change-password flag, and project memberships in one call. Projects are withheld until the password change completes (R-AUTH-DB-8).';

-- ---------------------------------------------------------------------------
-- Grants
--
-- R-RLS-5: SELECT on views only. No table in `app` is writable by this role,
-- and no write RPC exists yet — those arrive with the next migration.
-- ---------------------------------------------------------------------------

grant select on api.project          to authenticated;
grant select on api.book             to authenticated;
grant select on api.chapter          to authenticated;
grant select on api.verse            to authenticated;
grant select on api.verse_revision   to authenticated;
grant select on api.comment          to authenticated;
grant select on api.assignment       to authenticated;
grant select on api.review_queue     to authenticated;
grant select on api.project_progress to authenticated;

grant execute on function api.me() to authenticated;
