#!/usr/bin/env bash
# Build an AppImage of Anycubic Slicer Next from Anycubic's official .deb.
#
# Usage:
#   scripts/build-appimage.sh                 # query apt repo, download, verify, build
#   scripts/build-appimage.sh --deb FILE      # build from a local .deb (no checksum check)
#
# Environment:
#   REGION         global (default) | china
#   OUT_DIR        output directory (default: ./dist)
#   WORK_DIR       scratch directory (default: ./build)
#   UPDATE_REPO    owner/repo for embedded zsync update info (default: $GITHUB_REPOSITORY)
#   APPIMAGETOOL   path to an existing appimagetool binary (downloaded otherwise)
#
# Writes KEY=VALUE lines (app_version, appimage, ...) to $GITHUB_OUTPUT when set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$(realpath -m "${OUT_DIR:-$ROOT/dist}")"
WORK_DIR="$(realpath -m "${WORK_DIR:-$ROOT/build}")"
UPDATE_REPO="${UPDATE_REPO:-${GITHUB_REPOSITORY:-}}"
ARCH=x86_64
APP_NAME=AnycubicSlicer

DEB_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --deb) DEB_FILE="$(realpath "$2")"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

mkdir -p "$OUT_DIR" "$WORK_DIR"

# --------------------------------------------------------------------------- download
DEB_SHA256=""
DEB_VERSION=""
DEB_FILENAME=""
if [ -z "$DEB_FILE" ]; then
  log "Querying Anycubic apt repository"
  meta="$(GITHUB_OUTPUT="" "$ROOT/scripts/check-upstream.sh")"
  get() { sed -n "s/^$1=//p" <<<"$meta"; }
  DEB_URL="$(get deb_url)"
  DEB_SHA256="$(get deb_sha256)"
  DEB_VERSION="$(get deb_version)"
  DEB_FILENAME="$(get deb_filename)"
  DEB_FILE="$WORK_DIR/$DEB_FILENAME"

  if [ -f "$DEB_FILE" ] && echo "$DEB_SHA256  $DEB_FILE" | sha256sum -c --status; then
    log "Using cached $DEB_FILENAME"
  else
    log "Downloading $DEB_URL"
    curl -fL --retry 5 --retry-delay 10 -o "$DEB_FILE.part" "$DEB_URL"
    mv "$DEB_FILE.part" "$DEB_FILE"
  fi

  log "Verifying SHA256"
  echo "$DEB_SHA256  $DEB_FILE" | sha256sum -c -
else
  [ -f "$DEB_FILE" ] || { echo "No such file: $DEB_FILE" >&2; exit 1; }
  DEB_FILENAME="$(basename "$DEB_FILE")"
  DEB_SHA256="$(sha256sum "$DEB_FILE" | cut -d' ' -f1)"
fi

# --------------------------------------------------------------------------- extract
EXTRACT_DIR="$WORK_DIR/extracted"
log "Extracting $DEB_FILENAME"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -x "$DEB_FILE" "$EXTRACT_DIR"
  [ -n "$DEB_VERSION" ] || DEB_VERSION="$(dpkg-deb -f "$DEB_FILE" Version)"
else
  tmp="$(mktemp -d)"
  (cd "$tmp" && ar x "$DEB_FILE")
  tar -xf "$tmp"/data.tar.* -C "$EXTRACT_DIR"
  rm -rf "$tmp"
fi

USR="$EXTRACT_DIR/usr"
RES_SRC="$USR/share/AnycubicSlicerNext/resources"
BIN_SRC="$USR/bin/AnycubicSlicerNext"
for p in "$BIN_SRC" "$USR/lib" "$RES_SRC"; do
  [ -e "$p" ] || { echo "Unexpected package layout: missing $p" >&2; exit 1; }
done

# --------------------------------------------------------------------------- version
APP_VERSION=""
if [ -f "$RES_SRC/build-version.txt" ]; then
  APP_VERSION="$(tr -d '[:space:]' <"$RES_SRC/build-version.txt")"
