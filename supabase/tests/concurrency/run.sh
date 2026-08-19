#!/usr/bin/env bash
#
# Concurrency tests: R-TEST-2 (simultaneous saves) and R-TEST-4 (out-of-order
# commit race).
#
# These live outside the pgTAP suite because they need TWO concurrent database
# sessions, and pgTAP runs in one. The whole point is what happens when two
# transactions overlap, so a single-session approximation cannot cover it —
# 05_sync_search.sql tests the snapshot FILTER, this reproduces the RACE.
#
# Emits TAP on stdout; exit code is the number of failures.
#
#   bash supabase/tests/concurrency/run.sh
#
# Fixtures are COMMITTED, because both sessions must see them, and are torn
# down at the end — unlike the pgTAP files, which roll back. Fixture names are
# prefixed `conc-` so a leftover cannot collide with the pgTAP suite's users.

set -uo pipefail

DB="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

TESTS=0
FAILURES=0

ok()    { TESTS=$((TESTS+1)); echo "ok $TESTS - $1"; }
notok() { TESTS=$((TESTS+1)); FAILURES=$((FAILURES+1)); echo "not ok $TESTS - $1";
          if [ -n "${2:-}" ]; then echo "#   $2"; fi; }
is()    { if [ "$1" = "$2" ]; then ok "$3"; else notok "$3" "got [$1] want [$2]"; fi; }

q() { psql "$DB" -v ON_ERROR_STOP=1 -q -At -c "$1"; }

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

setup() {
  psql "$DB" -v ON_ERROR_STOP=1 -q -f supabase/tests/concurrency/fixture.psql
}

