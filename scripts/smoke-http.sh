#!/usr/bin/env bash
#
# End-to-end smoke test over HTTP, against the running stack.
#
# Everything else in this repo tests SQL. This tests the path the Android app
# actually takes (R-TRANSPORT-1): GoTrue for auth, PostgREST for reads and RPC,
# with a bearer token and an anon key. It is the only thing that can catch a
# failure living between Postgres and the wire - `api` not exposed, JWT claims
# not reaching auth.uid(), an RPC argument PostgREST cannot bind, the
# Idempotency-Key header not arriving as request.headers, or a typed error
# losing its HTTP status on the way out.
#
# Expects `scripts/provision.sh bootstrap` to have run first.
#
#   bash scripts/smoke-http.sh
#
# Emits TAP; exit code is the number of failures.

set -uo pipefail

TESTS=0
FAILURES=0
ok()    { TESTS=$((TESTS+1)); echo "ok $TESTS - $1"; }
notok() { TESTS=$((TESTS+1)); FAILURES=$((FAILURES+1)); echo "not ok $TESTS - $1"
          if [ -n "${2:-}" ]; then echo "#   $2"; fi; }
is()    { if [ "$1" = "$2" ]; then ok "$3"; else notok "$3" "got [$1] want [$2]"; fi; }

if [ -z "${API_URL:-}" ] || [ -z "${ANON_KEY:-}" ]; then
  status=$(supabase status -o env 2>/dev/null) || true
  [ -n "$status" ] && eval "$status" 2>/dev/null || true
fi
API_URL="${API_URL:-http://127.0.0.1:54321}"
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
[ -n "${ANON_KEY:-}" ] || { echo "Bail out! ANON_KEY unavailable"; exit 1; }

EMAIL="${1:-translator@local.test}"
INITIAL_PW="${2:-dev-initial-password}"
NEW_PW="changed-password-9f2a"

# ---------------------------------------------------------------------------
# JSON extraction
#
# Postgres renders jsonb as {"key": value} WITH a space after the colon. Every
# pattern here tolerates surrounding whitespace: matching '"key":value' finds
# nothing, yields an empty string, and then compares unequal to everything -
# a failure that reads like a broken API rather than a broken assertion.
# ---------------------------------------------------------------------------

json_field() {
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
                   | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"
}
json_bool() {
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(true|false)" \
                   | head -1 | grep -oE '(true|false)$'
}
json_int() {
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*-?[0-9]+" \
                   | head -1 | grep -oE -- '-?[0-9]+$'
}
count_of() { printf '%s' "$1" | grep -o "\"$2\"" | wc -l | tr -d ' '; }

# Generalised so the reviewer can be driven too, not only the translator.
sign_in_as() {
  curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
       -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
       -d "$(printf '{"email":"%s","password":"%s"}' "$1" "$2")"
}

sign_in() {
  curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
       -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
       -d "$(printf '{"email":"%s","password":"%s"}' "$EMAIL" "$1")"
}

# ---------------------------------------------------------------------------
echo "# sign-in and the forced password change (R-AUTH-DB-7/8)"
# ---------------------------------------------------------------------------

LOGIN=$(sign_in "$INITIAL_PW")
TOKEN=$(json_field "$LOGIN" access_token)
FRESH_ACCOUNT=1
if [ -z "$TOKEN" ]; then
  # Already run against this database, so the password is the changed one.
  # Keeps the test re-runnable locally, where the database is not reset first.
  LOGIN=$(sign_in "$NEW_PW")
  TOKEN=$(json_field "$LOGIN" access_token)
  FRESH_ACCOUNT=0
fi

if [ -n "$TOKEN" ]; then
  ok "sign-in with the provisioned password returns an access token"
else
  notok "sign-in with the provisioned password returns an access token" \
        "$(printf '%s' "$LOGIN" | head -c 200)"
  echo "1..$TESTS"; exit 1
fi

auth_get() { curl -sS "$API_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN"; }
auth_rpc() { curl -sS -X POST "$API_URL/rest/v1/rpc/$1" -H "apikey: $ANON_KEY" \
                  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
                  ${3:+-H "Idempotency-Key: $3"} -d "$2"; }