fi
if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  APP_VERSION="$(grep -aoE 'AnycubicSlicerNext/[0-9]+(\.[0-9]+)+' "$BIN_SRC" | head -1 | cut -d/ -f2 || true)"
fi
if ! [[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "Could not determine app version" >&2
  exit 1
fi
log "App version: $APP_VERSION (deb version: ${DEB_VERSION:-unknown})"

# --------------------------------------------------------------------------- AppDir
APPDIR="$WORK_DIR/$APP_NAME.AppDir"
log "Assembling $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"

cp -a "$USR/bin" "$APPDIR/"
mkdir -p "$APPDIR/lib"
# Only runtime shared objects; skip static archives and cmake files.
find "$USR/lib" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) -exec cp -a {} "$APPDIR/lib/" \;
cp -a "$RES_SRC" "$APPDIR/resources"
[ -f "$USR/LICENSE.txt" ] && cp -a "$USR/LICENSE.txt" "$APPDIR/"
chmod +x "$APPDIR/bin/AnycubicSlicerNext"

install -Dm755 "$ROOT/packaging/AppRun" "$APPDIR/AppRun"

install -Dm644 "$ROOT/packaging/$APP_NAME.desktop" "$APPDIR/usr/share/applications/$APP_NAME.desktop"
ln -s "usr/share/applications/$APP_NAME.desktop" "$APPDIR/$APP_NAME.desktop"

install -Dm644 "$RES_SRC/images/$APP_NAME.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_NAME.png"
if [ -f "$RES_SRC/images/$APP_NAME.svg" ]; then
  install -Dm644 "$RES_SRC/images/$APP_NAME.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/$APP_NAME.svg"
fi
ln -s "usr/share/icons/hicolor/256x256/apps/$APP_NAME.png" "$APPDIR/$APP_NAME.png"
ln -s "$APP_NAME.png" "$APPDIR/.DirIcon"

mkdir -p "$APPDIR/usr/share/metainfo"
sed -e "s|@VERSION@|$APP_VERSION|g" -e "s|@DATE@|$(date -u +%Y-%m-%d)|g" \
  "$ROOT/packaging/appdata.xml.in" >"$APPDIR/usr/share/metainfo/com.anycubic.AnycubicSlicer.appdata.xml"
echo "$APP_VERSION" >"$APPDIR/VERSION"

# --------------------------------------------------------------------------- appimagetool
APPIMAGETOOL="${APPIMAGETOOL:-}"
if [ -z "$APPIMAGETOOL" ]; then
  APPIMAGETOOL="$WORK_DIR/appimagetool-$ARCH.AppImage"
  if [ ! -x "$APPIMAGETOOL" ]; then
    log "Downloading appimagetool"
    curl -fL --retry 5 -o "$APPIMAGETOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
    chmod +x "$APPIMAGETOOL"
  fi
fi

OUTPUT="$OUT_DIR/$APP_NAME-$APP_VERSION-$ARCH.AppImage"
rm -f "$OUTPUT" "$OUTPUT.zsync" "$OUTPUT.sha256"

tool_args=(--no-appstream)
if [ -n "$UPDATE_REPO" ]; then
  tool_args+=(-u "gh-releases-zsync|${UPDATE_REPO%%/*}|${UPDATE_REPO#*/}|latest|$APP_NAME-*$ARCH.AppImage.zsync")
fi

log "Running appimagetool"
# APPIMAGE_EXTRACT_AND_RUN lets appimagetool itself run without FUSE (CI containers).
(
  cd "$OUT_DIR"
  ARCH=$ARCH VERSION="$APP_VERSION" APPIMAGE_EXTRACT_AND_RUN=1 \
    "$APPIMAGETOOL" "${tool_args[@]}" "$APPDIR" "$OUTPUT"
)
chmod +x "$OUTPUT"

if [ -n "$UPDATE_REPO" ] && [ ! -f "$OUTPUT.zsync" ]; then
  if command -v zsyncmake >/dev/null 2>&1; then
    (cd "$OUT_DIR" && zsyncmake -u "$(basename "$OUTPUT")" -o "$OUTPUT.zsync" "$OUTPUT")
  else
    echo "Warning: no .zsync produced and zsyncmake not available" >&2
  fi
fi

(cd "$OUT_DIR" && sha256sum "$(basename "$OUTPUT")" >"$OUTPUT.sha256")

log "Built $OUTPUT"
ls -la "$OUT_DIR"

out="app_version=$APP_VERSION
deb_version=$DEB_VERSION
deb_filename=$DEB_FILENAME
deb_sha256=$DEB_SHA256
appimage=$OUTPUT"
echo "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "$out" >>"$GITHUB_OUTPUT"
fi
