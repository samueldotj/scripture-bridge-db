-- Delta sync and project-wide search, plus the retention jobs they depend on.
--
-- Requirements: DB §10 (delta sync), §5.8 (search), §13.5 (scheduled jobs).
--
-- Both functions here are SECURITY INVOKER, unlike the write RPCs. They are
-- reads, so RLS can do the work: if the membership check below were wrong, the
-- policies would still filter the rows. The explicit check exists to return a
-- typed `forbidden` rather than a silent empty page — an offline client needs
-- to tell "no access" from "no changes".

-- ---------------------------------------------------------------------------
-- Job bookkeeping (R-OPS-7)
--
-- A pruning job that silently stops running presents months later as a table
-- that grew without bound, or a cursor that never expires. Outcomes are
-- recorded so an operator can see the last successful run.
--
-- Records SUCCESSES only: a job that raises rolls back its own job_run row
-- along with its work, since Postgres has no autonomous transactions. A failure
-- therefore shows up as a missing run, not a failed one — check for a stale
-- last-success timestamp, and the scheduler's own error log for the reason.
-- ---------------------------------------------------------------------------

create table app.job_run (
  id            uuid primary key default gen_random_uuid(),
  job_name      text not null,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  rows_affected bigint,
  ok            boolean,
  detail        text
);

create index job_run_name_started_idx on app.job_run (job_name, started_at desc);

alter table app.job_run enable row level security;
alter table app.job_run force row level security;
-- No policy: operator/console concern, read with the service key. Same
-- reasoning as app.audit_log.

-- ---------------------------------------------------------------------------
-- Cursor encoding (R-SYNC-4)
--
-- Opaque to the app, which treats it as a token (APP §13.4). Not signed: RLS
-- and the membership check re-verify project access on every call, so a forged
-- cursor can at worst cause a client to skip its own changes.
--
-- encode(..., 'base64') wraps at 76 characters; the payload is far shorter than
-- that, but the newlines are stripped anyway so a longer cursor can never
-- become an invalid header or query parameter.
-- ---------------------------------------------------------------------------

create or replace function app.encode_cursor(p_project_id uuid, p_seq bigint)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(
           encode(
             convert_to(
               jsonb_build_object('v', 1, 'p', p_project_id, 's', p_seq)::text,
               'UTF8'),
             'base64'),
           E'\n', '');
$$;

create or replace function app.decode_cursor(p_cursor text, p_project_id uuid)
returns bigint
language plpgsql
stable
set search_path = ''
as $$
declare
  v_json jsonb;
begin
  begin
    v_json := convert_from(decode(p_cursor, 'base64'), 'UTF8')::jsonb;
  exception when others then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'cursor', 'reason', 'malformed'));
  end;

  if (v_json ->> 'v') <> '1' then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'cursor', 'reason', 'unsupported_version'));
  end if;

  -- A cursor from another project is a client bug, not an expiry. Advancing on
  -- it would silently sync the wrong project's scope.
  if (v_json ->> 'p') <> p_project_id::text then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'cursor', 'reason', 'project_mismatch'));
  end if;

  return (v_json ->> 's')::bigint;
end;
$$;

-- ---------------------------------------------------------------------------
-- GET /projects/{id}/changes?since={cursor}   (APP §13.4, DB §10)
--
-- ===========================================================================
-- THE SNAPSHOT GUARD BELOW IS THE POINT OF THIS FUNCTION. DO NOT REMOVE IT.
--
--   and xact_id < pg_snapshot_xmin(pg_current_snapshot())
--
-- Identity values are assigned at INSERT time but become visible at COMMIT
-- time. A transaction can take seq = 100 and commit AFTER one that took
-- seq = 101. Without this filter, a reader that returns 101 and advances its
-- cursor there will NEVER see 100: the row is permanently skipped, the client's
-- copy of that verse is permanently stale, and nothing anywhere reports an
-- error.
--
-- The filter excludes entries that any in-flight transaction could still be
-- holding below. The cost is latency — a change becomes visible to sync once
-- the transactions that were open when it was written have finished — which is
-- sub-second normally and longer only if a long transaction is open. That is a
-- latency cost, not a correctness one, and it is the right trade.
--
-- R-TEST-4 constructs this failure deliberately, because ordinary use will not
-- find it.
-- ===========================================================================
-- ---------------------------------------------------------------------------