if [ "$FRESH_ACCOUNT" -eq 1 ]; then
  ME=$(auth_rpc me '{}')
  is "$(json_bool "$ME" must_change_password)" "true" "rpc/me reports the forced-change flag"

  # The gate lives in RLS, not in app navigation: project data must be
  # unreachable even though the account is a member.
  GATED=$(auth_get 'project?select=id')
  is "$(count_of "$GATED" id)" "0" "no project is readable while the password gate is closed"

  CHANGED=$(curl -sS -X PUT "$API_URL/auth/v1/user" \
                 -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
                 -H 'Content-Type: application/json' \
                 -d "$(printf '{"password":"%s"}' "$NEW_PW")")
  if [ -n "$(json_field "$CHANGED" id)" ]; then
    ok "the user can change their own password"
  else
    notok "the user can change their own password" "$(printf '%s' "$CHANGED" | head -c 200)"
  fi

  COMPLETE=$(auth_rpc complete_password_change '{}')
  is "$(json_bool "$COMPLETE" must_change_password)" "false" \
     "complete_password_change clears the flag once the password really changed"
else
  echo "# account already past the password gate; skipping the gate assertions"
fi

# Changing a password revokes existing refresh tokens, so the session from
# before it cannot be renewed. Re-authenticate and carry the new pair forward.
RELOGIN=$(sign_in "$NEW_PW")
TOKEN=$(json_field "$RELOGIN" access_token)
REFRESH=$(json_field "$RELOGIN" refresh_token)
if [ -n "$TOKEN" ]; then
  ok "signing in again with the changed password works"
else
  notok "signing in again with the changed password works" "$(printf '%s' "$RELOGIN" | head -c 200)"
  echo "1..$TESTS"; exit 1
fi

# ---------------------------------------------------------------------------
echo "# reads through PostgREST (R-TRANSPORT-1, R-SCHEMA-2)"
# ---------------------------------------------------------------------------

PROJECTS=$(auth_get 'project?select=id,name,my_role')
is "$(count_of "$PROJECTS" id)" "1" "the project is readable once the gate opens"
is "$(json_field "$PROJECTS" my_role)" "translator" "api.project reports the caller's role"

ASSIGN=$(auth_get 'assignment?select=chapter_id,book_code,chapter_number')
is "$(json_field "$ASSIGN" book_code)" "MAT" "the assignment view returns the assigned chapter"

CHAPTER_ID=$(json_field "$ASSIGN" chapter_id)
VERSES=$(auth_get "verse?select=id,number,rev,status&chapter_id=eq.$CHAPTER_ID&order=number&limit=1")
VERSE_ID=$(json_field "$VERSES" id)
if [ -n "$VERSE_ID" ]; then
  ok "verses of the assigned chapter are readable"
else
  notok "verses of the assigned chapter are readable" "$(printf '%s' "$VERSES" | head -c 200)"
  echo "1..$TESTS"; exit 1
fi

REVREAD=$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/rest/v1/verse_revision?select=id&limit=1" \
               -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN")
is "$REVREAD" "200" "the revision view is reachable through the api schema"

# ---------------------------------------------------------------------------
echo "# writes and idempotency over HTTP (R-IDEM-1)"
# ---------------------------------------------------------------------------

STARTING_REV=$(psql "$DB_URL" -At -c "select rev from app.verse where id = '$VERSE_ID'" 2>/dev/null)
KEY="smoke-key-$(date +%s%N)"
SAVE=$(auth_rpc save_verse_text \
       "$(printf '{"p_verse_id":"%s","p_text":"smoke test text","p_reason":"explicit_save"}' "$VERSE_ID")" \
       "$KEY")
is "$(json_int "$SAVE" rev)" "$((STARTING_REV + 1))" "save_verse_text over HTTP advances rev by one"
is "$(json_bool "$SAVE" revision_captured)" "true" "an explicit save captures a revision"

BEFORE_REPLAY=$(psql "$DB_URL" -At -c "select count(*) from app.verse_revision where verse_id = '$VERSE_ID'" 2>/dev/null)

