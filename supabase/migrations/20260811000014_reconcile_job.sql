-- Reconciliation as a schedulable job (R-PERF-4, R-OPS-7).
--
-- app.reconcile_chapter_counters() returns discrepancies to a caller who reads
-- them. A cron job has no reader, so scheduling it directly would run the check
-- weekly and discard the answer - the drift would be detected and then thrown
-- away, which is worse than not checking, because the schedule implies someone
-- is looking.
--
-- This wrapper records the outcome the way the pruning jobs do, so "is anything
-- drifting?" is a query against app.job_run rather than a thing nobody knows.

create or replace function app.run_counter_reconciliation()
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_run  uuid;
  v_rows bigint;
begin
  insert into app.job_run (job_name) values ('reconcile_chapter_counters')
  returning id into v_run;

  select count(*) into v_rows from app.reconcile_chapter_counters(false);

  update app.job_run
     set finished_at   = now(),
         -- ok = false when drift exists. The job succeeded; the DATA did not,
         -- and an operator scanning for the last non-ok run should see it.
         ok            = (v_rows = 0),
         rows_affected = v_rows,
         detail        = case when v_rows = 0
                              then 'no drift'
                              else v_rows || ' counter(s) disagree with their verse rows'
                         end
   where id = v_run;

  return v_rows;
end;
$$;

comment on function app.run_counter_reconciliation() is
  'Scheduled weekly (scripts/schedule-jobs.sql). Reports drift rather than repairing it: an automatic repair would hide a bug that is producing the drift.';
