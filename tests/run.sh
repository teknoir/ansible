#!/usr/bin/env bash
# Runs every local test of this repo: the inventory unit tests (tests/test_*.py) and the
# playbook suites tests/*/run.sh (fake manifests and stubbed tools; no device, no cluster,
# no root, no network). Usage: tests/run.sh [suite ...]   (suites: unit, k3s-networks, ...)
#
# Under a coding agent (CLAUDECODE, AI_AGENT unless 0/false/no/off, Codex) each suite's full
# output goes to the git-ignored .test-logs/ and only failures, per-suite totals, the exit
# code and the log directory are printed. Humans and CI get the full output.
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo" || exit 1

is_agent() {
  case "${AI_AGENT:-}" in 0 | false | no | off) return 1 ;; "") ;; *) return 0 ;; esac
  [ -n "${CLAUDECODE:-}${CODEX_THREAD_ID:-}${CODEX_SANDBOX:-}" ]
}

suites=("$@")
if [ ${#suites[@]} -eq 0 ]; then
  suites=(unit)
  for f in tests/*/run.sh; do s=${f#tests/}; suites+=("${s%/run.sh}"); done
fi

run_suite() {
  if [ "$1" = unit ]; then
    python3 -m unittest discover -s tests -p 'test_*.py'
  else
    bash "tests/$1/run.sh"
  fi
}

rc=0
if ! is_agent; then
  for s in "${suites[@]}"; do
    echo "== $s"
    run_suite "$s" || rc=1
  done
  exit "$rc"
fi

export NO_COLOR=1 ANSIBLE_NOCOLOR=1
logdir=".test-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$logdir"
for s in "${suites[@]}"; do
  log="$logdir/$s.log"
  run_suite "$s" >"$log" 2>&1
  r=$?
  if [ "$s" = unit ]; then
    totals=$(grep -E '^(Ran |OK|FAILED)' "$log" | tr '\n' ' ')
    [ "$r" -eq 0 ] || grep -vE '^[.EFsx]+$' "$log"
  else
    totals="$(grep -cE '^(ok   |PASS: )' "$log") passed, $(grep -cE '^FAIL( |: )' "$log") failed"
    [ "$r" -eq 0 ] || grep -vE '^(ok   |PASS: |all passed$)' "$log"
  fi
  echo "$s: ${totals% } exit=$r"
  [ "$r" -eq 0 ] || rc=1
done
echo "exit=$rc full logs: $logdir/"
exit "$rc"
