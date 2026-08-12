-- Schemas, extensions, and shared conventions.
--
-- Requirements: DB §4 (schema organisation), R-SCHEMA-1..4, R-RLS-6/7.

-- ---------------------------------------------------------------------------
-- Schemas (R-SCHEMA-1)
-- ---------------------------------------------------------------------------

create schema if not exists app;
create schema if not exists api;
create schema if not exists ref;

comment on schema app is
  'Base tables and internal functions. Never exposed through PostgREST (R-SCHEMA-2).';
comment on schema api is
  'Views and RPC functions the app and console call. The only exposed schema.';
comment on schema ref is
  'Immutable reference data: canonical books and versification (R-DATA-1).';

-- R-SCHEMA-3: `public` is left empty. Anything landing there is a mistake, and
-- an empty schema makes that visible.
revoke create on schema public from public;

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------

create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;

-- ---------------------------------------------------------------------------
-- Grants
--
-- `authenticated` needs USAGE on `app` and SELECT on its tables because the
-- `api` views are security_invoker (R-RLS-13) — privileges on the underlying
-- tables are checked against the calling user, and RLS then filters the rows.
-- This is not a weakening: `app` is unreachable over HTTP (R-SCHEMA-2) and
-- every table has RLS enabled and forced.
--
-- R-RLS-5: no INSERT, UPDATE, or DELETE is granted to `authenticated` on any
-- table, anywhere. All writes go through SECURITY DEFINER RPCs (R-TRANSPORT-4).
-- R-RLS-2: `anon` receives nothing. Nothing in this system is public.
-- ---------------------------------------------------------------------------

grant usage on schema app to authenticated;
grant usage on schema api to authenticated;
grant usage on schema ref to authenticated;

alter default privileges in schema app  grant select on tables to authenticated;
alter default privileges in schema ref  grant select on tables to authenticated;
alter default privileges in schema api  grant select on tables to authenticated;

-- R-RLS-6: Postgres grants EXECUTE to PUBLIC by default, and the default is
-- wrong here. Each function must be granted explicitly to `authenticated`.
alter default privileges in schema app revoke execute on functions from public;
alter default privileges in schema api revoke execute on functions from public;
alter default privileges in schema ref revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- Shared trigger functions
--
-- Every SECURITY DEFINER function pins search_path and schema-qualifies every
-- identifier (R-RLS-7). An unpinned search_path on a definer function is a
-- well-known privilege-escalation path; CI enforces this (R-TEST-6).
-- ---------------------------------------------------------------------------

create or replace function app.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function app.set_updated_at() is
  'Maintains updated_at. Server time only — client clocks never determine ordering (R-API-3).';

-- Append-only guard. Used on verse_revision (R-FN-9) and audit_log (R-AUDIT-2).
-- Grants stop `authenticated`; this trigger stops a future migration, a console
-- feature, or a service_role script, which bypass grants but not triggers.
create or replace function app.forbid_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'append_only_table'
    using errcode = 'PT409',
          detail  = format('{"table": "%s.%s", "operation": "%s"}',
                           tg_table_schema, tg_table_name, tg_op);
end;
$$;

comment on function app.forbid_mutation() is
  'Raises unconditionally. Makes append-only a property of the table, not a convention.';

-- Immutable text folding for search (R-SEARCH-DB-2).
--
-- unaccent() is not marked IMMUTABLE because a dictionary can be redefined, so
-- it cannot be used directly in a generated column or index. The two-argument
-- form takes an explicit, schema-qualified dictionary, which makes this wrapper
-- safe to mark immutable in practice.
--
-- Consequence to accept: if the unaccent dictionary is ever changed, every
-- index and generated column built on this function must be rebuilt.
create or replace function app.fold_text(t text)
returns text
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select lower(extensions.unaccent('extensions.unaccent'::regdictionary, t));
$$;

comment on function app.fold_text(text) is
  'Case- and diacritic-folded form for trigram search (R-SEARCH-DB-2). Script-agnostic: no per-language text-search configuration is involved.';
