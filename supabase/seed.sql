-- Local development fixture. Runs on `supabase db reset`.
--
-- Creates one project with Matthew materialised — the MVP's one book end to end
-- (APP §18.1). Reference data itself is seeded by migration, not here
-- (R-MIG-4), because it is versioned with the schema.
--
-- ---------------------------------------------------------------------------
-- Users are deliberately NOT seeded here.
--
-- Inserting into auth.users directly couples this file to GoTrue's internal
-- schema, which moves between CLI versions and would leave `supabase db reset`
-- failing for reasons that have nothing to do with this project. Accounts are
-- created the way production creates them (R-AUTH-DB-5) — through the admin
-- API with the service key — which also means the local path exercises the real
-- provisioning path rather than a fixture-only shortcut.
--
-- With the stack running, create a dev translator:
--
--   curl -X POST 'http://127.0.0.1:54321/auth/v1/admin/users' \
--     -H "apikey: $SERVICE_ROLE_KEY" \
--     -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
--     -H 'Content-Type: application/json' \
--     -d '{"email":"translator@example.test","password":"dev-password",
--          "email_confirm":true,"user_metadata":{"display_name":"Dev Translator"}}'
--
-- The trigger in migration 20260811000003 creates the matching profile. Then
-- add membership and assignment with the psql snippet at the end of this file.
-- A console script replaces all of this at M1 (see docs/roadmap.md §8).
-- ---------------------------------------------------------------------------

do $$
declare
  v_project_id uuid;
  v_book_id    uuid;
begin
  insert into app.project (
    name, language_name, language_code, script_code,
    text_direction, versification_scheme, font_size_sp
  )
  values (
    'Dev Project', 'Example Language', 'xx', 'Latn',
    'ltr', 'eng', 18
  )
  returning id into v_project_id;

  v_book_id := app.materialise_book(v_project_id, 'MAT');

  raise notice 'Seeded project % with book % (Matthew, 28 chapters, 1071 verses)',
    v_project_id, v_book_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- After creating a dev user with the curl above, wire them up:
--
--   insert into app.project_member (project_id, profile_id, role)
--   select p.id, pr.id, 'translator'
--     from app.project p, app.profile pr
--    where p.name = 'Dev Project'
--      and pr.display_name = 'Dev Translator';
--
--   -- Clear the forced password change so the RLS gate (R-AUTH-DB-8) opens.
--   update app.profile set must_change_password = false
--    where display_name = 'Dev Translator';
--
--   -- Assign Matthew 1.
--   update app.chapter c set assigned_translator_id = pr.id
--     from app.book b, app.profile pr
--    where c.book_id = b.id and b.code = 'MAT' and c.number = 1
--      and pr.display_name = 'Dev Translator';
-- ---------------------------------------------------------------------------
