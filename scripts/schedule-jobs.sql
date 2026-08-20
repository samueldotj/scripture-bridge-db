-- Scheduled maintenance. Run ONCE per environment, after migrations.
--
--   psql "$DB_URL" -f scripts/schedule-jobs.sql
--
-- Or against a linked Supabase project:
--
--   supabase db execute --file scripts/schedule-jobs.sql
--
-- ===========================================================================
-- Why this is not a migration
--
-- Creating pg_cron inside one would make `supabase db reset` fail wherever the
-- extension is unavailable - which includes the database-only CI job - and a
-- reliable reset from zero is what CI and every developer depend on (R-MIG-5).
-- Scheduling is also an environment concern rather than a schema concern: the
-- same schema runs locally, in CI, in staging, and in production, but only the
-- last two should be pruning anything.
--
-- Safe to re-run. cron.schedule upserts by job name, so applying this twice
-- updates the existing jobs rather than duplicating them.
-- ===========================================================================

\set ON_ERROR_STOP on

create extension if not exists pg_cron;

do $$
begin
  if to_regclass('cron.job') is null then
    raise exception
      'pg_cron is not available in this database. Enable the extension for the project first; without it nothing prunes, the change log grows without bound, and cursor_expired can never fire (R-SYNC-6/7).';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Schedules are in UTC. The deployment region is India (ap-south-1, Mumbai),
-- so each time below is annotated with its IST equivalent (UTC+5:30).
--
-- An earlier version ran these at 03:17 UTC, which is 08:47 IST - the start of
-- the working day for the people using the system. They now run in the small
-- hours local time. The jobs are cheap, so this is about habit rather than
-- load: a maintenance window chosen in UTC drifts into the working day of
-- whoever is actually affected, and the next job added here may not be cheap.
-- ---------------------------------------------------------------------------

-- R-SYNC-6: 90 days. Also maintains the watermark, which is what lets
-- changes_since tell "nothing changed" from "you missed data and must
-- refetch". Pruning and cursor_expired are one mechanism, not two.
select cron.schedule(
  'scripture-prune-change-log',
  '47 20 * * *',   -- 02:17 IST
  $job$ select app.prune_change_log(90) $job$
);

-- R-IDEM-5: 7 days. The window must comfortably exceed the longest realistic
-- offline period for a queued write (APP §2.3 describes multi-hour outages;
-- a week covers a field trip).
select cron.schedule(
  'scripture-prune-idempotency-keys',
  '2 21 * * *',    -- 02:32 IST
  $job$ select app.prune_idempotency_keys(7) $job$
);

-- R-PERF-4: weekly. Reports drift, deliberately without repairing it - an
-- automatic repair would paper over whatever is producing the drift.
select cron.schedule(
  'scripture-reconcile-counters',
  '35 21 * * 6',   -- Sunday 03:05 IST (Saturday in UTC)
  $job$ select app.run_counter_reconciliation() $job$
);

-- ---------------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------------

select jobname, schedule, active, command
  from cron.job
 where jobname like 'scripture-%'
 order by jobname;

\echo ''
\echo 'Scheduled. Check outcomes with:'
\echo '  select job_name, started_at, finished_at, ok, rows_affected, detail'
\echo '    from app.job_run order by started_at desc limit 20;'
\echo ''
\echo 'A job that stops running leaves a stale last-success timestamp rather'
\echo 'than an error: failures roll back their own job_run row, because Postgres'
\echo 'has no autonomous transactions. Watch for absence, not for failure rows.'
\echo ''
\echo 'To remove:  select cron.unschedule(''scripture-prune-change-log'');'