# Same key, same body. The Idempotency-Key header must have arrived as
# request.headers, or this performs the write a second time.
REPLAY=$(auth_rpc save_verse_text \
         "$(printf '{"p_verse_id":"%s","p_text":"smoke test text","p_reason":"explicit_save"}' "$VERSE_ID")" \
         "$KEY")
is "$(json_int "$REPLAY" rev)" "$((STARTING_REV + 1))" \
   "replaying the key returns the stored response rather than writing again"

AFTER_REPLAY=$(psql "$DB_URL" -At -c "select count(*) from app.verse_revision where verse_id = '$VERSE_ID'" 2>/dev/null)
is "$AFTER_REPLAY" "$BEFORE_REPLAY" "the replay created no second revision (APP R-OFF-4)"

# ---------------------------------------------------------------------------
echo "# typed errors reach the wire with the right HTTP status (R-ERR-1)"
#
# DB 11.2 maps SQLSTATE PT<nnn> to HTTP <nnn>, and PostgREST performs that
# mapping. It cannot be verified in SQL: pgTAP sees the SQLSTATE, not the status
# the app branches on. If the mapping broke, every typed refusal would arrive as
# a 500 and the app would treat it as retryable-unknown, holding the write in
# its outbox forever (APP R-API-12).
# ---------------------------------------------------------------------------

ERRFILE=$(mktemp)

# status_and_code <expected-status> <expected-code> <rpc> <json-body> [key]
status_and_code() {
  local want_status="$1" want_code="$2" rpc="$3" body="$4" key="${5:-}"
  local status code
  status=$(curl -sS -o "$ERRFILE" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/$rpc" \
           -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN" \
           -H 'Content-Type: application/json' \
           ${key:+-H "Idempotency-Key: $key"} -d "$body")
  code=$(json_field "$(cat "$ERRFILE")" message)
  if [ "$status" = "$want_status" ] && [ "$code" = "$want_code" ]; then
    ok "$want_code arrives as HTTP $want_status"
  else
    notok "$want_code arrives as HTTP $want_status" \
          "got status=$status code=[$code] body=$(head -c 160 "$ERRFILE")"
  fi
}

VERSE_BODY=$(printf '{"p_verse_id":"%s","p_text":"error probe","p_reason":"explicit_save"}' "$VERSE_ID")

status_and_code 400 idempotency_key_required save_verse_text "$VERSE_BODY"

status_and_code 400 invalid_argument save_verse_text \
  "$(printf '{"p_verse_id":"%s","p_text":"x","p_reason":"nonsense"}' "$VERSE_ID")" \
  "errkey-a-$(date +%s%N)"

# The decomposed literal is produced by Postgres rather than by a shell escape:
# U&'\0065\0301clair' is 'e' + U+0301 COMBINING ACUTE, is pure ASCII in this
# file, and cannot be mangled by an editor the way \xCC\x81 was, twice.
NFD=$(psql "$DB_URL" -At -c "select U&'\0065\0301clair'" 2>/dev/null)
status_and_code 422 text_not_normalized save_verse_text \
  "$(printf '{"p_verse_id":"%s","p_text":"%s","p_reason":"explicit_save"}' "$VERSE_ID" "$NFD")" \
  "errkey-b-$(date +%s%N)"

status_and_code 422 comment_required flag_verse \
  "$(printf '{"p_verse_id":"%s","p_body":"  "}' "$VERSE_ID")" \
  "errkey-c-$(date +%s%N)"

