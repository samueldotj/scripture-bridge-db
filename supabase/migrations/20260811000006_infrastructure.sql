-- Idempotency, change log, audit log, and consent records.
--
-- Requirements: DB §9 (idempotency), §10 (delta sync), §12.2 (audit),
-- §12.3 (personal data).

-- ---------------------------------------------------------------------------
-- Idempotency (DB §9)
--
-- Not optional: the deployment's defining network condition (APP §2.3) is the
-- dropped response. Every write function begins by inserting the key; a unique
-- violation means the request has been seen, and the stored response is
-- returned without performing the work twice.
-- ---------------------------------------------------------------------------

create table app.idempotency_key (
  profile_id   uuid not null references app.profile(id) on delete cascade,
  key          text not null check (length(key) between 8 and 255),
  operation    text not null,

  -- R-IDEM-3: if the key matches but the hash differs, the API raises
  -- idempotency_key_reuse. Silently returning the first response to a different
  -- request is worse than an error, because the client believes the second
  -- write landed.
  request_hash text not null,

  -- NULL while in flight. R-IDEM-4: a second caller blocks on the row lock and
  -- returns the first's response when it commits, rather than proceeding in
  -- parallel.
  response     jsonb,

  created_at   timestamptz not null default now(),
  primary key (profile_id, key)
);

-- R-IDEM-5: pruned after 7 days. The window must comfortably exceed the longest
-- realistic offline period for a queued write.
create index idempotency_key_created_idx on app.idempotency_key (created_at);

alter table app.idempotency_key enable row level security;
alter table app.idempotency_key force row level security;

-- ---------------------------------------------------------------------------
-- Change log (DB §10.1)
--
-- Written by the write functions in the same transaction as their mutation.
-- Nothing else writes to it: the write functions are the only mutation path
-- (R-RLS-5), so trigger-based capture would add a second mechanism with no
-- additional coverage.
-- ---------------------------------------------------------------------------

create table app.change_log (
  seq         bigint generated always as identity primary key,
  project_id  uuid not null references app.project(id) on delete restrict,
  entity_type text not null check (entity_type in
                ('verse', 'chapter', 'comment', 'assignment', 'project')),
  entity_id   uuid not null,
  op          text not null check (op in ('insert', 'update')),

  -- R-SYNC-2: the full new state, not a delta. Verse rows are small;
  -- reconstructing state from diffs on a client that may have missed windows
  -- is not.
  payload     jsonb not null,

  -- R-SYNC-3: THE CRITICAL COLUMN. Identity values are assigned at insert time
  -- but become visible at commit time, so a transaction can take seq = 100 and
  -- commit AFTER one that took seq = 101. A reader that advances its cursor to
  -- 101 would never see 100 — permanently skipped, no error anywhere, and the
  -- client's copy of that verse silently stale forever.
  --
  -- Readers must therefore filter on
  --     xact_id < pg_snapshot_xmin(pg_current_snapshot())
  -- which excludes entries any in-flight transaction could still be holding
  -- below. The cost is latency (changes surface once concurrent transactions
  -- finish), not correctness.
  xact_id     xid8 not null default pg_current_xact_id(),

  created_at  timestamptz not null default clock_timestamp()
);

create index change_log_project_seq_idx on app.change_log (project_id, seq);
create index change_log_xact_idx        on app.change_log (xact_id);

alter table app.change_log enable row level security;
alter table app.change_log force row level security;

-- UPDATE only, NOT delete. Unlike revisions and the audit log, change-log rows
-- are transient by design: they are pruned after 90 days (R-SYNC-6) and the
-- watermark records how far. Forbidding DELETE here would make retention
-- impossible, and an unbounded change log eventually means a cursor that never
-- expires and a table that never stops growing.
create trigger change_log_no_update
  before update on app.change_log
  for each row execute function app.forbid_mutation();

-- R-SYNC-6/7: a per-project watermark records the highest pruned seq. A cursor
-- at or below it returns cursor_expired (HTTP 410) so the app falls back to a
-- full fetch. Returning an empty page instead would look like "nothing changed"
-- and leave the device silently stale forever.
create table app.change_log_watermark (
  project_id        uuid primary key references app.project(id) on delete restrict,
  pruned_through_seq bigint not null default 0,
  updated_at        timestamptz not null default now()
);

alter table app.change_log_watermark enable row level security;
alter table app.change_log_watermark force row level security;

-- ---------------------------------------------------------------------------
-- Audit log (DB §12.2)
--
-- APP §14.2 lists a server-side audit trail of privileged operations as an
-- assumption the app relies on and does not attempt to compensate for.
-- ---------------------------------------------------------------------------

create table app.audit_log (
  id           uuid primary key default gen_random_uuid(),
  occurred_at  timestamptz not null default now(),
  actor_profile_id uuid references app.profile(id),
  actor_kind   text not null check (actor_kind in ('user', 'console', 'system')),
  action       text not null,
  target_type  text not null,
  target_id    uuid,

  -- R-AUDIT-3: no verse text here. Content history is the revision table's job;
  -- duplicating it would create a second, unmanaged copy of translation data
  -- with different retention.
  before       jsonb,
  after        jsonb,
  request_id   text
);

create index audit_log_occurred_idx on app.audit_log (occurred_at desc);
create index audit_log_target_idx   on app.audit_log (target_type, target_id);

alter table app.audit_log enable row level security;
alter table app.audit_log force row level security;

create trigger audit_log_append_only
  before update or delete on app.audit_log
  for each row execute function app.forbid_mutation();

-- ---------------------------------------------------------------------------
-- Consent (DB §12.3, APP R-LEGAL-1)
-- ---------------------------------------------------------------------------

create table app.consent_record (
  profile_id  uuid not null references app.profile(id) on delete cascade,
  version     text not null,
  accepted_at timestamptz not null default now(),
  primary key (profile_id, version)
);

comment on table app.consent_record is
  'The consent-text version is stored so a changed notice can be re-presented (R-COMPLY-1).';

alter table app.consent_record enable row level security;
alter table app.consent_record force row level security;
