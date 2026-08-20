#!/usr/bin/env bash
#
# Console stand-in: create users, projects, memberships, and assignments.
#
# The Android app deliberately has no administrative UI (APP §18.2), so without
# something like this nobody can create an account, a project, or an assignment
# — and none of the app is reachable. This covers M1 through M4; the web console
# replaces it before the pilot (docs/roadmap.md §8).
#
# Users are created through the GoTrue ADMIN API rather than by writing to
# auth.users, because that is how production does it (R-AUTH-DB-5) and because
# direct writes couple to GoTrue's internal schema. Everything else is SQL:
# project setup, membership, and assignment are console-only operations with no
# API surface by design (DB §13.6).
#
# Usage:
#   scripts/provision.sh bootstrap [email] [password]
#   scripts/provision.sh create-user <display-name> <email> <password>
#   scripts/provision.sh create-project <name> <language> <script> [book...]
#   scripts/provision.sh add-member <project> <email> <admin|translator|reviewer>
#   scripts/provision.sh assign <project> <book> <chapter> <translator-email> [reviewer-email]
#   scripts/provision.sh reset-password <email> <new-password>
#   scripts/provision.sh list
#
# Configuration comes from the environment, falling back to `supabase status`:
#   API_URL, SERVICE_ROLE_KEY, ANON_KEY, DB_URL

set -uo pipefail

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
#
# The service key is read but NEVER echoed. It bypasses RLS entirely, so its
# exposure is a full compromise of every project's data (R-RLS-3) — which is
# also why this script exists on an operator's machine and not in the app.
# ---------------------------------------------------------------------------

load_config() {
  if [ -z "${API_URL:-}" ] || [ -z "${SERVICE_ROLE_KEY:-}" ] || [ -z "${DB_URL:-}" ]; then
    local status
    status=$(supabase status -o env 2>/dev/null) || true
    if [ -n "$status" ]; then
      eval "$status" 2>/dev/null || true
    fi
  fi

  API_URL="${API_URL:-http://127.0.0.1:54321}"
  DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
  ANON_KEY="${ANON_KEY:-}"
  SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:-}"

  [ -n "$SERVICE_ROLE_KEY" ] || die "SERVICE_ROLE_KEY not set and 'supabase status' gave none. Is the stack running?"
}

# Recorded against every console action (R-AUTH-DB-12). Without it the audit
# trail says "a console did this" and not which coordinator.
OPERATOR="${OPERATOR:-${USER:-unknown}}@provision.sh"

psql_q() { psql "$DB_URL" -v ON_ERROR_STOP=1 -q -At -c "$1"; }

# Escape a value for embedding in a single-quoted SQL literal.
sql_lit() { printf "%s" "$1" | sed "s/'/''/g"; }

json_field() {  # json_field <json> <key>   (flat string fields only)
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
                   | head -1 | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/"
}

