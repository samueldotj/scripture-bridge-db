-- Shared test setup. Included by each file in tests/database with:
--
--   \ir ../helpers.sql
--
-- Everything here is created INSIDE the test transaction and disappears on
-- rollback, so no test scaffolding ships to production. pgTAP itself is created
-- the same way.
--
-- If your pg_prove invocation does not honour \ir, inline this file instead —
-- it is deliberately small enough to paste.

create extension if not exists pgtap;

create schema tests;

-- Tests read fixture objects after switching to `authenticated`, so the schema
-- must be reachable from that role. Individual objects still need their own
-- grants; this only opens the door.
grant usage on schema tests to authenticated;

-- Fixture ids, so tests can refer to actors by name after switching roles.
create table tests.ids (name text primary key, id uuid not null);

-- ---------------------------------------------------------------------------
-- Impersonation
--
-- NOTE: authentication CANNOT be wrapped in a helper function. Postgres undoes
-- any SET performed inside a function when that function exits, so `SET LOCAL
-- ROLE` in a helper would silently have no effect and every RLS test would run
-- as the owner — passing while asserting nothing. Tests must therefore switch
-- roles with top-level statements:
--
--   select set_config('request.jwt.claims', tests.jwt('alice'), true);
--   set local role authenticated;
--   ... assertions ...
--   reset role;
--
-- set_config(..., true) called as a top-level query is not undone the same way,
-- so only the role switch needs to be a bare statement.
-- ---------------------------------------------------------------------------

create function tests.jwt(p_name text)
returns text
language sql
as $$
  select json_build_object(
           'sub',  (select id::text from tests.ids where name = p_name),
           'role', 'authenticated')::text;
$$;

-- ---------------------------------------------------------------------------
-- Fixture builders
--
-- Inserts into auth.users directly, which couples these tests to GoTrue's
-- internal schema. That is acceptable in tests and NOT acceptable in seed.sql
-- (see the note there): a test that breaks on a CLI upgrade is a signal, a
-- broken `db reset` is a blocked app team.
-- ---------------------------------------------------------------------------

create function tests.create_user(p_name text, p_password text default 'initial-pw')
returns uuid
language plpgsql
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data)
  values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
    p_name || '@example.test', 'hashed:' || p_password,
    now(), now(), now(),
    '{"provider":"email"}'::jsonb,
    json_build_object('display_name', p_name)::jsonb);

  insert into tests.ids (name, id) values (p_name, v_id);
  return v_id;
end;
$$;

-- The profile is created by the trigger on auth.users. Most tests want a user
-- past the forced password change (R-AUTH-DB-8), or my_project_ids() returns
-- empty and every content assertion trivially passes for the wrong reason.
create function tests.clear_password_gate(p_name text)
returns void
language sql
as $$
  update app.profile
     set must_change_password = false
   where auth_user_id = (select id from tests.ids where name = p_name);
$$;

create function tests.profile_id(p_name text)
returns uuid
language sql
as $$
  select p.id from app.profile p
   where p.auth_user_id = (select id from tests.ids where name = p_name);
$$;

create function tests.new_project(p_name text, p_book text default 'MAT')
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  insert into app.project (name, language_name, language_code, script_code,
                           text_direction, versification_scheme)
  values (p_name, 'Test Language', 'xx', 'Latn', 'ltr', 'eng')
  returning id into v_id;

  perform app.materialise_book(v_id, p_book);
  insert into tests.ids (name, id) values ('project:' || p_name, v_id);
  return v_id;
end;
$$;

create function tests.add_member(p_project uuid, p_user text, p_role text)
returns void
language sql
as $$
  insert into app.project_member (project_id, profile_id, role)
  values (p_project, tests.profile_id(p_user), p_role);
$$;

-- Convenience: the nth verse of chapter n of the project's only book.
create function tests.verse_of(p_project uuid, p_chapter int, p_verse int)
returns uuid
language sql
as $$
  select v.id
    from app.verse v
    join app.chapter c on c.id = v.chapter_id
   where v.project_id = p_project and c.number = p_chapter and v.number = p_verse;
$$;

create function tests.chapter_of(p_project uuid, p_chapter int)
returns uuid
language sql
as $$
  select c.id from app.chapter c
    join app.book b on b.id = c.book_id
   where b.project_id = p_project and c.number = p_chapter;
$$;

-- Writes require an Idempotency-Key header (R-IDEM-6). Like the role switch
-- above, tests set it with a top-level statement rather than through a helper,
-- because GUC changes made inside a function can be unwound at function exit:
--
--   select set_config('request.headers', '{"idempotency-key": "k1"}', true);
--
-- Each distinct write in a test needs a distinct key, or the second call
-- returns the first's stored response instead of doing anything.
