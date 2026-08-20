-- The write API.
--
-- Requirements: DB §3.2, §8, §9, §11.2. Maps to APP §13.3.
--
-- ===========================================================================
-- EVERY function here follows the same order, and the order is load-bearing:
--
--   1. idempotency  — before any work, so a replay never performs it twice
--   2. authorise    — R-RLS-4: these are SECURITY DEFINER and therefore bypass
--                     RLS, so each MUST re-establish the caller's permission
--                     itself. A function here that skips step 2 is a privilege
--                     escalation carrying the API's own signature.
--   3. validate     — workflow rules, as typed errors (R-ERR-3)
--   4. mutate       — one transaction; partial application is how current text
--                     and history come to disagree (R-FN-1)
--   5. log          — change log always; audit for workflow transitions
--   6. return       — the full new state, so the app can settle its local row
--                     without a follow-up read on a metered connection (R-FN-2)
--
-- A raised error rolls back all of it, including the idempotency row, so a
-- rejected write is re-evaluated on retry rather than replaying a stale refusal.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Shared authorisation guard
--
-- R-ERR-3: distinguishes the causes, because "you may not write here" and "this
-- chapter is finished" mean different things to an offline client acting on
-- stale state — one is permanent, the other clears when an admin reopens.
-- ---------------------------------------------------------------------------

-- Every write begins here. Separates "not signed in" from "signed in but still
-- behind the forced password change" (R-AUTH-DB-8), so the app can route the
-- user to the right screen instead of showing a generic refusal.
create or replace function app.assert_can_act()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := app.current_profile_id();
begin
  if v_me is null then
    perform app.error('unauthenticated', 401);
  end if;
  if not app.password_change_complete() then
    perform app.error('must_change_password', 403);
  end if;
  return v_me;
end;
$$;

create or replace function app.assert_can_edit_verse(p_verse_id uuid)
returns app.verse
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verse   app.verse;
  v_chapter app.chapter;
begin
  perform app.assert_can_act();

  select * into v_verse from app.verse where id = p_verse_id;
  if not found then
    perform app.error('not_found', 404);
  end if;

  if not app.is_member(v_verse.project_id) then
    perform app.error('forbidden', 403);
  end if;

  select * into v_chapter from app.chapter where id = v_verse.chapter_id;

  -- R-API-11 / APP R-WF-3: this is the ONLY condition under which a text write
  -- is refused. Never staleness — last write wins (APP §7).
  if v_chapter.workflow_state = 'approved' then
    perform app.error('chapter_locked', 409,
      jsonb_build_object('chapter_id', v_chapter.id));
  end if;

  -- coalesce(..., false) is load-bearing, not defensive noise.
  --
  -- On an UNASSIGNED chapter both columns are NULL, so the comparisons yield
  -- NULL, `NULL or NULL or false` is NULL, `not NULL` is NULL, and `if NULL
  -- then` does not fire. Without the coalesce this check silently permits any
  -- project member to write to any chapter nobody has been assigned - a
  -- three-valued-logic hole that fails OPEN.
  --
  -- It went unnoticed in SQL tests because their fixture chapter has an
  -- assigned translator, making the comparison false rather than NULL. Only an
  -- unassigned chapter reproduces it.
  if not coalesce(
       v_chapter.assigned_translator_id = app.current_profile_id()
    or v_chapter.assigned_reviewer_id   = app.current_profile_id()
    or app.role_in_project(v_verse.project_id) = 'admin',
    false) then
    perform app.error('not_assigned', 403,
      jsonb_build_object('chapter_id', v_chapter.id));
  end if;

  return v_verse;
end;
$$;

create or replace function app.assert_chapter_role(
  p_chapter_id uuid, p_role text)
returns app.chapter
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chapter app.chapter;
  v_me      uuid;
