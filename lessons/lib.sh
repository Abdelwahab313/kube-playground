#!/bin/sh
# Shared helpers for lesson check.sh scripts. Source it, do not run it.

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# check "description" command...   -> pass if command exits 0
check() {
  desc=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# check_eq "description" expected command...   -> pass if stdout equals expected
check_eq() {
  desc=$1; expected=$2; shift 2
  actual=$("$@" 2>/dev/null)
  if [ "$actual" = "$expected" ]; then pass "$desc"; else fail "$desc (got: '${actual:-<empty>}', want: '$expected')"; fi
}

# check_contains "description" needle command...
check_contains() {
  desc=$1; needle=$2; shift 2
  actual=$("$@" 2>/dev/null)
  case "$actual" in
    *"$needle"*) pass "$desc" ;;
    *) fail "$desc (no '$needle' in output)" ;;
  esac
}

summary() {
  echo
  echo "passed: $PASS  failed: $FAIL"
  [ "$FAIL" -eq 0 ] && echo "LESSON COMPLETE" || echo "not yet, keep going"
  [ "$FAIL" -eq 0 ]
}
