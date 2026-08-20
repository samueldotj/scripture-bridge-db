-- Operational hardening: statement timeout and font storage
-- (R-API-DB-5, R-STORE-1/2/3).

-- ---------------------------------------------------------------------------
-- Statement timeout (R-API-DB-5)
--
-- Project-wide search is the endpoint that will eventually meet a pathological
-- query, and this is a shared instance: one unbounded scan degrades the API for
-- every translator on it, not just the one who asked. The target for search is
-- under 500 ms (DB §15), so seconds of headroom is generous.
--
-- Applied to the roles PostgREST assumes rather than to the database, so
-- migrations, the console, and the pruning jobs are unaffected.
-- ---------------------------------------------------------------------------

-- The role that MATTERS here is `authenticator`, not `authenticated`.
--
-- PostgREST logs in as authenticator and then assumes authenticated with SET
-- ROLE. Postgres applies per-role settings at LOGIN and does not re-apply them
-- on assumption, so a timeout set only on `authenticated` is inert for every
-- API request - the catalogue reads as configured while the API stays
-- unbounded. Verified: 08_hardening.sql asserts the effective value and caught
-- exactly this.
--
-- The settings on authenticated and anon are kept for any client that connects
-- as those roles directly, but authenticator is what covers the API.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    execute 'alter role authenticator set statement_timeout = ''8s''';
  end if;
end;
$$;

alter role authenticated set statement_timeout = '8s';
alter role anon          set statement_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Font storage (R-STORE-1/2/3)
--
-- Fonts are bundled or downloaded, never assumed present on the device
-- (APP R-FONT-1): Class D script coverage is unreliable across Android versions
-- and OEM ROMs, so a project can be unusable without the font it names.
--
-- Wrapped in a guard because the `storage` schema is provided by the Supabase
-- stack, not by this repository. The pgTAP job starts Postgres alone, and an
-- unguarded reference here would fail that job for a reason unrelated to the
-- schema under test.
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage schema absent (database-only environment); skipping font bucket';
    return;
  end if;

  -- Private. Font licences permit redistribution through the app, not
  -- unauthenticated hosting (R-STORE-3), and the bucket is not a CDN.
  insert into storage.buckets (id, name, public)
  values ('fonts', 'fonts', false)
  on conflict (id) do nothing;

  -- Readable only by members of a project that actually references the font.
  -- Membership is evaluated through app.my_project_ids(), so the password gate
  -- (R-AUTH-DB-8) applies here too: a user who has not changed their password
  -- cannot pull project assets either.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'fonts_readable_by_project_members'
  ) then
    execute $p$
      create policy fonts_readable_by_project_members on storage.objects
        for select to authenticated
        using (
          bucket_id = 'fonts'
          and exists (
            select 1
              from app.font f
              join app.project p on p.font_id = f.id
             where f.storage_path = objects.name
               and p.id in (select app.my_project_ids())
          )
        )
    $p$;
  end if;

  -- No insert, update, or delete policy for `authenticated`, deliberately.
  -- Uploading a font is a console operation performed with the service key:
  -- the app verifies the sha256 it was given (R-STORE-2) and must never be
  -- able to replace the asset it is checking.
end;
$$;