begin
  v_me := app.assert_can_act();

  select * into v_chapter from app.chapter where id = p_chapter_id;
  if not found then
    perform app.error('not_found', 404);
  end if;

  if not app.is_member(v_chapter.project_id) then
    perform app.error('forbidden', 403);
  end if;

  if app.role_in_project(v_chapter.project_id) <> 'admin' then
    if p_role = 'translator' and v_chapter.assigned_translator_id is distinct from v_me then
      perform app.error('not_assigned', 403,
        jsonb_build_object('chapter_id', p_chapter_id, 'required_role', 'translator'));
    elsif p_role = 'reviewer' and v_chapter.assigned_reviewer_id is distinct from v_me then
      perform app.error('not_assigned', 403,
        jsonb_build_object('chapter_id', p_chapter_id, 'required_role', 'reviewer'));
    end if;
  end if;

  return v_chapter;
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /verses/{id}/text  (APP §13.3 — the core save)
--
-- p_reason is an OBSERVATION of what happened in the UI, not an instruction.
-- R-FN-6: APP R-REV-4 puts history policy on the server, but APP §6.2's first
-- commit point ("the user explicitly saves or navigates away") is inherently a
-- client-side event. The client reports the event; the server decides what it
-- means and may ignore it.
-- ---------------------------------------------------------------------------

create or replace function api.save_verse_text(
  p_verse_id uuid,
  p_text     text,
  p_reason   text default 'autosave')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay jsonb;
  v_result jsonb;
begin
  v_replay := app.idempotency_begin('save_verse_text',
    jsonb_build_object('verse_id', p_verse_id, 'text', p_text, 'reason', p_reason));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_reason not in ('autosave', 'explicit_save', 'editor_closed') then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'reason', 'value', p_reason));
  end if;

  perform app.assert_can_edit_verse(p_verse_id);

  v_result := app.write_verse_text(p_verse_id, p_text, p_reason);

  return app.idempotency_complete(v_result);
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /verses/{id}/status
-- ---------------------------------------------------------------------------

