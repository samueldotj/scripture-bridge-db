-- Personal-data erasure (DB §12.3, R-COMPLY-2, APP R-LEGAL-2).
--
-- The hard requirement is that erasing a person does NOT erase their work:
-- "Erasure of a user's personal data must not destroy translation history"
-- (APP R-LEGAL-2). Every revision, comment, and approval must survive with a
-- stable author reference, rendered by the app as "Former contributor".
--
-- The schema was built for this: content tables reference app.profile, never
-- auth.users, and profile.auth_user_id is ON DELETE SET NULL (R-DATA-4). A
-- direct foreign key to auth.users with ON DELETE CASCADE would destroy history
-- on an erasure request, and ON DELETE RESTRICT would make erasure impossible.
-- This migration is where that design is finally exercised.

create or replace function api.anonymise_profile(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile app.profile;
  v_auth    uuid;
begin
  select * into v_profile from app.profile where id = p_profile_id;

  if not found then
    perform app.error('not_found', 404,
      jsonb_build_object('profile_id', p_profile_id));
  end if;

  -- Idempotent: erasure is irreversible, and a retried request must not look
  -- like a failure to the operator performing it.
  if v_profile.anonymised_at is not null then
    return jsonb_build_object(
      'profile_id',    v_profile.id,
      'anonymised_at', v_profile.anonymised_at,
      'already',       true);
  end if;

  v_auth := v_profile.auth_user_id;

  -- Order matters. The profile is tombstoned FIRST, so that if the auth
  -- deletion fails the account is already unusable rather than left readable
  -- with a live login.
  update app.profile
     set display_name                 = null,
         anonymised_at                = now(),
         must_change_password         = false,
         initial_password_fingerprint = null
   where id = p_profile_id;

  -- Deleting the auth user removes the sign-in identity, the sessions, and the
  -- refresh tokens. app.profile.auth_user_id is SET NULL by the foreign key;
  -- nothing in app or ref cascades from here (asserted in 07_erasure.sql).
  if v_auth is not null then
    delete from auth.users where id = v_auth;
  end if;

  -- R-AUDIT-3: no verse text, and no display name either - recording the name
  -- being erased in an append-only table would defeat the erasure.
  insert into app.audit_log
    (actor_kind, action, target_type, target_id, after)
  values
    ('console', 'profile.anonymise', 'profile', p_profile_id,
     jsonb_build_object('had_auth_user', v_auth is not null));

  return jsonb_build_object(
    'profile_id',    p_profile_id,
    'anonymised_at', now(),
    'already',       false);
end;
$$;

comment on function api.anonymise_profile(uuid) is
  'Irreversible. Tombstones the profile and deletes the sign-in identity, leaving every revision, comment, and approval intact (APP R-LEGAL-2). Console operation, service key only.';

-- NOT granted to `authenticated`. This is a console operation performed with
-- the service key (R-COMPLY-2); a project admin must not be able to erase a
-- colleague through the app's own API surface.
revoke execute on function api.anonymise_profile(uuid) from public;
grant execute on function api.anonymise_profile(uuid) to service_role;
