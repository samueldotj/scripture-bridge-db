-- The console API (DB §13.6, R-AUTH-DB-12).
--
-- Project setup, membership, assignment, and reopen are console-only
-- operations with no app-facing surface. They were previously raw SQL inside
-- scripts/provision.sh, which meant two problems:
--
--   1. Two implementations of the same rules. The console would have been a
--      third, and the audit logging a fourth place to remember.
--   2. Assignment wrote no change-log entry, so a chapter assigned by a
--      coordinator would never reach a device through delta sync. The
--      translator would be assigned work their app could not see until a full
--      refetch. That is fixed here.
--
-- Everything below is granted to service_role ONLY. A project admin must not be
-- able to reassign chapters or reopen approved work through the app's own API
-- surface; that is a console action performed by a coordinator.

-- ---------------------------------------------------------------------------
-- Who did it
--
-- R-AUTH-DB-12 requires privileged operations to record the acting operator.
-- Until now console entries carried actor_kind='console' and a null profile,
-- which says "a console did this" and not which coordinator. The console
-- authenticates its own operators outside this schema, so it passes a label.
-- ---------------------------------------------------------------------------

alter table app.audit_log add column if not exists actor_label text;

comment on column app.audit_log.actor_label is
  'Operator identity supplied by the console, which authenticates its own users outside this schema. Null for actions taken by a signed-in app user, whose identity is in actor_profile_id.';

create or replace function app.console_audit(
  p_action      text,
  p_target_type text,
  p_target_id   uuid,
  p_operator    text default null,
  p_before      jsonb default null,
  p_after       jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into app.audit_log
    (actor_kind, actor_label, action, target_type, target_id, before, after)
  values
    ('console', p_operator, p_action, p_target_type, p_target_id, p_before, p_after);
$$;

-- ---------------------------------------------------------------------------
-- Project creation
-- ---------------------------------------------------------------------------

create or replace function api.create_project(
  p_name                 text,
  p_language_name        text,
  p_language_code        text,
  p_script_code          text,
  p_versification_scheme text default 'eng',
  p_text_direction       text default 'ltr',
  p_books                text[] default array['MAT'],
  p_operator             text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project uuid;
  v_book    text;
  v_count   int := 0;
begin
  if p_text_direction not in ('ltr', 'rtl') then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'text_direction', 'value', p_text_direction));
  end if;

  if not exists (select 1 from ref.versification_scheme
                  where code = p_versification_scheme) then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'versification_scheme', 'value', p_versification_scheme));
  end if;

  insert into app.project (name, language_name, language_code, script_code,
                           text_direction, versification_scheme)
  values (p_name, p_language_name, p_language_code, p_script_code,
          p_text_direction, p_versification_scheme)
  returning id into v_project;

  -- materialise_book raises versification_missing if the scheme has no data for
  -- a book, which is the guard against creating a project whose verse counts
  -- are silently wrong (R-DATA-2).
  foreach v_book in array p_books loop
    perform app.materialise_book(v_project, v_book);
    v_count := v_count + 1;
  end loop;

  perform app.console_audit('project.create', 'project', v_project, p_operator,
    null, jsonb_build_object('name', p_name, 'scheme', p_versification_scheme,
                             'books', p_books));

  return jsonb_build_object('project_id', v_project, 'books_materialised', v_count);
end;
$$;

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------

create or replace function api.add_project_member(
  p_project_id uuid,
  p_profile_id uuid,
  p_role       text,
  p_operator   text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before text;
begin
  if p_role not in ('admin', 'translator', 'reviewer') then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'role', 'value', p_role));
  end if;

  if not exists (select 1 from app.project where id = p_project_id) then
    perform app.error('not_found', 404, jsonb_build_object('project_id', p_project_id));
  end if;
  if not exists (select 1 from app.profile where id = p_profile_id) then
    perform app.error('not_found', 404, jsonb_build_object('profile_id', p_profile_id));
  end if;

  select role into v_before from app.project_member
   where project_id = p_project_id and profile_id = p_profile_id;

  insert into app.project_member (project_id, profile_id, role)
  values (p_project_id, p_profile_id, p_role)
      on conflict (project_id, profile_id) do update set role = excluded.role;

  perform app.console_audit('member.upsert', 'project', p_project_id, p_operator,
    case when v_before is null then null else jsonb_build_object('role', v_before) end,
    jsonb_build_object('profile_id', p_profile_id, 'role', p_role));

  return jsonb_build_object('project_id', p_project_id, 'profile_id', p_profile_id,
                            'role', p_role, 'previous_role', v_before);
end;
$$;

-- ---------------------------------------------------------------------------
-- Assignment
--
-- Writes a change-log entry, which the raw-SQL version did not. Without it a
-- coordinator's assignment never reaches the device: delta sync is the only
-- way the app learns anything changed (R-SYNC-1), so the translator would be
-- assigned work their app could not see.
-- ---------------------------------------------------------------------------

