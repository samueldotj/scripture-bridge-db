-- Identity: profiles, decoupled from auth.users.
--
-- Requirements: DB §5.2, R-DATA-4/5/6, R-AUTH-DB-6/7.

create table app.profile (
  id                   uuid primary key default gen_random_uuid(),

  -- R-DATA-4: ON DELETE SET NULL, never CASCADE. Erasing a user's personal data
  -- (APP R-LEGAL-2) deletes the auth.users row; the profile survives so every
  -- revision, comment, and approval keeps a stable author reference. A CASCADE
  -- here would destroy translation history on an erasure request — the exact
  -- outcome R-LEGAL-2 forbids — and RESTRICT would make erasure impossible.
  auth_user_id         uuid unique references auth.users(id) on delete set null,

  display_name         text,
  anonymised_at        timestamptz,

  -- R-DATA-6: this flag lives here, NOT in raw_user_meta_data, which is
  -- writable by the user themselves through the auth API — a flag stored there
  -- can be cleared by the account it constrains, defeating the forced password
  -- change entirely (APP R-AUTH-6).
  must_change_password boolean not null default true,

  -- R-AUTH-DB-7: a fingerprint of the password hash as provisioned, so that
  -- clearing must_change_password can VERIFY the password actually changed
  -- rather than trusting the client's assertion that it did.
  --
  -- This is a change-detection fingerprint over an already-hashed value, not a
  -- credential: it cannot be used to authenticate, and it is never returned by
  -- any view or RPC.
  initial_password_fingerprint text,

  created_by           uuid references app.profile(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  -- R-DATA-5: an anonymised profile carries no display name. The app renders
  -- "Former contributor"; views must never filter these rows out, because a
  -- missing author is worse than a tombstoned one.
  constraint profile_anonymised_has_no_name
    check (anonymised_at is null or display_name is null)
);

create index profile_auth_user_id_idx on app.profile (auth_user_id)
  where auth_user_id is not null;

create trigger profile_set_updated_at
  before update on app.profile
  for each row execute function app.set_updated_at();

alter table app.profile enable row level security;
alter table app.profile force row level security;

-- ---------------------------------------------------------------------------
-- Profile creation
--
-- R-AUTH-DB-6: self-healing and idempotent. The console creates the profile
-- alongside the auth user (R-AUTH-DB-5); this trigger covers the case where it
-- did not. An auth user without a profile is invisible to every query in this
-- schema and presents as a user who can sign in but has no data.
-- ---------------------------------------------------------------------------

create or replace function app.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into app.profile (auth_user_id, display_name, initial_password_fingerprint)
  values (new.id,
          nullif(new.raw_user_meta_data ->> 'display_name', ''),
          md5(coalesce(new.encrypted_password, '')))
  on conflict (auth_user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- Caller identity
--
-- R-RLS-10: policies must call this as `(select app.current_profile_id())` so
-- it is evaluated once per statement as an InitPlan rather than once per row.
-- On the verse table the difference is substantial and costs nothing.
-- ---------------------------------------------------------------------------

create or replace function app.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.id
    from app.profile p
   where p.auth_user_id = (select auth.uid());
$$;

comment on function app.current_profile_id() is
  'Maps the JWT subject to a profile id. SECURITY DEFINER so it is usable inside policies on tables the caller cannot read directly.';

grant execute on function app.current_profile_id() to authenticated;

-- ---------------------------------------------------------------------------
-- Password-change gate
--
-- R-AUTH-DB-8: until this flag is cleared, RLS denies the caller access to all
-- project content. The gate is in the database, not in the app's navigation —
-- APP R-AUTH-6 requires the user reach no project data first, and a navigation
-- guard is not a security control.
-- ---------------------------------------------------------------------------

create or replace function app.password_change_complete()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from app.profile p
     where p.auth_user_id = (select auth.uid())
       and p.must_change_password = false
  );
$$;

grant execute on function app.password_change_complete() to authenticated;
