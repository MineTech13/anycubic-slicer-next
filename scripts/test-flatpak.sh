#!/usr/bin/env bash
# Smoke-test the built Flatpak by installing it from the OSTree repo (like users do).
#
# Usage: scripts/test-flatpak.sh path/to/site/repo
#
# Environment:
#   EXPECTED_VERSION  app version the build must contain (e.g. from the AppImage build)
#   FLATPAK_KEY_FILE  public key the repo is signed with (default: <repo>/../key.gpg if present)
#   LAUNCH_TEST, LAUNCH_SECONDS, LOG_DIR (see scripts/lib/test-common.sh)
set -euo pipefail

REPO="$(realpath "${1:?usage: $0 path/to/repo}")"
# shellcheck source=scripts/lib/test-common.sh
source "$(dirname "$0")/lib/test-common.sh"

APP_ID=com.anycubic.AnycubicSlicer
REMOTE=anycubic-slicer-test
KEY_FILE="${FLATPAK_KEY_FILE:-$(dirname "$REPO")/key.gpg}"

echo "Testing Flatpak repo $REPO"

echo "[repo]"
check "repo config exists" test -f "$REPO/config"
check "summary exists" test -f "$REPO/summary"
check "ref app/$APP_ID/x86_64/stable exists" test -f "$REPO/refs/heads/app/$APP_ID/x86_64/stable"
if [ -f "$KEY_FILE" ]; then
  check "summary is signed" test -s "$REPO/summary.sig"
  gpg_args=(--gpg-import="$KEY_FILE")
else
  skip "repo is unsigned (no key file)"
  gpg_args=(--no-gpg-verify)
fi

echo "[install]"
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak uninstall --user -y --noninteractive "$APP_ID" >/dev/null 2>&1 || true
flatpak remote-delete --user --force "$REMOTE" >/dev/null 2>&1 || true
flatpak remote-add --user "${gpg_args[@]}" "$REMOTE" "file://$REPO"
if flatpak install --user -y --noninteractive "$REMOTE" "$APP_ID//stable"; then
  pass "installs from the repo (runtime from Flathub)"
else
  fail "installation failed"
  finish
fi

check "installed ref is the stable branch" bash -c "flatpak info --user --show-ref $APP_ID | grep -qx 'app/$APP_ID/x86_64/stable'"
check "launch command is anycubic-slicer" bash -c "flatpak info --user --show-metadata $APP_ID | grep -qx 'command=anycubic-slicer'"
check "uses the GNOME runtime" bash -c "flatpak info --user --show-runtime $APP_ID | grep -q '^org.gnome.Platform/'"

FILES="$(flatpak info --user --show-location "$APP_ID")/files"
echo "[contents]"
for p in bin/AnycubicSlicerNext bin/anycubic-slicer lib resources/fonts resources/profiles \
         share/metainfo/$APP_ID.metainfo.xml \
         share/icons/hicolor/256x256/apps/$APP_ID.png share/icons/hicolor/scalable/apps/$APP_ID.svg; do
  check "contains $p" test -e "$FILES/$p"
done

EXPORTS="$HOME/.local/share/flatpak/exports/share"
check "desktop file exported" test -f "$EXPORTS/applications/$APP_ID.desktop"
check "icon exported" test -f "$EXPORTS/icons/hicolor/256x256/apps/$APP_ID.png"
if command -v desktop-file-validate >/dev/null 2>&1; then
  check "desktop file validates" desktop-file-validate "$EXPORTS/applications/$APP_ID.desktop"
fi
if command -v appstreamcli >/dev/null 2>&1; then
  check "metainfo validates" appstreamcli validate --no-net --pedantic=no "$FILES/share/metainfo/$APP_ID.metainfo.xml"
fi

version="$(tr -d '[:space:]' <"$FILES/resources/build-version.txt")"
check "metainfo release version is $version" grep -q "<release version=\"$version\"" "$FILES/share/metainfo/$APP_ID.metainfo.xml"
if [ -n "${EXPECTED_VERSION:-}" ]; then
  check "version matches expected $EXPECTED_VERSION" test "$version" = "$EXPECTED_VERSION"
fi

echo "[libraries]"
missing="$(flatpak run --user --command=sh "$APP_ID" -c 'ldd /app/bin/AnycubicSlicerNext /app/lib/*.so' 2>/dev/null | grep 'not found' | sort -u || true)"
if [ -z "$missing" ]; then
  pass "all shared libraries resolve inside the runtime"
else
  fail "unresolved shared libraries inside the runtime:"
  while IFS= read -r line; do echo "        $line"; done <<<"$missing"
fi

echo "[launch]"
if want_launch; then
  dbus=()
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
    dbus=(dbus-run-session --)
  fi
  launch_check flatpak-launch "${dbus[@]}" \
    xvfb-run -a -s "-screen 0 1920x1080x24" \
    flatpak run --user --env=LIBGL_ALWAYS_SOFTWARE=1 "$APP_ID"
fi

finish
