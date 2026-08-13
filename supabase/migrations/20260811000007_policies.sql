-- Row Level Security: the whole of authorisation.
--
-- Requirements: DB §6, R-RLS-1..14, R-API-5, R-AUTH-DB-8.
--
-- ===========================================================================
-- READ THIS BEFORE CHANGING ANYTHING IN THIS FILE
--
-- 1. There are NO write policies, anywhere, deliberately. `authenticated` holds
--    no INSERT/UPDATE/DELETE grant on any table (R-RLS-5), so a write policy
--    would grant nothing and would falsely suggest a client write path exists.
--    All writes go through SECURITY DEFINER RPCs (R-TRANSPORT-4).
--
-- 2. Those RPCs bypass RLS, by design. They are owned by a role with BYPASSRLS
--    (`postgres` on Supabase), which is what makes them able to write to tables
--    carrying FORCE ROW LEVEL SECURITY. This is the reason R-RLS-4 requires
--    every one of them to re-establish the caller's permission explicitly, as
--    its first action, using the helpers below. A SECURITY DEFINER function
--    that forgets that check is a privilege escalation with the API's own
--    signature on it.
--
-- 3. Policies use `x in (select app.my_project_ids())`. The subquery is
--    evaluated once per statement as a hashed SubPlan rather than once per row
--    (R-RLS-10). Rewriting it as a per-row function call silently turns a
--    constant-time check into a per-row one on a 31,000-row table.
--
--    Do NOT "optimise" this into `= any ((select ...))` by analogy with the
--    scalar `(select auth.uid())` idiom — a parenthesised sub-SELECT in ANY
--    position is read as a subquery, not an array, and the whole migration
--    fails with "operator does not exist: uuid = uuid[]".
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- The caller's project set
--
-- One membership lookup per statement, returned as an array so every content
-- policy is a single equality test against it.
--
-- R-AUTH-DB-8: returns empty until the forced password change is complete, so
-- a user who has not changed their password reaches no project data at all.
-- The gate is here, in the database, not in the app's navigation.
-- ---------------------------------------------------------------------------

-- Returns a SET, not an array, so policies can say `x in (select ...)`.
--
-- An earlier version returned uuid[] and policies used
-- `x in (select app.my_project_ids())`. That does not work: when the
-- operand of ANY is parenthesised as a sub-SELECT, Postgres uses subquery
-- semantics and compares the left side against each returned ROW — whose type
-- is uuid[] — giving "operator does not exist: uuid = uuid[]". The scalar
-- `(select auth.uid())` idiom does not generalise to arrays.
--
-- `in (select ...)` gets the same once-per-statement evaluation as a hashed
-- SubPlan, and is ordinary SQL that reads correctly.
create or replace function app.my_project_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.project_id
    from app.project_member m
   where m.profile_id = (select app.current_profile_id())
     and (select app.password_change_complete());
$$;

comment on function app.my_project_ids() is
  'Projects the caller may read. Empty while must_change_password is set (R-AUTH-DB-8).';

grant execute on function app.my_project_ids() to authenticated;

-- ---------------------------------------------------------------------------
-- Write-permission helper
--
-- R-RLS-12: write access is narrower than read access. Text and status writes
-- require assignment as translator on that chapter; review operations require
-- assignment as reviewer; both require the chapter not be approved
-- (APP R-WF-3). Project admins may act in either capacity.
--
-- Used by the write RPCs, not by any policy — there are no write policies.
-- It lives here so that the rule has exactly one implementation (R-RLS-8).
-- ---------------------------------------------------------------------------

create or replace function app.can_edit_verse(p_verse_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from app.verse v
      join app.chapter c on c.id = v.chapter_id
     where v.id = p_verse_id
       and c.workflow_state <> 'approved'
       and (select app.is_member(v.project_id))
       and (
             c.assigned_translator_id = (select app.current_profile_id())
          or c.assigned_reviewer_id   = (select app.current_profile_id())
          or (select app.role_in_project(v.project_id)) = 'admin'
       )
  );
$$;

comment on function app.can_edit_verse(uuid) is
  'Membership + assignment + chapter not approved. The API still returns distinct typed errors for each cause (R-ERR-3), so this is a guard, not the error source.';

