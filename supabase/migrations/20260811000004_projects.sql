-- Projects, membership, and fonts.
--
-- Requirements: DB §5.3, §5.6, R-DATA-7/8/9, R-DATA-13.
--
-- Enumerated values use text + CHECK rather than Postgres enum types. Adding a
-- value to an enum cannot be used in the same transaction that adds it, which
-- is awkward under linear migrations (R-MIG-2), and CHECK constraints keep the
-- additive-only release discipline of R-MIG-3 straightforward.

-- ---------------------------------------------------------------------------
-- Fonts (R-DATA-13, R-FONT-1/3)
-- ---------------------------------------------------------------------------

create table app.font (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  script_code     text not null,
  storage_path    text not null unique,
  file_size_bytes bigint not null check (file_size_bytes > 0),

  -- R-STORE-2: authoritative. The app verifies this after download and refuses
  -- a mismatch — a corrupt font on a Class D script renders the app unusable.
  sha256          text not null check (sha256 ~ '^[0-9a-f]{64}$'),

  -- R-STORE-3: a legal gate on which fonts may be uploaded at all.
  license         text not null,
  version         text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger font_set_updated_at
  before update on app.font
  for each row execute function app.set_updated_at();

alter table app.font enable row level security;
alter table app.font force row level security;

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

create table app.project (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null,
  language_name          text not null,

  -- BCP 47. Not validated beyond shape: many target languages have codes that
  -- stock validators reject, and rejecting a real language is worse than
  -- accepting a malformed tag (APP §2.1).
  language_code          text not null,
  script_code            text not null,

  -- APP R-RTL-1: drives editor layout. Required from v1 even before a Class C
  -- language is onboarded, because retrofitting RTL is expensive.
  text_direction         text not null default 'ltr'
                           check (text_direction in ('ltr', 'rtl')),

  -- R-DATA-8: immutable after creation (trigger below). Changing it would
  -- orphan or duplicate verse rows that already hold translated text.
  versification_scheme   text not null references ref.versification_scheme(code),

  -- APP R-FONT-2: per-project, because scripts differ substantially in the size
  -- needed for comfortable reading.
  font_id                uuid references app.font(id),
  font_size_sp           int not null default 18 check (font_size_sp between 8 and 72),
  line_height_multiplier numeric(3,2) not null default 1.40
                           check (line_height_multiplier between 1.0 and 3.0),

  -- R-DATA-9: projects are archived, never deleted, from the console.
  archived_at            timestamptz,

  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

create index project_archived_idx on app.project (archived_at) where archived_at is null;

create trigger project_set_updated_at
  before update on app.project
  for each row execute function app.set_updated_at();

alter table app.project enable row level security;
alter table app.project force row level security;

create or replace function app.forbid_versification_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.versification_scheme is distinct from old.versification_scheme then
    raise exception 'versification_immutable'
      using errcode = 'PT409',
            detail  = format('{"project_id": "%s"}', old.id);
  end if;
  return new;
end;
$$;

create trigger project_versification_immutable
  before update on app.project
  for each row execute function app.forbid_versification_change();

-- ---------------------------------------------------------------------------
-- Membership
--
-- R-DATA-7: role is a property of (user, project). There is no global role
-- column anywhere. A "platform administrator" is a console operator holding the
-- service key, not a row in this table.
-- ---------------------------------------------------------------------------

create table app.project_member (
  project_id uuid not null references app.project(id) on delete restrict,
  profile_id uuid not null references app.profile(id) on delete restrict,
  role       text not null check (role in ('admin', 'translator', 'reviewer')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (project_id, profile_id)
);

-- Read path for every policy in the system: "which projects is this caller in?"
create index project_member_profile_idx on app.project_member (profile_id);

create trigger project_member_set_updated_at
  before update on app.project_member
  for each row execute function app.set_updated_at();

alter table app.project_member enable row level security;
alter table app.project_member force row level security;

-- ---------------------------------------------------------------------------
-- Membership helpers
--
-- R-RLS-9: these are SECURITY DEFINER because a policy on project_member that
-- queries project_member recurses. That failure presents as an infinite
-- recursion error at query time, not at migration time.
--
-- R-RLS-8: policies call these rather than repeating join logic. The rules in
-- APP §4 and §8 must have exactly one implementation; a rule expressed in
-- fifteen policies is a rule with fifteen chances to be wrong.
-- ---------------------------------------------------------------------------

create or replace function app.role_in_project(p_project_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
    from app.project_member m
   where m.project_id = p_project_id
     and m.profile_id = (select app.current_profile_id());
$$;

create or replace function app.is_member(p_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- R-AUTH-DB-8: membership is not enough. A caller who has not completed the
  -- forced password change reaches no project data at all.
  select (select app.password_change_complete())
     and exists (
       select 1
         from app.project_member m
        where m.project_id = p_project_id
          and m.profile_id = (select app.current_profile_id())
     );
$$;

grant execute on function app.role_in_project(uuid) to authenticated;
grant execute on function app.is_member(uuid)        to authenticated;