# A chapter this user is not assigned. Chapter 2 was never assigned.
OTHER_VERSE=$(psql "$DB_URL" -At -c "select v.id from app.verse v
                join app.chapter c on c.id = v.chapter_id
               where c.project_id = (select project_id from app.chapter where id = '$CHAPTER_ID')
                 and c.number = 2 and v.number = 1" 2>/dev/null)
if [ -n "$OTHER_VERSE" ]; then
  status_and_code 403 not_assigned save_verse_text \
    "$(printf '{"p_verse_id":"%s","p_text":"x","p_reason":"explicit_save"}' "$OTHER_VERSE")" \
    "errkey-d-$(date +%s%N)"
else
  notok "not_assigned arrives as HTTP 403" "could not find an unassigned verse"
fi

# An approved chapter is the ONLY condition under which a text write is refused
# (R-API-11). Set directly, because reaching approval legitimately needs all 25
# verses filled and reviewed.
psql "$DB_URL" -q -c "update app.chapter set workflow_state='approved', approved_at=now(),
                        approved_by_id=coalesce(assigned_reviewer_id, assigned_translator_id)
                      where id='$CHAPTER_ID'" >/dev/null 2>&1
status_and_code 409 chapter_locked save_verse_text "$VERSE_BODY" "errkey-e-$(date +%s%N)"
psql "$DB_URL" -q -c "update app.chapter set workflow_state='in_progress', approved_at=null,
                        approved_by_id=null where id='$CHAPTER_ID'" >/dev/null 2>&1


# 404: a verse that does not exist.
status_and_code 404 not_found save_verse_text   '{"p_verse_id":"00000000-0000-0000-0000-000000000000","p_text":"x","p_reason":"explicit_save"}'   "errkey-f-$(date +%s%N)"

# 409: the same key carrying a different body (R-IDEM-3). Answering the second
# request with the first one's response would be worse than refusing it: the
# client would believe a write it never made had landed.
REUSE_KEY="errkey-g-$(date +%s%N)"
auth_rpc save_verse_text   "$(printf '{"p_verse_id":"%s","p_text":"first body","p_reason":"explicit_save"}' "$VERSE_ID")"   "$REUSE_KEY" >/dev/null
status_and_code 409 idempotency_key_reuse save_verse_text   "$(printf '{"p_verse_id":"%s","p_text":"second body","p_reason":"explicit_save"}' "$VERSE_ID")"   "$REUSE_KEY"

# 403: a project the caller is not a member of.
status_and_code 403 forbidden changes_since   '{"p_project_id":"00000000-0000-0000-0000-000000000000"}'

# 422: marking an empty verse done would let the chapter pass the "no empty
# verses" check on submit, because that check reads status rather than text.
EMPTY_VERSE=$(psql "$DB_URL" -At -c "select id from app.verse where chapter_id = '$CHAPTER_ID' and text = '' order by number limit 1" 2>/dev/null)
status_and_code 422 verse_empty set_verse_status   "$(printf '{"p_verse_id":"%s","p_status":"done"}' "$EMPTY_VERSE")"   "errkey-h-$(date +%s%N)"

# 422: submitting a chapter that still has empty verses (R-WF-1).
status_and_code 422 chapter_not_ready submit_chapter   "$(printf '{"p_chapter_id":"%s"}' "$CHAPTER_ID")"   "errkey-i-$(date +%s%N)"

# 410: a cursor stranded by pruning must expire, not return an empty page.
PROJECT_ID=$(psql "$DB_URL" -At -c "select project_id from app.chapter where id = '$CHAPTER_ID'" 2>/dev/null)
psql "$DB_URL" -q -c "insert into app.change_log_watermark (project_id, pruned_through_seq) values ('$PROJECT_ID', 500) on conflict (project_id) do update set pruned_through_seq = 500" >/dev/null 2>&1
STALE_CURSOR=$(psql "$DB_URL" -At -c "select app.encode_cursor('$PROJECT_ID', 499)" 2>/dev/null)
status_and_code 410 cursor_expired changes_since   "$(printf '{"p_project_id":"%s","p_cursor":"%s"}' "$PROJECT_ID" "$STALE_CURSOR")"
psql "$DB_URL" -q -c "delete from app.change_log_watermark where project_id = '$PROJECT_ID'" >/dev/null 2>&1

# The reviewer account is still behind the password gate, which bootstrap
# leaves in place - so it is the natural fixture for the two codes that only
# a gated account can produce.
REV_LOGIN=$(curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password"             -H "apikey: $ANON_KEY" -H 'Content-Type: application/json'             -d "$(printf '{"email":"reviewer@local.test","password":"%s"}' "$INITIAL_PW")")
REV_TOKEN=$(json_field "$REV_LOGIN" access_token)
if [ -n "$REV_TOKEN" ]; then
  SAVED_TOKEN="$TOKEN"
  TOKEN="$REV_TOKEN"
  status_and_code 403 must_change_password save_verse_text "$VERSE_BODY" "errkey-j-$(date +%s%N)"
  # Clearing the flag without actually changing the password must be refused,
  # or the forced change is advisory (R-AUTH-DB-7).
  status_and_code 422 password_unchanged complete_password_change '{}'
  TOKEN="$SAVED_TOKEN"
else
  notok "must_change_password arrives as HTTP 403" "could not sign in as the reviewer"
  notok "password_unchanged arrives as HTTP 422" "could not sign in as the reviewer"
fi

# ---------------------------------------------------------------------------
echo "# privileged operations are audited (R-AUDIT-1)"
#
# APP 14.2 lists a server-side audit trail as an assumption the app relies on
# and does not attempt to compensate for.
# ---------------------------------------------------------------------------

psql "$DB_URL" -q -c "update app.verse set text = 'filled for submission', status = 'draft' where chapter_id = '$CHAPTER_ID' and text = ''" >/dev/null 2>&1

SUBMIT=$(auth_rpc submit_chapter "$(printf '{"p_chapter_id":"%s"}' "$CHAPTER_ID")" "submit-key-$(date +%s%N)")
is "$(json_field "$SUBMIT" workflow_state)" "in_review" "a complete chapter submits over HTTP"

AUDITED=$(psql "$DB_URL" -At -c "select count(*) from app.audit_log where action = 'chapter.submit' and target_id = '$CHAPTER_ID'" 2>/dev/null)
is "${AUDITED:-0}" "1" "the submission is recorded in the audit log"

AUDIT_SHAPE=$(psql "$DB_URL" -At -c "select actor_profile_id is not null and before is not null and after is not null from app.audit_log where action = 'chapter.submit' and target_id = '$CHAPTER_ID' limit 1" 2>/dev/null)
is "${AUDIT_SHAPE:-f}" "t" "with an actor and before/after state"

AUDIT_TEXT=$(psql "$DB_URL" -At -c "select count(*) from app.audit_log where after::text like '%filled for submission%'" 2>/dev/null)
is "${AUDIT_TEXT:-1}" "0" "and no verse text, which is the revision table's job (R-AUDIT-3)"

# ---------------------------------------------------------------------------
echo "# the review loop and the remaining typed errors"
# ---------------------------------------------------------------------------

ERRFILE2=$(mktemp)

# The chapter is in_review after the submission above, so submitting again is a
# transition the state machine does not allow (R-FN-13). An offline client
# acting on stale state lands here, which is why it is typed rather than a
# silent no-op.
status_and_code 409 invalid_transition submit_chapter \
  "$(printf '{"p_chapter_id":"%s"}' "$CHAPTER_ID")" "errkey-k-$(date +%s%N)"

# Bring the reviewer past the password gate. Deliberately after the gate
# assertions earlier, which need it still closed.
REV_NEW_PW="reviewer-changed-7c3d"
REV_LOGIN=$(sign_in_as "reviewer@local.test" "$INITIAL_PW")
REV_TOKEN=$(json_field "$REV_LOGIN" access_token)
if [ -n "$REV_TOKEN" ]; then
  curl -sS -X PUT "$API_URL/auth/v1/user" -H "apikey: $ANON_KEY" \
       -H "Authorization: Bearer $REV_TOKEN" -H 'Content-Type: application/json' \
       -d "$(printf '{"password":"%s"}' "$REV_NEW_PW")" >/dev/null
  curl -sS -X POST "$API_URL/rest/v1/rpc/complete_password_change" \
       -H "apikey: $ANON_KEY" -H "Authorization: Bearer $REV_TOKEN" \
       -H 'Content-Type: application/json' -d '{}' >/dev/null
fi
REV_LOGIN=$(sign_in_as "reviewer@local.test" "$REV_NEW_PW")
REV_TOKEN=$(json_field "$REV_LOGIN" access_token)

if [ -n "$REV_TOKEN" ]; then
  SAVED_TOKEN="$TOKEN"
  TOKEN="$REV_TOKEN"

  FLAG=$(auth_rpc flag_verse \
         "$(printf '{"p_verse_id":"%s","p_body":"consider a clearer word"}' "$VERSE_ID")" \
         "errkey-l-$(date +%s%N)")
  is "$(json_field "$FLAG" status)" "flagged" "a reviewer can flag a verse with a comment"

  # R-WF-2: a chapter carrying flagged verses cannot be approved.
  status_and_code 422 chapter_has_flags review_chapter \
    "$(printf '{"p_chapter_id":"%s","p_decision":"approve"}' "$CHAPTER_ID")" \
    "errkey-m-$(date +%s%N)"

  TOKEN="$SAVED_TOKEN"

  # A flagged verse is cleared by resolving the comment, not by the translator
  # re-marking it done (R-REVIEW-3).
  status_and_code 422 verse_flagged set_verse_status \
    "$(printf '{"p_verse_id":"%s","p_status":"done"}' "$VERSE_ID")" \
    "errkey-n-$(date +%s%N)"
else
  notok "a reviewer can flag a verse with a comment" "could not sign the reviewer in"
  notok "chapter_has_flags arrives as HTTP 422"      "could not sign the reviewer in"
  notok "verse_flagged arrives as HTTP 422"          "could not sign the reviewer in"
fi

# 401 with no Authorization header. The code is asserted as well as the status,
# so a gateway-level rejection is not mistaken for the API's own refusal.
UNAUTH=$(curl -sS -o "$ERRFILE2" -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/save_verse_text" \
         -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
         -H "Idempotency-Key: unauth-$(date +%s%N)" \
         -d "$(printf '{"p_verse_id":"%s","p_text":"x","p_reason":"autosave"}' "$VERSE_ID")")
is "$UNAUTH" "401" "unauthenticated arrives as HTTP 401"
is "$(json_field "$(cat "$ERRFILE2")" message)" "unauthenticated" "carrying the API's own code"

# APP R-LEGAL-1: the app presents a consent notice at first sign-in and records
# the acknowledgement through the API.
CONSENT=$(auth_rpc record_consent '{"p_version":"2026-08-01"}' "consent-$(date +%s%N)")
is "$(json_bool "$CONSENT" accepted)" "true" "the consent acknowledgement is recorded"
CONSENT_ROW=$(psql "$DB_URL" -At -c "select count(*) from app.consent_record where version = '2026-08-01'" 2>/dev/null)
is "${CONSENT_ROW:-0}" "1" "and stored with its version, so a changed notice can be re-presented"

rm -f "$ERRFILE2"

rm -f "$ERRFILE"

# ---------------------------------------------------------------------------
echo "# the anon key alone is worth nothing (R-RLS-2)"
# ---------------------------------------------------------------------------

ANONREAD=$(curl -sS "$API_URL/rest/v1/project?select=id" -H "apikey: $ANON_KEY")
is "$(count_of "$ANONREAD" id)" "0" "the anon key reads no project data"

ANONWRITE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/save_verse_text" \
            -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
            -H "Idempotency-Key: anonkey-$(date +%s%N)" \
            -d "$(printf '{"p_verse_id":"%s","p_text":"anon","p_reason":"autosave"}' "$VERSE_ID")")
if [ "$ANONWRITE" != "200" ]; then
  ok "the anon key cannot write (HTTP $ANONWRITE)"
else
  notok "the anon key cannot write" "got HTTP 200 - an unauthenticated write succeeded"
fi

# ---------------------------------------------------------------------------
echo "# token refresh (APP R-AUTH-5)"
# ---------------------------------------------------------------------------

RENEW=$(curl -sS -X POST "$API_URL/auth/v1/token?grant_type=refresh_token" \
             -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
             -d "$(printf '{"refresh_token":"%s"}' "$REFRESH")")
if [ -n "$(json_field "$RENEW" access_token)" ]; then
  ok "the refresh token renews an access token"
else
  notok "the refresh token renews an access token" "$(printf '%s' "$RENEW" | head -c 200)"
fi

echo "1..$TESTS"
if [ "$TESTS" -eq 0 ]; then echo "Bail out! smoke test ran zero assertions"; exit 1; fi
if [ "$FAILURES" -eq 0 ]; then echo "# all $TESTS HTTP assertions passed"; else echo "# $FAILURES of $TESTS failed"; fi
exit "$FAILURES"
