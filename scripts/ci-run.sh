#!/usr/bin/env bash
#
# Run a command, echo its output, and on failure re-emit the tail as a GitHub
# error annotation.
#
# Why this exists: GitHub requires sign-in to read Actions logs, even on public
# repositories, and the logs API returns 403 without repository admin rights.
# Annotations, by contrast, are readable through the public API. Without this,
# a CI failure is visible only as "Process completed with exit code 1" to
# anyone who cannot sign in to the repo — which makes diagnosing a red build a
# guessing game.
#
# Usage:  bash scripts/ci-run.sh "<label>" <command> [args...]

set -uo pipefail

label="$1"
shift

out=$("$@" 2>&1)
code=$?

printf '%s\n' "$out"

if [ "$code" -ne 0 ]; then
  # Workflow commands are newline-delimited, so the payload must be escaped:
  # % first (or it would mangle the escapes introduced after it), then CR, then
  # LF. Trimmed to the last 3000 bytes because annotation messages are capped.
  msg=$(printf '%s' "$out" \
        | tail -c 3000 \
        | sed -e 's/%/%25/g' -e 's/\r/%0D/g' \
        | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/%0A/g')
  printf '::error::%s failed (exit %s): %s\n' "$label" "$code" "$msg"
fi

exit "$code"