create or replace function api.changes_since(
  p_project_id uuid,
  p_cursor     text default null,
  p_limit      int  default 500)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_since     bigint := 0;
  v_watermark bigint := 0;
  v_limit     int    := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_rows      jsonb;
  v_count     int;
  v_next      bigint;
begin
  perform app.assert_can_act();

  if not app.is_member(p_project_id) then
    perform app.error('forbidden', 403,
      jsonb_build_object('project_id', p_project_id));
  end if;

  if p_cursor is not null then
    v_since := app.decode_cursor(p_cursor, p_project_id);

    select coalesce(w.pruned_through_seq, 0) into v_watermark
      from app.change_log_watermark w
     where w.project_id = p_project_id;

    -- R-SYNC-7: strictly below. The watermark is the highest seq pruned, so a
    -- cursor sitting exactly on it has missed nothing. An initial sync (no
    -- cursor) is never expired.
    if v_since < coalesce(v_watermark, 0) then
      perform app.error('cursor_expired', 410,
        jsonb_build_object('project_id', p_project_id));
    end if;
  end if;

  -- Fetch one row beyond the page. If it exists there is more to come; this
  -- avoids a count(*) over the log (R-SYNC-5) and, unlike comparing the page
  -- size to the limit, does not claim has_more on an exactly-full final page.
  with page as (
    select cl.seq, cl.entity_type, cl.entity_id, cl.op, cl.payload, cl.created_at
      from app.change_log cl
     where cl.project_id = p_project_id
       and cl.seq > v_since
       and cl.xact_id < pg_snapshot_xmin(pg_current_snapshot())
     order by cl.seq
     limit v_limit + 1
  ),
  trimmed as (
    select * from page order by seq limit v_limit
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'seq',         t.seq,
             'entity_type', t.entity_type,
             'entity_id',   t.entity_id,
             'op',          t.op,
             'payload',     t.payload,
             'created_at',  t.created_at)
           order by t.seq), '[]'::jsonb),
         max(t.seq),
         (select count(*) from page)
    into v_rows, v_next, v_count
    from trimmed t;

  return jsonb_build_object(
    'project_id',  p_project_id,
    'changes',     v_rows,
    -- Unchanged when the page is empty, so a client with nothing to do does not
    -- reset its position.
    'next_cursor', app.encode_cursor(p_project_id, coalesce(v_next, v_since)),
    'has_more',    v_count > v_limit
  );
end;
$$;

comment on function api.changes_since(uuid, text, int) is
  'Delta sync (APP R-OFF-7). has_more is approximate only in that a full final page reports true; the next call then returns an empty page.';

-- ---------------------------------------------------------------------------
-- GET /projects/{id}/search?q=   (APP §13.4, §11.5, DB §5.8)
--
-- Trigram matching over the folded column, not tsvector: Postgres text-search
-- configurations are per-language and do not exist for the target languages,
-- and `simple` would tokenise on whitespace, which is wrong for scripts that do
-- not delimit words that way (R-SEARCH-DB-1/2).
--
-- Results are ordered by canonical position, never by relevance score: a
-- translator searching for a term wants it in Bible order (R-SEARCH-DB-3).
-- ---------------------------------------------------------------------------

create or replace function api.search_verses(
  p_project_id uuid,
  p_query      text,
  p_limit      int default 50,
  p_offset     int default 0)
returns table (
  verse_id       uuid,
  chapter_id     uuid,
  book_id        uuid,
  book_code      text,
  book_name      text,
  chapter_number int,
  verse_number   int,
  verse_text     text,
  verse_status   text)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pattern text;
