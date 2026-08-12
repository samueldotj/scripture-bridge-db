-- Shared machinery for the write RPCs: typed errors, idempotency, change log,
-- audit, and state serialisation.
--
-- Requirements: DB §8 (write operations), §9 (idempotency), §10.1 (change log),
-- §11.2 (error model), §12.2 (audit).

-- ---------------------------------------------------------------------------
-- Typed errors (DB §11.2)
--
-- PostgREST maps SQLSTATE 'PT<nnn>' to HTTP status <nnn>, and surfaces the
-- exception message as the response `message` field. The application code goes
-- in the message and structured context in DETAIL as JSON; the app's
-- API-client module normalises this into APP §13.5's
-- { error: { code, message, details } } envelope.
--
-- R-ERR-4: no verse text, display name, or token may appear in a code, detail,
-- or hint. Error payloads reach logs and crash reports (APP R-SEC-6).
-- ---------------------------------------------------------------------------

create or replace function app.error(
  p_code text, p_http int, p_details jsonb default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using
    errcode = 'PT' || p_http::text,
    message = p_code,
    detail  = coalesce(p_details, '{}'::jsonb)::text;
end;
$$;

comment on function app.error(text, int, jsonb) is
  'Raises a typed error. Every code here must exist in DB §11.2 and in APP §13.5, or the app will treat it as retryable-unknown and hold the write in its outbox forever (APP R-API-12).';

-- ---------------------------------------------------------------------------
-- NFC guard
--
-- R-TEXT-DB-2: the API REJECTS non-NFC text rather than normalising it.
-- Normalising on write would mean a read returns text differing from what was
-- just sent, breaking the round-trip guarantee the app's dirty-state tracking
-- depends on (APP R-TEXT-1).
--
-- Returns boolean rather than a normalised value on purpose: a function that
-- returned NULL for bad input would be compared with `<>`, and `x <> NULL` is
-- NULL, not true — so the rejection would silently never fire.
-- ---------------------------------------------------------------------------

create or replace function app.is_nfc(t text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select t is nfc normalized;
$$;

-- ---------------------------------------------------------------------------
-- Idempotency (DB §9)
--
-- The key arrives in the Idempotency-Key header (R-IDEM-1). Under PostgREST it
-- is readable from request.headers; in psql and pgTAP there is no such setting,
-- so tests must supply one:
--
--   set local request.headers = '{"idempotency-key": "test-key-1"}';
--
-- R-IDEM-6: a write without a key is rejected. Making it optional guarantees
-- some code path omits it, and the resulting duplicate revisions are
-- indistinguishable from real edits.
-- ---------------------------------------------------------------------------

create or replace function app.request_idempotency_key()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_key text;
begin
  begin
    v_key := nullif(
      current_setting('request.headers', true)::json ->> 'idempotency-key', '');
  exception when others then
    v_key := null;   -- malformed header JSON is treated as absent
  end;

  if v_key is null then
    perform app.error('idempotency_key_required', 400);
  end if;
  return v_key;
end;
$$;

-- Returns the stored response when this request has already been performed,
-- or NULL when the caller should go ahead and do the work.
--
-- R-IDEM-4 (concurrent duplicate) is handled by Postgres itself: an INSERT
-- conflicting with an uncommitted duplicate BLOCKS on the unique index until
-- that transaction ends. If it committed we get unique_violation and return its
-- response; if it rolled back our insert simply succeeds. There is no window in
-- which two callers both perform the work.
--
-- A write that raises rolls back its idempotency row along with everything
-- else, so failures are deliberately not cached — retrying a rejected write
-- re-evaluates it against current state, which is what an offline client acting
-- on stale state needs.
create or replace function app.idempotency_begin(
  p_operation text, p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key     text := app.request_idempotency_key();
  v_profile uuid := app.current_profile_id();
  -- Not a security hash: an equality check on a client-supplied body, to catch
  -- a key reused for a different request (R-IDEM-3).
  v_hash    text := md5(p_request::text);
  v_row     app.idempotency_key;
begin
  if v_profile is null then
    perform app.error('unauthenticated', 401);
  end if;

  begin
    insert into app.idempotency_key (profile_id, key, operation, request_hash)
    values (v_profile, v_key, p_operation, v_hash);
    return null;
  exception when unique_violation then
    select * into v_row
      from app.idempotency_key
     where profile_id = v_profile and key = v_key
     for update;

    if v_row.request_hash is distinct from v_hash then
      perform app.error('idempotency_key_reuse', 409,
        jsonb_build_object('operation', v_row.operation));
    end if;

    -- Committed row with no response should not occur; treat as "do the work"
    -- rather than returning null to the client as if it were a result.
    return v_row.response;
  end;
end;
$$;

create or replace function app.idempotency_complete(p_response jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update app.idempotency_key
     set response = p_response
   where profile_id = app.current_profile_id()
     and key = app.request_idempotency_key();
  return p_response;
end;
$$;

-- ---------------------------------------------------------------------------
-- Change log (DB §10.1)
--
-- R-SYNC-1: appended in the same transaction as the mutation. Nothing but the
-- write functions calls this.
-- ---------------------------------------------------------------------------

create or replace function app.log_change(
  p_project_id  uuid,
  p_entity_type text,
  p_entity_id   uuid,
  p_payload     jsonb,
  p_op          text default 'update')
returns void
language sql
security definer
set search_path = ''
as $$
  insert into app.change_log (project_id, entity_type, entity_id, op, payload)
  values (p_project_id, p_entity_type, p_entity_id, p_op, p_payload);
$$;

-- ---------------------------------------------------------------------------
-- Audit (DB §12.2)
--
-- R-AUDIT-1: every privileged operation and every workflow transition.
-- R-AUDIT-3: never verse text — content history is the revision table's job.
-- ---------------------------------------------------------------------------

create or replace function app.audit(
  p_action      text,
  p_target_type text,
  p_target_id   uuid,
  p_before      jsonb default null,
  p_after       jsonb default null)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into app.audit_log
    (actor_profile_id, actor_kind, action, target_type, target_id, before, after)
  values
    (app.current_profile_id(), 'user', p_action, p_target_type, p_target_id,
     p_before, p_after);
$$;

-- ---------------------------------------------------------------------------
-- State serialisation
--
-- One definition of "the current state of a verse / chapter", used for both the
-- RPC return value (R-FN-2) and the change-log payload (R-SYNC-2), so the two
-- can never disagree about what the client is told.
-- ---------------------------------------------------------------------------

create or replace function app.verse_state(p_verse_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'verse_id',                 v.id,
           'chapter_id',               v.chapter_id,
           'project_id',               v.project_id,
           'number',                   v.number,
           'text',                     v.text,
           'rev',                      v.rev,
           'status',                   v.status,
           'last_modified_by_id',      v.last_modified_by_id,
           'last_modified_at',         v.last_modified_at,
           'unresolved_comment_count', v.unresolved_comment_count)
    from app.verse v
   where v.id = p_verse_id;
$$;

create or replace function app.chapter_state(p_chapter_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'chapter_id',             c.id,
           'book_id',                c.book_id,
           'project_id',             c.project_id,
           'number',                 c.number,
           'verse_count',            c.verse_count,
           'workflow_state',         c.workflow_state,
           'assigned_translator_id', c.assigned_translator_id,
           'assigned_reviewer_id',   c.assigned_reviewer_id,
           'submitted_at',           c.submitted_at,
           'approved_at',            c.approved_at,
           'approved_by_id',         c.approved_by_id,
           'verses_empty',           c.verses_empty,
           'verses_draft',           c.verses_draft,
           'verses_done',            c.verses_done,
           'flagged_verse_count',    c.verses_flagged)
    from app.chapter c
   where c.id = p_chapter_id;
$$;

create or replace function app.comment_state(p_comment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'comment_id',     k.id,
           'verse_id',       k.verse_id,
           'project_id',     k.project_id,
           'body',           k.body,
           'author_id',      k.author_id,
           'created_at',     k.created_at,
           'resolved_at',    k.resolved_at,
           'resolved_by_id', k.resolved_by_id)
    from app.comment k
   where k.id = p_comment_id;
$$;

-- ---------------------------------------------------------------------------
-- The core verse write (DB §8.1)
--
-- Internal, so that api.save_verse_text and api.restore_revision are the SAME
-- write path rather than two implementations that can drift (R-FN-10). The
-- caller has already authorised and taken the idempotency key.
--
-- The verse row is locked FOR UPDATE before rev is read (R-FN-5): last write
-- wins means the later arrival wins, not that two writes race to claim the same
-- counter value.
-- ---------------------------------------------------------------------------

create or replace function app.write_verse_text(
  p_verse_id      uuid,
  p_text          text,
  p_reason        text,
  p_restored_from uuid default null,
  p_note          text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verse            app.verse;
  v_profile          uuid := app.current_profile_id();
  v_workflow_changed boolean := false;
  v_capture          boolean;
  v_last_author      uuid;
  v_last_at          timestamptz;
  v_has_revision     boolean;
  v_revision_id      uuid;
  v_new_status       text;
begin
  select * into v_verse from app.verse where id = p_verse_id for update;

  if not found then
    perform app.error('not_found', 404);
  end if;

  if p_text is null or not app.is_nfc(p_text) then
    perform app.error('text_not_normalized', 422,
      jsonb_build_object('verse_id', p_verse_id));
  end if;

  -- R-FN-4: a byte-identical write is a no-op. Not merely an optimisation — the
  -- outbox re-sends collapsed writes (APP R-OFF-5) and autosave fires on
  -- unchanged text, and without this, history fills with identical entries and
  -- the 10-minute rule below trips on non-edits.
  if v_verse.text = p_text then
    return jsonb_build_object('revision_captured', false, 'revision_id', null)
           || app.verse_state(p_verse_id);
  end if;

  v_new_status := case
    when p_text = ''              then 'empty'
    when v_verse.status = 'flagged' then 'flagged'  -- editing does not clear a
                                                    -- flag; resolving the
                                                    -- comment does
    when v_verse.status = 'done'  then 'draft'      -- changed after being
                                                    -- marked done
    else 'draft'
  end;

  update app.verse
     set text                = p_text,
         rev                 = v_verse.rev + 1,
         status              = v_new_status,
         last_modified_by_id = v_profile,
         last_modified_at    = now()
   where id = p_verse_id;

  -- APP §8.1: the first verse edited moves the chapter off not_started. This is
  -- a workflow transition, so it is also a revision commit point (§8.2 rule 2).
  update app.chapter
     set workflow_state = 'in_progress'
   where id = v_verse.chapter_id
     and workflow_state = 'not_started';

  if found then
    v_workflow_changed := true;
  end if;

  -- ---- Revision capture (DB §8.2, APP R-REV-4) ----------------------------
  -- The decision is made HERE, server-side. The client reports what happened in
  -- its UI via p_reason; it does not decide policy (R-FN-6). An old or hostile
  -- client can at worst cause extra revisions, never inconsistent history.
  select r.author_id, r.created_at, true
    into v_last_author, v_last_at, v_has_revision
    from app.verse_revision r
   where r.verse_id = p_verse_id
   order by r.rev desc
   limit 1;

  v_capture :=
       p_reason in ('explicit_save', 'editor_closed', 'restore')  -- rule 1
    or v_workflow_changed                                         -- rule 2
    or coalesce(v_has_revision, false) = false                    -- first ever
    or v_last_author is distinct from v_profile                   -- rule 4
    or (now() - v_last_at) > interval '10 minutes';               -- rule 3

  if v_capture then
    insert into app.verse_revision
      (verse_id, project_id, rev, text, author_id, note, restored_from_revision_id)
    values
      (p_verse_id, v_verse.project_id, v_verse.rev + 1, p_text, v_profile,
       p_note, p_restored_from)
    returning id into v_revision_id;
  end if;

  perform app.log_change(v_verse.project_id, 'verse', p_verse_id,
                         app.verse_state(p_verse_id));

  if v_workflow_changed then
    perform app.log_change(v_verse.project_id, 'chapter', v_verse.chapter_id,
                           app.chapter_state(v_verse.chapter_id));
  end if;

  return jsonb_build_object(
           'revision_captured', v_capture,
           'revision_id',       v_revision_id)
         || app.verse_state(p_verse_id);
end;
$$;
