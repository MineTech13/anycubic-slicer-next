# shellcheck shell=bash
# Shared helpers for scripts/test-*.sh. Source it; do not execute.
#
# Environment:
#   LAUNCH_TEST     auto (default: run if xvfb-run is available) | 1 (required) | 0 (skip)
#   LAUNCH_SECONDS  how long the app must stay alive headless (default: 45)
#   LOG_DIR         where to put launch logs (default: ./test-logs)

LAUNCH_TEST="${LAUNCH_TEST:-auto}"
LAUNCH_SECONDS="${LAUNCH_SECONDS:-45}"
LOG_DIR="$(realpath -m "${LOG_DIR:-test-logs}")"

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

# Returns 0 when the headless launch test should run; records a failure or skip otherwise.
want_launch() {
  local have=0
  command -v xvfb-run >/dev/null 2>&1 && have=1
  case "$LAUNCH_TEST" in
    0) skip "headless launch test (LAUNCH_TEST=0)"; return 1 ;;
    1) [ "$have" = 1 ] && return 0; fail "LAUNCH_TEST=1 but xvfb-run is not installed"; return 1 ;;
    *) [ "$have" = 1 ] && return 0; skip "headless launch test (install xvfb or set LAUNCH_TEST=1)"; return 1 ;;
  esac
}

# launch_check NAME COMMAND...
# Runs COMMAND (which must start the app under xvfb-run) for $LAUNCH_SECONDS and
# checks that it neither crashes nor exits early, and that the bundled fonts load.
launch_check() {
  local name="$1"; shift
  mkdir -p "$LOG_DIR"
  local log="$LOG_DIR/$name.log" pid rc=124
  # Run in its own session: the slicer can outlive the process we started
  # (AppImage runtime, flatpak run), so the whole process group is killed afterwards.
  setsid "$@" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq "$LAUNCH_SECONDS"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
      set +e; wait "$pid"; rc=$?; set -e
      break
    fi
  done
  kill -TERM -- "-$pid" 2>/dev/null || true
  sleep 3
  kill -KILL -- "-$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  echo "        exit code: $rc (124 = still running at timeout)"
  if grep -qE 'error while loading shared libraries|symbol lookup error|version `GLIBC' "$log"; then
    fail "dynamic linking error during launch"
  elif grep -qE 'Segmentation fault|core dumped|Aborted' "$log" || [ "$rc" -eq 139 ] || [ "$rc" -eq 134 ]; then
    fail "application crashed during launch"
  elif [ "$rc" -eq 124 ]; then
    pass "application stayed alive for ${LAUNCH_SECONDS}s"
  else
    fail "application exited early with code $rc"
  fi
  if grep -q 'add font of' "$log"; then
    if grep 'add font of' "$log" | grep -qv 'returns 1'; then
      fail "some bundled fonts failed to load (resource path problem)"
    else
      pass "bundled fonts loaded"
    fi
  else
    fail "no font loading output (app did not get far enough)"
  fi
  echo "        last log lines:"
  grep -vE 'Gtk-CRITICAL|Failed to create hard link|^[[:space:]]*$' "$log" | tail -n 15 | sed 's/^/        | /' || true
}

finish() {
  echo
  if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
  fi
  echo "All checks passed"
}
