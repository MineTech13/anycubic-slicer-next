#!/usr/bin/env bash
# Smoke-test a built AppImage.
#
# Usage: scripts/test-appimage.sh path/to/AnycubicSlicer-VERSION-x86_64.AppImage
#
# Environment:
#   LAUNCH_TEST     auto (default: run if xvfb-run is available) | 1 (required) | 0 (skip)
#   LAUNCH_SECONDS  how long the app must stay alive headless (default: 45)
#   LOG_DIR         where to put launch logs (default: ./test-logs)
set -euo pipefail

APPIMAGE="$(realpath "${1:?usage: $0 path/to/AppImage}")"
LAUNCH_TEST="${LAUNCH_TEST:-auto}"
LAUNCH_SECONDS="${LAUNCH_SECONDS:-45}"
LOG_DIR="$(realpath -m "${LOG_DIR:-test-logs}")"

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Testing $APPIMAGE"

echo "[file]"
check "is executable" test -x "$APPIMAGE"
check "is an ELF binary" bash -c "head -c4 '$APPIMAGE' | grep -q ELF"
check "has AppImage type 2 magic" bash -c "[ \"\$(dd if='$APPIMAGE' bs=1 skip=8 count=3 2>/dev/null | od -An -tx1 | tr -d ' ')\" = '414902' ]"
size=$(stat -c %s "$APPIMAGE")
if [ "$size" -gt $((80 * 1024 * 1024)) ]; then pass "size is plausible ($((size / 1024 / 1024)) MiB)"; else fail "size too small ($size bytes)"; fi
if [ -f "$APPIMAGE.sha256" ]; then
  check "sha256 file matches" bash -c "cd '$(dirname "$APPIMAGE")' && sha256sum -c '$(basename "$APPIMAGE").sha256'"
fi

echo "[contents]"
if (cd "$WORK" && "$APPIMAGE" --appimage-extract >/dev/null 2>&1); then
  pass "--appimage-extract works"
else
  fail "--appimage-extract failed"
  exit 1
fi
ROOT="$WORK/squashfs-root"
for p in AppRun bin/AnycubicSlicerNext lib resources/fonts resources/profiles resources/images/AnycubicSlicer.png \
         AnycubicSlicer.desktop AnycubicSlicer.png .DirIcon VERSION usr/share/metainfo/com.anycubic.AnycubicSlicer.appdata.xml; do
  check "contains $p" test -e "$ROOT/$p"
done
check "AppRun is executable" test -x "$ROOT/AppRun"
check "main binary is executable" test -x "$ROOT/bin/AnycubicSlicerNext"
check "AppRun passes bash -n" bash -n "$ROOT/AppRun"
check "AppRun does not cd into the AppDir" bash -c "! grep -qE '^[[:space:]]*cd[[:space:]]' '$ROOT/AppRun'"

version_in_name="$(basename "$APPIMAGE" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
check "VERSION file matches file name ($version_in_name)" bash -c "[ \"\$(cat '$ROOT/VERSION')\" = '$version_in_name' ]"

if command -v desktop-file-validate >/dev/null 2>&1; then
  check "desktop file validates" desktop-file-validate "$ROOT/AnycubicSlicer.desktop"
else
  skip "desktop-file-validate not installed"
fi
if command -v appstreamcli >/dev/null 2>&1; then
  check "appdata validates" appstreamcli validate --no-net --pedantic=no "$ROOT/usr/share/metainfo/com.anycubic.AnycubicSlicer.appdata.xml"
fi

update_info="$("$APPIMAGE" --appimage-updateinformation 2>/dev/null || true)"
if [ -n "$update_info" ]; then
  pass "update information embedded: $update_info"
  if [ -f "$APPIMAGE.zsync" ]; then pass "zsync file present"; else fail "update info set but no .zsync next to AppImage"; fi
else
  skip "no update information embedded (local build)"
fi

echo "[libraries]"
missing="$( (cd "$ROOT" && LD_LIBRARY_PATH="$ROOT/lib:$ROOT/bin" ldd bin/AnycubicSlicerNext lib/*.so) 2>/dev/null | grep 'not found' | sort -u || true)"
if [ -z "$missing" ]; then
  pass "all shared libraries resolve"
else
  fail "unresolved shared libraries:"
  while IFS= read -r line; do echo "        $line"; done <<<"$missing"
fi

echo "[launch]"
run_launch=0
case "$LAUNCH_TEST" in
  1) run_launch=1 ;;
  0) ;;
  auto) command -v xvfb-run >/dev/null 2>&1 && run_launch=1 ;;
esac

if [ "$run_launch" = 1 ]; then
  if ! command -v xvfb-run >/dev/null 2>&1; then
    fail "LAUNCH_TEST=1 but xvfb-run is not installed"
  else
    mkdir -p "$LOG_DIR"
    log="$LOG_DIR/launch.log"
    home="$WORK/home"
    # The slicer aborts if ~/.config does not exist yet.
    mkdir -p "$home/.config" "$home/.local/share" "$home/.cache"
    # Run in its own session: the slicer outlives the AppImage runtime process,
    # so killing only the direct child is not enough.
    HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
      APPIMAGE_EXTRACT_AND_RUN=1 LIBGL_ALWAYS_SOFTWARE=1 GDK_BACKEND=x11 \
      setsid xvfb-run -a -s "-screen 0 1920x1080x24" "$APPIMAGE" >"$log" 2>&1 &
    pid=$!
    rc=124
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
    fi
    echo "        last log lines:"
    grep -vE 'Gtk-CRITICAL|Failed to create hard link|^[[:space:]]*$' "$log" | tail -n 15 | sed 's/^/        | /' || true
  fi
else
  skip "headless launch test (install xvfb or set LAUNCH_TEST=1)"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
