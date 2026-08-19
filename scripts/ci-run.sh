#!/usr/bin/env bash
#
# Run a command, echo its output, and re-emit a digest as a GitHub annotation:
# an error annotation on failure, a notice on success.
#
# Why this exists: GitHub requires sign-in to read Actions logs, even on public
# repositories, and the logs API returns 403 without repository admin rights.
# Annotations are readable through the public API. Without this, a CI result is
# visible from outside only as "Process completed with exit code 1" — or, when
# it passes, as nothing at all.
#
# The success digest earns its place as much as the failure one: a test step
# that quietly stopped running assertions would otherwise stay green forever,
# and "green" would mean "nothing ran" rather than "nothing broke".
#
# Usage:  bash scripts/ci-run.sh "<label>" <command> [args...]

set -uo pipefail

label="$1"
shift

out=$("$@" 2>&1)
code=$?

printf '%s\n' "$out"

# Workflow-command payloads are newline-delimited, so the text must be escaped:
# % first (or it mangles the escapes introduced after it), then CR, then LF.
escape() {
  printf '%s' "$1" \
    | sed -e 's/%/%25/g' -e 's/\r/%0D/g' \
    | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/%0A/g'
}

if [ "$code" -ne 0 ]; then
  printf '::error::%s failed (exit %s): %s\n' \
    "$label" "$code" "$(escape "$(printf '%s' "$out" | tail -c 3000)")"
  exit "$code"
fi

# Success digest: the TAP plan and counts when present, otherwise pg_prove's
# own summary line. grep -c exits 1 on no match but still prints 0, which is
# the value wanted here.
plan=$(printf '%s\n' "$out" | grep -oE '^1\.\.[0-9]+' | tail -1)
oks=$(printf '%s\n'  "$out" | grep -cE '^ok [0-9]+')
noks=$(printf '%s\n' "$out" | grep -cE '^not ok [0-9]+')
prove=$(printf '%s\n' "$out" | grep -oE 'Files=[0-9]+, Tests=[0-9]+' | tail -1)
result=$(printf '%s\n' "$out" | grep -oE '^Result: [A-Z]+' | tail -1)

digest=""
if [ -n "$plan" ];   then digest="$digest $plan ok=$oks not_ok=$noks"; fi
if [ -n "$prove" ];  then digest="$digest $prove"; fi
if [ -n "$result" ]; then digest="$digest $result"; fi
if [ -z "$digest" ]; then digest=" completed"; fi

printf '::notice::%s passed —%s\n' "$label" "$digest"
exit 0
