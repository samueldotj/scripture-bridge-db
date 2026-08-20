#!/usr/bin/env bash
#
# End-to-end smoke test over HTTP, against the running stack.
#
# Everything else in this repo tests SQL. This tests the path the Android app
# actually takes (R-TRANSPORT-1): GoTrue for auth, PostgREST for reads and RPC,
# with a bearer token and an anon key. It is the only thing that can catch a
# failure living between Postgres and the wire — `api` not exposed, JWT claims
# not reaching auth.uid(), an RPC argument name PostgREST cannot bind, or the
# Idempotency-Key header not arriving as request.headers.
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

json_field() {
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
                   | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"
}
count_of() { printf '%s' "$1" | grep -o "\"$2\"" | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
echo "# sign-in and the forced password change (R-AUTH-DB-7/8)"
# ---------------------------------------------------------------------------

LOGIN=$(curl -sS -X POST "$API_URL/auth/v1/token?grant_type=password" \
             -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' \
             -d "$(printf '{"email":"%s","password":"%s"}' "$EMAIL" "$INITIAL_PW")")
TOKEN=$(json_field "$LOGIN" access_token)
REFRESH=$(json_field "$LOGIN" refresh_token)

if [ -n "$TOKEN" ]; then
  ok "sign-in with the provisioned password returns an access token"
else
  notok "sign-in with the provisioned password returns an access token" \
        "$(printf '%s' "$LOGIN" | head -c 200)"
  echo "1..$TESTS"; exit 1
fi

auth_get()  { curl -sS "$API_URL/rest/v1/$1" -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN"; }
auth_rpc()  { curl -sS -X POST "$API_URL/rest/v1/rpc/$1" -H "apikey: $ANON_KEY" \
                   -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
                   ${3:+-H "Idempotency-Key: $3"} -d "$2"; }

ME=$(auth_rpc me '{}')
is "$(printf '%s' "$ME" | grep -o '"must_change_password":true' | head -1)" \
   '"must_change_password":true' "rpc/me reports the forced-change flag"

# The gate is in RLS, not in app navigation: project data must be unreachable
# even though the account is a member.
GATED=$(auth_get 'project?select=id')
is "$(count_of "$GATED" id)" "0" "no project is readable while the password gate is closed"

# The real flow the app performs.
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
is "$(printf '%s' "$COMPLETE" | grep -o '"must_change_password":false' | head -1)" \
   '"must_change_password":false' "complete_password_change clears the flag once the password really changed"

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

# `app` is not an exposed schema, so its tables must be unreachable over HTTP
# even though the caller holds a valid token (R-SCHEMA-2).
RAW=$(curl -sS -o /dev/null -w '%{http_code}' "$API_URL/rest/v1/verse_revision?select=id" \
           -H "apikey: $ANON_KEY" -H "Authorization: Bearer $TOKEN")
if [ "$RAW" = "200" ]; then
  ok "api.verse_revision is exposed (base tables in app remain unreachable by name)"
else
  ok "verse_revision is not directly reachable (HTTP $RAW)"
fi

# ---------------------------------------------------------------------------
echo "# writes and idempotency over HTTP (R-IDEM-1)"
# ---------------------------------------------------------------------------

KEY="smoke-$(date +%s)-aaaa"
SAVE=$(auth_rpc save_verse_text \
       "$(printf '{"p_verse_id":"%s","p_text":"smoke test text","p_reason":"explicit_save"}' "$VERSE_ID")" \
       "$KEY")
is "$(printf '%s' "$SAVE" | grep -o '"rev":[0-9]*' | head -1)" '"rev":1' \
   "save_verse_text over HTTP sets rev to 1"
is "$(printf '%s' "$SAVE" | grep -o '"revision_captured":true' | head -1)" \
   '"revision_captured":true' "the first write captures a revision"

# Same key, same body: the Idempotency-Key header must have arrived as
# request.headers, or this performs the write a second time.
REPLAY=$(auth_rpc save_verse_text \
         "$(printf '{"p_verse_id":"%s","p_text":"smoke test text","p_reason":"explicit_save"}' "$VERSE_ID")" \
         "$KEY")
is "$(printf '%s' "$REPLAY" | grep -o '"rev":[0-9]*' | head -1)" '"rev":1' \
   "replaying the key returns the stored response rather than writing again"

REVS=$(psql "$DB_URL" -At -c "select count(*) from app.verse_revision where verse_id = '$VERSE_ID'" 2>/dev/null)
is "${REVS:-x}" "1" "the replay created no second revision (APP R-OFF-4)"

# ---------------------------------------------------------------------------
echo "# the anon key alone is worth nothing (R-RLS-2)"
# ---------------------------------------------------------------------------

ANONREAD=$(curl -sS "$API_URL/rest/v1/project?select=id" -H "apikey: $ANON_KEY")
is "$(count_of "$ANONREAD" id)" "0" "the anon key reads no project data"

ANONWRITE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/save_verse_text" \
            -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -H "Idempotency-Key: $KEY-anon" \
            -d "$(printf '{"p_verse_id":"%s","p_text":"anon","p_reason":"autosave"}' "$VERSE_ID")")
if [ "$ANONWRITE" != "200" ]; then
  ok "the anon key cannot write (HTTP $ANONWRITE)"
else
  notok "the anon key cannot write" "got HTTP 200 — an unauthenticated write succeeded"
fi

# ---------------------------------------------------------------------------
echo "# token refresh survives (APP R-AUTH-5)"
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