teardown() {
  psql "$DB" -q -f supabase/tests/concurrency/teardown.psql >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Session A: a psql process fed through a FIFO, so its transaction stays open
# across commands.
#
# Progress is signalled with SESSION-level advisory locks, not a marker row:
# anything A writes inside its open transaction is invisible to other sessions
# by definition — which is precisely the situation under test. Advisory locks
# appear in pg_locks immediately.
# ---------------------------------------------------------------------------

FIFO=""
A_PID=""
A_LOG=""

start_session_a() {
  FIFO=$(mktemp -u)
  A_LOG=$(mktemp)
  mkfifo "$FIFO"
  psql "$DB" -v ON_ERROR_STOP=1 -q -At -f "$FIFO" >"$A_LOG" 2>&1 &
  A_PID=$!
  exec 9>"$FIFO"
}

send_a() { printf '%s\n' "$1" >&9; }

stop_session_a() {
  exec 9>&- 2>/dev/null || true
  if [ -n "$A_PID" ]; then wait "$A_PID" 2>/dev/null; fi
  if [ -n "$FIFO" ]; then rm -f "$FIFO"; fi
  A_PID=""
}

wait_for_lock() {          # classid objid
  local i n
  for i in $(seq 1 100); do
    n=$(q "select count(*) from pg_locks where locktype='advisory' and classid=$1 and objid=$2 and granted" 2>/dev/null)
    if [ "${n:-0}" -ge 1 ]; then return 0; fi
    sleep 0.1
  done
  return 1
}

wait_for_blocked_writer() {
  local i n
  for i in $(seq 1 100); do
    n=$(q "select count(*) from pg_stat_activity where query like '%save_verse_text%' and wait_event_type = 'Lock' and pid <> pg_backend_pid()" 2>/dev/null)
    if [ "${n:-0}" -ge 1 ]; then return 0; fi
    sleep 0.1
  done
  return 1
}

cleanup() { stop_session_a; teardown; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "# R-TEST-4: an out-of-order commit must not skip a change-log entry"
# ---------------------------------------------------------------------------

setup

PROJECT=$(q "select id from ctest.fixture where name = 'project'")
VERSE=$(q "select id from ctest.fixture where name = 'verse'")
AUTHUID=$(q "select id from ctest.fixture where name = 'auth_user'")
CLAIMS="{\"sub\":\"$AUTHUID\",\"role\":\"authenticated\"}"

start_session_a

# A takes the LOWER seq and stays open.
send_a "begin;"
send_a "insert into app.change_log (project_id, entity_type, entity_id, op, payload) values ('$PROJECT', 'verse', '$VERSE', 'update', '{\"probe\":\"A\"}'::jsonb);"
send_a "select pg_advisory_lock(9001, 1);"

if wait_for_lock 9001 1; then
  ok "session A holds an open transaction carrying the lower seq"
else
  notok "session A holds an open transaction carrying the lower seq" "timed out waiting for its advisory lock"
  echo "1..$TESTS"
  exit 1
fi

# B takes the HIGHER seq and commits immediately — out of order.
q "insert into app.change_log (project_id, entity_type, entity_id, op, payload) values ('$PROJECT', 'verse', '$VERSE', 'update', '{\"probe\":\"B\"}'::jsonb)" >/dev/null

# Control. The same read WITHOUT the snapshot guard does see B right now.
# This proves the scenario actually reproduces the race: if it ever fails, the
# guarded assertion below is passing vacuously and proves nothing.
NAIVE=$(q "select count(*) from app.change_log where project_id = '$PROJECT' and seq > 0")
if [ "${NAIVE:-0}" -ge 1 ]; then
  ok "control: an unguarded read sees B while A is still in flight"
else
  notok "control: an unguarded read sees B while A is still in flight" \
        "got $NAIVE rows — the race was not reproduced, so the next assertion is meaningless"
fi

# The real assertion. changes_since must withhold B: advancing a cursor past it
# would strand A's lower seq permanently once A commits.
GUARDED=$(q "select set_config('request.jwt.claims', '$CLAIMS', false); select jsonb_array_length(api.changes_since('$PROJECT') -> 'changes')" | tail -1)
is "${GUARDED:-missing}" "0" "changes_since withholds B while A is in flight (R-SYNC-3)"

# A commits, after B.
send_a "commit;"
send_a "select pg_advisory_unlock(9001, 1);"
sleep 0.5

AFTER=$(q "select set_config('request.jwt.claims', '$CLAIMS', false); select jsonb_array_length(api.changes_since('$PROJECT') -> 'changes')" | tail -1)
is "${AFTER:-missing}" "2" "once A commits, both entries are returned and neither is skipped"

SEQ_A=$(q "select seq from app.change_log where project_id = '$PROJECT' and payload->>'probe' = 'A'")
SEQ_B=$(q "select seq from app.change_log where project_id = '$PROJECT' and payload->>'probe' = 'B'")
if [ "${SEQ_A:-0}" -lt "${SEQ_B:-0}" ]; then
  ok "A held the lower seq ($SEQ_A) yet committed after B ($SEQ_B)"
else
  notok "A held the lower seq yet committed after B" "seq_a=$SEQ_A seq_b=$SEQ_B"
fi

stop_session_a

# ---------------------------------------------------------------------------
echo "# R-TEST-2: two simultaneous saves to the same verse"
# ---------------------------------------------------------------------------

start_session_a

send_a "begin;"
send_a "select set_config('request.jwt.claims', '$CLAIMS', false);"
send_a "select set_config('request.headers', '{\"idempotency-key\":\"conc-key-session-a\"}', false);"
send_a "select api.save_verse_text('$VERSE', 'text from A', 'explicit_save');"
send_a "select pg_advisory_lock(9001, 2);"

if wait_for_lock 9001 2; then
  ok "session A saved and holds the verse row lock"
else
  notok "session A saved and holds the verse row lock" "timed out"
  echo "1..$TESTS"
  exit 1
fi

# B attempts the same verse. R-FN-5's FOR UPDATE must serialise it.
B_LOG=$(mktemp)
psql "$DB" -v ON_ERROR_STOP=1 -q -At >"$B_LOG" 2>&1 <<SQL &
select set_config('request.jwt.claims', '$CLAIMS', false);
select set_config('request.headers', '{"idempotency-key":"conc-key-session-b"}', false);
select api.save_verse_text('$VERSE', 'text from B', 'explicit_save');
SQL
B_PID=$!

if wait_for_blocked_writer; then
  ok "session B blocks on A's row lock instead of racing it (R-FN-5)"
else
  notok "session B blocks on A's row lock instead of racing it (R-FN-5)" \
        "B never entered a lock wait, so the two saves did not actually overlap"
fi

send_a "commit;"
send_a "select pg_advisory_unlock(9001, 2);"

wait "$B_PID" 2>/dev/null
B_STATUS=$?
is "$B_STATUS" "0" "session B's save succeeds once A commits"

REV=$(q "select rev from app.verse where id = '$VERSE'")
is "${REV:-missing}" "2" "two concurrent saves produce two distinct rev values, not a collision"

TEXT=$(q "select text from app.verse where id = '$VERSE'")
is "$TEXT" "text from B" "the later arrival wins (APP R-CON-1, last write wins)"

# APP R-CON-2. This is the entire safety net under last-write-wins: there is no
# conflict UI, but no work is destroyed either.
KEPT=$(q "select count(*) from app.verse_revision where verse_id = '$VERSE' and text = 'text from A'")
is "${KEPT:-0}" "1" "the overwritten text survives in revision history (APP R-CON-2)"

REVS=$(q "select count(distinct rev) from app.verse_revision where verse_id = '$VERSE'")
is "${REVS:-0}" "2" "each save captured its own revision at a distinct rev"

rm -f "$B_LOG" "$A_LOG"

echo "1..$TESTS"

# A harness that ran no assertions must not report success. Emitting the count
# is visibility; failing on zero is the guarantee. Without this, a script that
# silently stopped exercising anything would stay green indefinitely.
if [ "$TESTS" -eq 0 ]; then
  echo "Bail out! the harness ran zero assertions"
  exit 1
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "# all $TESTS concurrency assertions passed"
else
  echo "# $FAILURES of $TESTS failed"
fi
exit "$FAILURES"