grant execute on function app.can_edit_verse(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Reference data
--
-- Not secret, but not public either: R-RLS-2 gives `anon` nothing anywhere.
-- Readable before the password gate opens, because it contains no project data.
-- ---------------------------------------------------------------------------

alter table ref.versification_scheme enable row level security;
alter table ref.versification_scheme force row level security;
alter table ref.book_canon           enable row level security;
alter table ref.book_canon           force row level security;
alter table ref.versification        enable row level security;
alter table ref.versification        force row level security;

create policy versification_scheme_select on ref.versification_scheme
  for select to authenticated using (true);

create policy book_canon_select on ref.book_canon
  for select to authenticated using (true);

create policy versification_select on ref.versification
  for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- Profiles
--
-- A caller reads their own profile, plus the profiles of people they share a
-- project with — needed to render authorship on verses, revisions, and
-- comments.
--
-- CONSEQUENCE, deliberate: a contributor who is removed from a project stops
-- being readable, so their name renders as "Former contributor" in history —
-- the same graceful path as anonymisation (APP R-LEGAL-2, R-DATA-5). If that
-- is not acceptable, the fix is for the console to stop hard-deleting
-- membership rows rather than to widen this policy; retaining membership with
-- a removed_at column keeps attribution working. Flagged rather than built,
-- because removing a member should be rare.
--
-- Own-profile access is NOT gated on must_change_password: the app must be
-- able to read the flag in order to show the password screen.
-- ---------------------------------------------------------------------------

create policy profile_select on app.profile
  for select to authenticated
  using (
    auth_user_id = (select auth.uid())
    or exists (
      select 1
        from app.project_member m
       where m.profile_id = profile.id
         and m.project_id in (select app.my_project_ids())
    )
  );

-- ---------------------------------------------------------------------------
-- Projects and membership
-- ---------------------------------------------------------------------------

create policy project_select on app.project
  for select to authenticated
  using (id in (select app.my_project_ids()));

create policy project_member_select on app.project_member
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

-- Fonts are readable when referenced by a project the caller is in. The binary
-- itself lives in Storage under its own policies (R-STORE-1).
create policy font_select on app.font
  for select to authenticated
  using (
    exists (
      select 1 from app.project p
       where p.font_id = font.id
         and p.id in (select app.my_project_ids())
    )
  );

-- ---------------------------------------------------------------------------
-- Content
--
-- R-RLS-11: a member reads ALL content of their projects. Translators are not
-- restricted to assigned chapters for reading — consistency of terminology
-- across a book requires seeing other chapters, and per-chapter read filtering
-- would make offline caching of a book impossible (APP §12).
-- ---------------------------------------------------------------------------

create policy book_select on app.book
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

create policy chapter_select on app.chapter
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

create policy verse_select on app.verse
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

create policy verse_revision_select on app.verse_revision
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

create policy comment_select on app.comment
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

-- ---------------------------------------------------------------------------
-- Sync and per-user bookkeeping
--
-- The app reaches change_log through rpc/changes_since, which applies the
-- snapshot guard of R-SYNC-3. These policies are defence in depth: a direct
-- read must not see another project's changes even if the RPC is bypassed.
-- ---------------------------------------------------------------------------

create policy change_log_select on app.change_log
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

create policy change_log_watermark_select on app.change_log_watermark
  for select to authenticated
  using (project_id in (select app.my_project_ids()));

create policy idempotency_key_select on app.idempotency_key
  for select to authenticated
  using (profile_id = (select app.current_profile_id()));

create policy consent_record_select on app.consent_record
  for select to authenticated
  using (profile_id = (select app.current_profile_id()));

-- ---------------------------------------------------------------------------
-- Audit log: no policy, deliberately.
--
-- RLS is enabled and forced with no policy granting `authenticated` anything,
-- so every read is denied. The audit trail is a console concern, read with the
-- service key (DB §12.2). The absence of a policy here is the intent, not an
-- omission — do not add one without deciding what a translator is entitled to
-- see about privileged operations.
-- ---------------------------------------------------------------------------