create or replace function api.set_verse_status(
  p_verse_id uuid,
  p_status   text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay jsonb;
  v_verse  app.verse;
begin
  v_replay := app.idempotency_begin('set_verse_status',
    jsonb_build_object('verse_id', p_verse_id, 'status', p_status));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_status not in ('draft', 'done') then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'status', 'value', p_status));
  end if;

  v_verse := app.assert_can_edit_verse(p_verse_id);

  -- Marking an empty verse done would let the chapter pass R-WF-1's "no empty
  -- verses" check on submit, since that check reads status, not text.
  if p_status = 'done' and v_verse.text = '' then
    perform app.error('verse_empty', 422, jsonb_build_object('verse_id', p_verse_id));
  end if;

  -- A flagged verse is cleared by resolving its comment (R-REVIEW-3), not by
  -- the translator re-marking it done.
  if v_verse.status = 'flagged' then
    perform app.error('verse_flagged', 422, jsonb_build_object('verse_id', p_verse_id));
  end if;

  update app.verse
     set status              = p_status,
         last_modified_by_id = app.current_profile_id(),
         last_modified_at    = now()
   where id = p_verse_id;

  perform app.log_change(v_verse.project_id, 'verse', p_verse_id,
                         app.verse_state(p_verse_id));

  return app.idempotency_complete(app.verse_state(p_verse_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /verses/{id}/restore
--
-- R-REV-5 / R-FN-10: restoring is a FORWARD operation. Restoring version 3
-- while the verse is at rev 47 creates a NEW revision whose text equals version
-- 3's. The counter is never rewound and no revision is removed.
--
-- Implemented in terms of app.write_verse_text, not beside it, so it cannot
-- drift from the ordinary save path.
-- ---------------------------------------------------------------------------

create or replace function api.restore_revision(
  p_verse_id    uuid,
  p_revision_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay   jsonb;
  v_revision app.verse_revision;
  v_result   jsonb;
begin
  v_replay := app.idempotency_begin('restore_revision',
    jsonb_build_object('verse_id', p_verse_id, 'revision_id', p_revision_id));
  if v_replay is not null then
    return v_replay;
  end if;

  perform app.assert_can_edit_verse(p_verse_id);

  select * into v_revision
    from app.verse_revision
   where id = p_revision_id and verse_id = p_verse_id;

  if not found then
    perform app.error('not_found', 404,
      jsonb_build_object('revision_id', p_revision_id));
  end if;

  v_result := app.write_verse_text(
    p_verse_id, v_revision.text, 'restore', p_revision_id);

  return app.idempotency_complete(v_result);
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /verses/{id}/comments
-- ---------------------------------------------------------------------------

create or replace function api.add_comment(
  p_verse_id uuid,
  p_body     text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay     jsonb;
  v_verse      app.verse;
  v_comment_id uuid;
begin
  v_replay := app.idempotency_begin('add_comment',
    jsonb_build_object('verse_id', p_verse_id, 'body', p_body));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_body is null or btrim(p_body) = '' then
    perform app.error('comment_required', 422,
      jsonb_build_object('verse_id', p_verse_id));
  end if;

  if not app.is_nfc(p_body) then
    perform app.error('text_not_normalized', 422,
      jsonb_build_object('verse_id', p_verse_id));
  end if;

  v_verse := app.assert_can_edit_verse(p_verse_id);

  insert into app.comment (verse_id, project_id, author_id, body)
  values (p_verse_id, v_verse.project_id, app.current_profile_id(), p_body)
  returning id into v_comment_id;

  perform app.log_change(v_verse.project_id, 'comment', v_comment_id,
                         app.comment_state(v_comment_id), 'insert');
  perform app.log_change(v_verse.project_id, 'verse', p_verse_id,
                         app.verse_state(p_verse_id));

  return app.idempotency_complete(app.comment_state(v_comment_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /verses/{id}/flag
--
-- R-REVIEW-2 / R-FN-12: a flag requires a comment, and both are created in one
-- transaction. A reviewer who can flag but cannot say why is not a review loop.
-- ---------------------------------------------------------------------------

create or replace function api.flag_verse(
  p_verse_id uuid,
  p_body     text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay     jsonb;
  v_verse      app.verse;
  v_chapter    app.chapter;
  v_comment_id uuid;
begin
  v_replay := app.idempotency_begin('flag_verse',
    jsonb_build_object('verse_id', p_verse_id, 'body', p_body));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_body is null or btrim(p_body) = '' then
    perform app.error('comment_required', 422,
      jsonb_build_object('verse_id', p_verse_id));
  end if;

  select * into v_verse from app.verse where id = p_verse_id;
  if not found then
    perform app.error('not_found', 404);
  end if;

  v_chapter := app.assert_chapter_role(v_verse.chapter_id, 'reviewer');

  if v_chapter.workflow_state = 'approved' then
    perform app.error('chapter_locked', 409,
      jsonb_build_object('chapter_id', v_chapter.id));
  end if;

  insert into app.comment (verse_id, project_id, author_id, body)
  values (p_verse_id, v_verse.project_id, app.current_profile_id(), p_body)
  returning id into v_comment_id;

  update app.verse set status = 'flagged' where id = p_verse_id;

  perform app.log_change(v_verse.project_id, 'comment', v_comment_id,
                         app.comment_state(v_comment_id), 'insert');
  perform app.log_change(v_verse.project_id, 'verse', p_verse_id,
                         app.verse_state(p_verse_id));

  return app.idempotency_complete(
    jsonb_build_object('comment', app.comment_state(v_comment_id))
    || app.verse_state(p_verse_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /comments/{id}/resolve
--
-- R-REVIEW-3: the translator resolves after addressing the comment. Clearing
-- the last unresolved comment clears the flag, returning the verse to draft
-- rather than to done — the text changed, so it needs re-confirming.
-- ---------------------------------------------------------------------------

create or replace function api.resolve_comment(p_comment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay    jsonb;
  v_comment   app.comment;
  v_verse     app.verse;
  v_remaining int;
begin
  v_replay := app.idempotency_begin('resolve_comment',
    jsonb_build_object('comment_id', p_comment_id));
  if v_replay is not null then
    return v_replay;
  end if;

  select * into v_comment from app.comment where id = p_comment_id;
  if not found then
    perform app.error('not_found', 404);
  end if;

  v_verse := app.assert_can_edit_verse(v_comment.verse_id);

  if v_comment.resolved_at is null then
    update app.comment
       set resolved_at    = now(),
           resolved_by_id = app.current_profile_id()
     where id = p_comment_id;

    select count(*) into v_remaining
      from app.comment
     where verse_id = v_comment.verse_id and resolved_at is null;

    if v_remaining = 0 and v_verse.status = 'flagged' then
      update app.verse
         set status = case when text = '' then 'empty' else 'draft' end
       where id = v_comment.verse_id;
    end if;

    perform app.log_change(v_comment.project_id, 'comment', p_comment_id,
                           app.comment_state(p_comment_id));
    perform app.log_change(v_comment.project_id, 'verse', v_comment.verse_id,
                           app.verse_state(v_comment.verse_id));
  end if;

  return app.idempotency_complete(app.comment_state(p_comment_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /chapters/{id}/submit
--
-- R-FN-11: validates against counters AND re-verifies against source rows in
-- the same transaction. Approving or submitting on a stale counter is not
-- recoverable without an admin reopen.
-- ---------------------------------------------------------------------------

create or replace function api.submit_chapter(p_chapter_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay  jsonb;
  v_chapter app.chapter;
  v_empty   int;
  v_before  jsonb;
begin
  v_replay := app.idempotency_begin('submit_chapter',
    jsonb_build_object('chapter_id', p_chapter_id));
  if v_replay is not null then
    return v_replay;
  end if;

  v_chapter := app.assert_chapter_role(p_chapter_id, 'translator');
  v_before  := app.chapter_state(p_chapter_id);

  -- R-FN-13: an invalid transition is a typed error, not a silent no-op. An
  -- offline client acting on stale chapter state is expected here.
  if v_chapter.workflow_state <> 'in_progress' then
    perform app.error('invalid_transition', 409,
      jsonb_build_object('chapter_id', p_chapter_id,
                         'from', v_chapter.workflow_state, 'to', 'in_review'));
  end if;

  select count(*) into v_empty
    from app.verse
   where chapter_id = p_chapter_id and (status = 'empty' or text = '');

  if v_empty > 0 then
    perform app.error('chapter_not_ready', 422,
      jsonb_build_object('chapter_id', p_chapter_id, 'empty_verse_count', v_empty));
  end if;

  update app.chapter
     set workflow_state = 'in_review',
         submitted_at   = now()
   where id = p_chapter_id;

  perform app.log_change(v_chapter.project_id, 'chapter', p_chapter_id,
                         app.chapter_state(p_chapter_id));
  perform app.audit('chapter.submit', 'chapter', p_chapter_id,
                    v_before, app.chapter_state(p_chapter_id));

  return app.idempotency_complete(app.chapter_state(p_chapter_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- POST /chapters/{id}/review
-- ---------------------------------------------------------------------------

create or replace function api.review_chapter(
  p_chapter_id uuid,
  p_decision   text,
  p_note       text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_replay  jsonb;
  v_chapter app.chapter;
  v_flagged int;
  v_before  jsonb;
begin
  v_replay := app.idempotency_begin('review_chapter',
    jsonb_build_object('chapter_id', p_chapter_id,
                       'decision', p_decision, 'note', p_note));
  if v_replay is not null then
    return v_replay;
  end if;

  if p_decision not in ('approve', 'return') then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'decision', 'value', p_decision));
  end if;

  v_chapter := app.assert_chapter_role(p_chapter_id, 'reviewer');
  v_before  := app.chapter_state(p_chapter_id);

  if v_chapter.workflow_state <> 'in_review' then
    perform app.error('invalid_transition', 409,
      jsonb_build_object('chapter_id', p_chapter_id,
                         'from', v_chapter.workflow_state, 'to', p_decision));
  end if;

  if p_decision = 'approve' then
    select count(*) into v_flagged
      from app.verse
     where chapter_id = p_chapter_id and status = 'flagged';

    if v_flagged > 0 then
      perform app.error('chapter_has_flags', 422,
        jsonb_build_object('chapter_id', p_chapter_id,
                           'flagged_verse_count', v_flagged));
    end if;

    update app.chapter
       set workflow_state = 'approved',
           approved_at    = now(),
           approved_by_id = app.current_profile_id()
     where id = p_chapter_id;
  else
    -- APP §8.1: needs_correction is not a separate state. A returned chapter
    -- goes back to in_progress, with its flagged verses carrying the detail.
    update app.chapter
       set workflow_state = 'in_progress',
           submitted_at   = null
     where id = p_chapter_id;
  end if;

  perform app.log_change(v_chapter.project_id, 'chapter', p_chapter_id,
                         app.chapter_state(p_chapter_id));
  perform app.audit('chapter.review.' || p_decision, 'chapter', p_chapter_id,
                    v_before, app.chapter_state(p_chapter_id));

  return app.idempotency_complete(app.chapter_state(p_chapter_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- Account operations
-- ---------------------------------------------------------------------------

-- R-AUTH-DB-7: clears must_change_password only after VERIFYING the password
-- actually changed, by comparing a fingerprint of the stored hash against the
-- one captured at provisioning. Trusting the client's assertion would make the
-- forced change advisory, and the out-of-band initial password is known to at
-- least two people (APP R-AUTH-6).
--
-- No idempotency key: this is not a queued outbox operation, it happens
-- interactively at sign-in while the device is online.
create or replace function api.complete_password_change()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile app.profile;
  v_current text;
begin
  select * into v_profile
    from app.profile
   where auth_user_id = (select auth.uid());

  if not found then
    perform app.error('unauthenticated', 401);
  end if;

  select md5(coalesce(u.encrypted_password, ''))
    into v_current
    from auth.users u
   where u.id = v_profile.auth_user_id;

  if v_profile.initial_password_fingerprint is not null
     and v_current = v_profile.initial_password_fingerprint then
    perform app.error('password_unchanged', 422);
  end if;

  update app.profile
     set must_change_password         = false,
         initial_password_fingerprint = null
   where id = v_profile.id;

  perform app.audit('profile.password_changed', 'profile', v_profile.id);

  return jsonb_build_object('must_change_password', false);
end;
$$;

-- APP R-LEGAL-1: the app presents the consent notice at first sign-in and
-- records the acknowledgement through the API. Versioned so a changed notice
-- can be re-presented (R-COMPLY-1).
create or replace function api.record_consent(p_version text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile uuid := app.current_profile_id();
begin
  if v_profile is null then
    perform app.error('unauthenticated', 401);
  end if;

  insert into app.consent_record (profile_id, version)
  values (v_profile, p_version)
  on conflict (profile_id, version) do nothing;

  return jsonb_build_object('version', p_version, 'accepted', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- R-RLS-6: EXECUTE was revoked from PUBLIC by default in migration 0001, so
-- each function must be granted explicitly. Internal app.* helpers are NOT
-- granted — they are reachable only from these SECURITY DEFINER functions.
-- ---------------------------------------------------------------------------

grant execute on function api.save_verse_text(uuid, text, text) to authenticated;
grant execute on function api.set_verse_status(uuid, text)      to authenticated;
grant execute on function api.restore_revision(uuid, uuid)      to authenticated;
grant execute on function api.add_comment(uuid, text)           to authenticated;
grant execute on function api.flag_verse(uuid, text)            to authenticated;
grant execute on function api.resolve_comment(uuid)             to authenticated;
grant execute on function api.submit_chapter(uuid)              to authenticated;
grant execute on function api.review_chapter(uuid, text, text)  to authenticated;
grant execute on function api.complete_password_change()        to authenticated;
grant execute on function api.record_consent(text)              to authenticated;