begin
  perform app.assert_can_act();

  if not app.is_member(p_project_id) then
    perform app.error('forbidden', 403,
      jsonb_build_object('project_id', p_project_id));
  end if;

  if p_query is null or length(btrim(p_query)) < 2 then
    perform app.error('invalid_argument', 400,
      jsonb_build_object('field', 'q', 'reason', 'min_length_2'));
  end if;

  -- Fold to match the generated column, then escape LIKE metacharacters so a
  -- query containing % or _ searches for those characters rather than acting
  -- as a wildcard.
  v_pattern := replace(replace(replace(
                 app.fold_text(btrim(p_query)),
                 '\', '\\'), '%', '\%'), '_', '\_');

  return query
    select v.id, v.chapter_id, b.id, b.code, b.name, c.number, v.number,
           v.text, v.status
      from app.verse v
      join app.chapter c on c.id = v.chapter_id
      join app.book b    on b.id = c.book_id
     where v.project_id = p_project_id
       and v.text_folded like '%' || v_pattern || '%'
     order by b.sort_order, c.number, v.number
     limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

comment on function api.search_verses(uuid, text, int, int) is
  'Online project-wide search. The app must present this as distinct from its offline local search (APP R-SEARCH-2) — the two will not agree in every edge case, and merging their results silently would be worse than saying which one ran.';

-- ---------------------------------------------------------------------------
-- Retention jobs (DB §9 R-IDEM-5, §10.3 R-SYNC-6, §13.5 R-OPS-6)
--
-- Plain functions, not scheduled here. See the scheduling note at the end of
-- this file: creating pg_cron in a migration risks `supabase db reset` failing
-- for environment reasons, and a reliable reset from zero is the M1 exit
-- criterion the app team is blocked on.
-- ---------------------------------------------------------------------------

create or replace function app.prune_change_log(p_retain_days int default 90)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_run  uuid;
  v_rows bigint := 0;
begin
  insert into app.job_run (job_name) values ('prune_change_log')
  returning id into v_run;

  -- The `marked` CTE is never referenced by the main query. Postgres executes
  -- data-modifying CTEs exactly once and to completion regardless, so the
  -- watermark upsert still happens; the main query reports rows deleted rather
  -- than projects touched.
  with deleted as (
    delete from app.change_log
     where created_at < now() - make_interval(days => p_retain_days)
    returning project_id, seq
  ),
  highest as (
    select project_id, max(seq) as seq, count(*) as n
      from deleted group by project_id
  ),
  marked as (
    insert into app.change_log_watermark (project_id, pruned_through_seq)
    select project_id, seq from highest
        on conflict (project_id) do update
       set pruned_through_seq = greatest(
             app.change_log_watermark.pruned_through_seq,
             excluded.pruned_through_seq),
           updated_at = now()
    returning 1
  )
  select coalesce(sum(highest.n), 0) into v_rows from highest;

  update app.job_run
     set finished_at = now(), ok = true, rows_affected = v_rows,
         detail = format('retained %s days', p_retain_days)
   where id = v_run;

  return v_rows;
end;
$$;

create or replace function app.prune_idempotency_keys(p_retain_days int default 7)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_run  uuid;
  v_rows bigint;
begin
  insert into app.job_run (job_name) values ('prune_idempotency_keys')
  returning id into v_run;

  with deleted as (
    delete from app.idempotency_key
     where created_at < now() - make_interval(days => p_retain_days)
    returning 1
  )
  select count(*) into v_rows from deleted;

  update app.job_run
     set finished_at = now(), ok = true, rows_affected = v_rows,
         detail = format('retained %s days', p_retain_days)
   where id = v_run;

  return v_rows;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- app.error and app.assert_can_act are granted because the two read functions
-- above are SECURITY INVOKER and call them as the calling user. Neither is
-- reachable over HTTP: `app` is not an exposed schema (R-SCHEMA-2).
--
-- The prune functions are NOT granted. They run as the service role.
-- ---------------------------------------------------------------------------

grant execute on function app.error(text, int, jsonb)            to authenticated;
grant execute on function app.assert_can_act()                   to authenticated;
grant execute on function app.encode_cursor(uuid, bigint)        to authenticated;
grant execute on function app.decode_cursor(text, uuid)          to authenticated;
grant execute on function app.fold_text(text)                    to authenticated;

grant execute on function api.changes_since(uuid, text, int)     to authenticated;
grant execute on function api.search_verses(uuid, text, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- Scheduling (run once per environment, not in a migration)
--
--   create extension if not exists pg_cron;
--
--   select cron.schedule('prune-change-log', '17 3 * * *',
--                        $job$ select app.prune_change_log(90) $job$);
--   select cron.schedule('prune-idempotency', '32 3 * * *',
--                        $job$ select app.prune_idempotency_keys(7) $job$);
--   select cron.schedule('reconcile-counters', '5 4 * * 0',
--                        $job$ select count(*) from app.reconcile_chapter_counters(false) $job$);
--
-- Retention windows are asserted from the connectivity profile in APP §2.3, not
-- measured. Revisit after the pilot with real device sync intervals (§17 #9).
-- ---------------------------------------------------------------------------