create or replace function api.assign_chapter(
  p_chapter_id    uuid,
  p_translator_id uuid default null,
  p_reviewer_id   uuid default null,
  p_operator      text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chapter app.chapter;
  v_before  jsonb;
begin
  select * into v_chapter from app.chapter where id = p_chapter_id;
  if not found then
    perform app.error('not_found', 404, jsonb_build_object('chapter_id', p_chapter_id));
  end if;

  -- Assigning someone who is not a member produces a chapter whose assignee
  -- cannot read it: the app would show them nothing and the refusal would look
  -- like a bug rather than a mis-assignment.
  if p_translator_id is not null
     and not exists (select 1 from app.project_member
                      where project_id = v_chapter.project_id
                        and profile_id = p_translator_id) then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'translator_id', 'reason', 'not_a_project_member'));
  end if;

  if p_reviewer_id is not null
     and not exists (select 1 from app.project_member
                      where project_id = v_chapter.project_id
                        and profile_id = p_reviewer_id) then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'reviewer_id', 'reason', 'not_a_project_member'));
  end if;

  v_before := app.chapter_state(p_chapter_id);

  update app.chapter
     set assigned_translator_id = p_translator_id,
         assigned_reviewer_id   = p_reviewer_id
   where id = p_chapter_id;

  perform app.log_change(v_chapter.project_id, 'chapter', p_chapter_id,
                         app.chapter_state(p_chapter_id));
  perform app.console_audit('chapter.assign', 'chapter', p_chapter_id, p_operator,
                            v_before, app.chapter_state(p_chapter_id));

  return app.chapter_state(p_chapter_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Reopen (R-FN-14, APP §8.1)
--
-- R-FN-14 said this existed in `api` and it never did. An approved chapter is
-- read-only (APP R-WF-3), and reopening is the ONLY way back - without it,
-- an approval made in error is permanent.
-- ---------------------------------------------------------------------------

create or replace function api.reopen_chapter(
  p_chapter_id uuid,
  p_note       text default null,
  p_operator   text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chapter app.chapter;
  v_before  jsonb;
begin
  select * into v_chapter from app.chapter where id = p_chapter_id;
  if not found then
    perform app.error('not_found', 404, jsonb_build_object('chapter_id', p_chapter_id));
  end if;

  if v_chapter.workflow_state <> 'approved' then
    perform app.error('invalid_transition', 409,
      jsonb_build_object('chapter_id', p_chapter_id,
                         'from', v_chapter.workflow_state, 'to', 'in_progress'));
  end if;

  v_before := app.chapter_state(p_chapter_id);

  update app.chapter
     set workflow_state = 'in_progress',
         approved_at    = null,
         approved_by_id = null,
         submitted_at   = null
   where id = p_chapter_id;

  perform app.log_change(v_chapter.project_id, 'chapter', p_chapter_id,
                         app.chapter_state(p_chapter_id));
  perform app.console_audit('chapter.reopen', 'chapter', p_chapter_id, p_operator,
    v_before, app.chapter_state(p_chapter_id) || jsonb_build_object('note', p_note));

  return app.chapter_state(p_chapter_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Provisioning support
--
-- The auth user is created through the GoTrue admin API, which is HTTP and
-- stays in the console. The profile arrives by trigger; this resolves it, so
-- the console does not need to know the profile table exists.
-- ---------------------------------------------------------------------------

create or replace function api.profile_for_auth_user(p_auth_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile app.profile;
begin
  select * into v_profile from app.profile where auth_user_id = p_auth_user_id;
  if not found then
    perform app.error('not_found', 404,
      jsonb_build_object('auth_user_id', p_auth_user_id));
  end if;
  return jsonb_build_object(
    'profile_id',           v_profile.id,
    'display_name',         v_profile.display_name,
    'must_change_password', v_profile.must_change_password);
end;
$$;

-- Re-arms the forced change after an administrative reset, and re-fingerprints
-- so complete_password_change compares against the new hash rather than a stale
-- one (R-AUTH-DB-7). The password itself is set through the admin API.
create or replace function api.rearm_password_change(
  p_profile_id uuid,
  p_operator   text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth uuid;
begin
  select auth_user_id into v_auth from app.profile where id = p_profile_id;
  if v_auth is null then
    perform app.error('not_found', 404, jsonb_build_object('profile_id', p_profile_id));
  end if;

  update app.profile
     set must_change_password         = true,
         initial_password_fingerprint =
           (select md5(coalesce(u.encrypted_password, '')) from auth.users u where u.id = v_auth)
   where id = p_profile_id;

  perform app.console_audit('profile.password_reset', 'profile', p_profile_id, p_operator);

  return jsonb_build_object('profile_id', p_profile_id, 'must_change_password', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- service_role only. Revoked from public first, because a function granted to
-- PUBLIC by default and then granted to service_role is still callable by
-- `authenticated` - and any of these in an app user's hands is an escalation.
-- ---------------------------------------------------------------------------

do $$
declare
  f text;
begin
  foreach f in array array[
    'api.create_project(text, text, text, text, text, text, text[], text)',
    'api.add_project_member(uuid, uuid, text, text)',
    'api.assign_chapter(uuid, uuid, uuid, text)',
    'api.reopen_chapter(uuid, text, text)',
    'api.profile_for_auth_user(uuid)',
    'api.rearm_password_change(uuid, text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('revoke all on function %s from authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;