audit() {  # audit <action> <target_type> <target_id> [detail-json]
  # R-AUTH-DB-12: every service-key operation is auditable. actor_kind is
  # 'console' with a null profile, because the operator is not a project member.
  psql_q "insert into app.audit_log (actor_kind, action, target_type, target_id, after)
          values ('console', '$(sql_lit "$1")', '$(sql_lit "$2")',
                  nullif('$(sql_lit "$3")','')::uuid, '$(sql_lit "${4:-{\}}")'::jsonb)" >/dev/null
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_create_user() {
  local name="$1" email="$2" password="$3"

  # email_confirm: true because identifiers may be synthetic addresses on a
  # project-controlled domain (R-AUTH-2) — no confirmation mail can be
  # delivered, and none is ever sent to a translator (R-AUTH-DB-3).
  local body
  body=$(printf '{"email":"%s","password":"%s","email_confirm":true,"user_metadata":{"display_name":"%s"}}' \
                "$email" "$password" "$name")

  local resp
  resp=$(curl -sS -X POST "$API_URL/auth/v1/admin/users" \
              -H "apikey: $SERVICE_ROLE_KEY" \
              -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
              -H 'Content-Type: application/json' \
              -d "$body")

  local uid
  uid=$(json_field "$resp" id)
  if [ -z "$uid" ]; then
    # Most likely already provisioned. Adopt the existing account instead of
    # failing, so bootstrap can be re-run against a partly-populated database.
    uid=$(psql_q "select id from auth.users where email = '$(sql_lit "$email")'")
    [ -n "$uid" ] || die "user creation failed: $(printf '%s' "$resp" | head -c 300)"
    echo "  user $email already exists; reusing" >&2
  fi

  # The profile arrives via the trigger on auth.users (R-AUTH-DB-6).
  # must_change_password stays TRUE: the out-of-band password is known to at
  # least two people (APP R-AUTH-6), and the app must force a change before any
  # project data is reachable.
  local pid
  pid=$(psql_q "select id from app.profile where auth_user_id = '$(sql_lit "$uid")'")
  [ -n "$pid" ] || die "auth user $uid created but no profile row appeared — is the trigger installed?"

  audit 'profile.create' 'profile' "$pid" "{\"email\":\"$(sql_lit "$email")\"}"
  echo "$pid"
}

cmd_create_project() {
  local name="$1" language="$2" script="$3"; shift 3
  local books=("$@")
  [ ${#books[@]} -gt 0 ] || books=("MAT")

  # Reuse a project of the same name rather than creating a second one.
  local pid existing
  existing=$(psql_q "select count(*) from app.project where name = '$(sql_lit "$name")'")
  if [ "${existing:-0}" -gt 1 ]; then
    die "several projects are named '$name'; this script needs the name to identify one"
  elif [ "${existing:-0}" -eq 1 ]; then
    pid=$(psql_q "select id from app.project where name = '$(sql_lit "$name")' limit 1")
    echo "  project '$name' already exists; reusing" >&2
    local b has
    for b in "${books[@]}"; do
      has=$(psql_q "select count(*) from app.book where project_id = '$pid' and code = '$(sql_lit "$b")'")
      if [ "${has:-0}" -eq 0 ]; then
        psql_q "select app.materialise_book('$pid', '$(sql_lit "$b")')" >/dev/null ||
          die "could not materialise $b - is its versification seeded?"
        echo "  materialised $b" >&2
      else
        echo "  $b already present" >&2
      fi
    done
    echo "$pid"
    return
  fi

  # api.create_project validates the scheme, materialises the books, and writes
  # the audit entry. Calling it rather than repeating that SQL here is the whole
  # point: the console runs the same function, so there is one implementation of
  # the rules and one place the audit trail is written.
  local books_sql
  books_sql=$(printf "'%s'," "${books[@]}")
  books_sql="array[${books_sql%,}]"

  pid=$(psql_q "select (api.create_project(
                          '$(sql_lit "$name")', '$(sql_lit "$language")', 'xx',
                          '$(sql_lit "$script")', 'eng', 'ltr',
                          $books_sql, '$(sql_lit "$OPERATOR")') ->> 'project_id')")
  [ -n "$pid" ] || die "project creation failed"
  echo "  materialised ${books[*]}" >&2
  echo "$pid"
}

# psql -At prints one line per row, so an ambiguous lookup silently produced two
# UUIDs joined by a newline and the failure surfaced far from its cause. These
# refuse anything but exactly one match.
project_id_by_name() {
  local n
  n=$(psql_q "select count(*) from app.project where name = '$(sql_lit "$1")'")
  [ "${n:-0}" -eq 1 ] || die "expected exactly one project named '$1', found ${n:-0}"
  psql_q "select id from app.project where name = '$(sql_lit "$1")' limit 1"
}

profile_id_by_email() {
  local n
  n=$(psql_q "select count(*) from app.profile p join auth.users u on u.id = p.auth_user_id
               where u.email = '$(sql_lit "$1")'")
  [ "${n:-0}" -eq 1 ] || die "expected exactly one user with email '$1', found ${n:-0}"
  psql_q "select p.id from app.profile p join auth.users u on u.id = p.auth_user_id
           where u.email = '$(sql_lit "$1")' limit 1"
}

cmd_add_member() {
  local project="$1" email="$2" role="$3"
  local pid uid
  pid=$(project_id_by_name "$project") || exit 1
  uid=$(profile_id_by_email "$email") || exit 1

  psql_q "select api.add_project_member('$pid', '$uid', '$(sql_lit "$role")',
                                        '$(sql_lit "$OPERATOR")')" >/dev/null     || die "could not add $email as $role"
  echo "added $email to $project as $role"
}

cmd_assign() {
  local project="$1" book="$2" chapter="$3" translator="$4" reviewer="${5:-}"
  local pid tid rid cid
  pid=$(project_id_by_name "$project") || exit 1
  tid=$(profile_id_by_email "$translator") || exit 1
  rid=""
  [ -n "$reviewer" ] && { rid=$(profile_id_by_email "$reviewer") || exit 1; }

  cid=$(psql_q "select c.id from app.chapter c join app.book b on b.id = c.book_id
                 where b.project_id = '$pid' and b.code = '$(sql_lit "$book")'
                   and c.number = $chapter")
  [ -n "$cid" ] || die "no chapter $book $chapter in project '$project'"

  # api.assign_chapter also writes the change-log entry, which the raw UPDATE
  # here did not - so an assignment made with an older version of this script
  # never reached the translator's device through delta sync.
  psql_q "select api.assign_chapter('$cid',
                                    nullif('$tid','')::uuid,
                                    nullif('$rid','')::uuid,
                                    '$(sql_lit "$OPERATOR")')" >/dev/null     || die "could not assign $book $chapter"
  echo "assigned $book $chapter to $translator${reviewer:+ (reviewer: $reviewer)}"
}

cmd_reset_password() {
  local email="$1" password="$2"

  # APP R-AUTH-7: self-service recovery cannot work against synthetic addresses,
  # so this is the ONLY thing standing between a translator and permanent
  # lockout. The console must expose it.
  local uid
  uid=$(psql_q "select id from auth.users where email = '$(sql_lit "$email")'")
  [ -n "$uid" ] || die "no user with email '$email'"

  local resp
  resp=$(curl -sS -X PUT "$API_URL/auth/v1/admin/users/$uid" \
              -H "apikey: $SERVICE_ROLE_KEY" \
              -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
              -H 'Content-Type: application/json' \
              -d "$(printf '{"password":"%s"}' "$password")")
  [ -n "$(json_field "$resp" id)" ] || die "password reset failed: $(printf '%s' "$resp" | head -c 300)"

  # Re-arm the forced change and re-fingerprint, or complete_password_change
  # would compare against a stale value (R-AUTH-DB-7).
  psql_q "update app.profile
             set must_change_password = true,
                 initial_password_fingerprint =
                   (select md5(coalesce(u.encrypted_password, ''))
                      from auth.users u where u.id = '$uid')
           where auth_user_id = '$uid'" >/dev/null

  audit 'profile.password_reset' 'profile' \
        "$(psql_q "select id from app.profile where auth_user_id = '$uid'")"
  echo "password reset for $email; they must change it at next sign-in"
}

cmd_list() {
  echo "== projects =="
  psql "$DB_URL" -c "select p.name, p.language_name, p.versification_scheme,
                            count(distinct b.id) as books,
                            count(distinct m.profile_id) as members
                       from app.project p
                       left join app.book b on b.project_id = p.id
                       left join app.project_member m on m.project_id = p.id
                      where p.archived_at is null
                      group by p.id, p.name, p.language_name, p.versification_scheme
                      order by p.name"
  echo "== members =="
  psql "$DB_URL" -c "select pr.name as project, u.email, m.role, pf.must_change_password
                       from app.project_member m
                       join app.project pr on pr.id = m.project_id
                       join app.profile pf on pf.id = m.profile_id
                       left join auth.users u on u.id = pf.auth_user_id
                      order by pr.name, u.email"
  echo "== assignments =="
  psql "$DB_URL" -c "select pr.name as project, b.code, c.number, c.workflow_state,
                            t.email as translator, r.email as reviewer
                       from app.chapter c
                       join app.book b on b.id = c.book_id
                       join app.project pr on pr.id = b.project_id
                       left join app.profile tp on tp.id = c.assigned_translator_id
                       left join auth.users t on t.id = tp.auth_user_id
                       left join app.profile rp on rp.id = c.assigned_reviewer_id
                       left join auth.users r on r.id = rp.auth_user_id
                      where c.assigned_translator_id is not null
                         or c.assigned_reviewer_id is not null
                      order by pr.name, b.sort_order, c.number"
}

cmd_bootstrap() {
  local email="${1:-translator@local.test}"
  local password="${2:-dev-initial-password}"
  local reviewer_email="reviewer@local.test"

  echo "Creating users..." >&2
  cmd_create_user "Dev Translator" "$email" "$password" >/dev/null
  cmd_create_user "Dev Reviewer" "$reviewer_email" "$password" >/dev/null

  echo "Creating project..." >&2
  cmd_create_project "Dev Project" "Example Language" "Latn" "MAT" >/dev/null

  cmd_add_member "Dev Project" "$email" translator >&2
  cmd_add_member "Dev Project" "$reviewer_email" reviewer >&2
  cmd_assign "Dev Project" MAT 1 "$email" "$reviewer_email" >&2

  cat <<INFO

Ready. Point a client at:

  URL       $API_URL
  anon key  ${ANON_KEY:-<run 'supabase status' to read it>}

  translator  $email / $password
  reviewer    $reviewer_email / $password

Both accounts must change their password before any project data is
readable — that gate is enforced in RLS, not in app navigation
(R-AUTH-DB-8). The flow is:

  POST $API_URL/auth/v1/token?grant_type=password
  PUT  $API_URL/auth/v1/user                     {"password": "..."}
  POST $API_URL/rest/v1/rpc/complete_password_change

The service key is NOT printed and must never reach the app (R-RLS-3).
INFO
}

# ---------------------------------------------------------------------------

main() {
  local cmd="${1:-}"; shift || true
  [ -n "$cmd" ] || { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
  load_config
  case "$cmd" in
    bootstrap)      cmd_bootstrap "$@" ;;
    create-user)    [ $# -eq 3 ] || die "usage: create-user <display-name> <email> <password>"; cmd_create_user "$@" ;;
    create-project) [ $# -ge 3 ] || die "usage: create-project <name> <language> <script> [book...]"; cmd_create_project "$@" ;;
    add-member)     [ $# -eq 3 ] || die "usage: add-member <project> <email> <role>"; cmd_add_member "$@" ;;
    assign)         [ $# -ge 4 ] || die "usage: assign <project> <book> <chapter> <translator-email> [reviewer-email]"; cmd_assign "$@" ;;
    reset-password) [ $# -eq 2 ] || die "usage: reset-password <email> <new-password>"; cmd_reset_password "$@" ;;
    list)           cmd_list ;;
    *)              die "unknown command '$cmd'" ;;
  esac
}

main "$@"
