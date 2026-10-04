#!/usr/bin/env bash
# Build the Flatpak of Anycubic Slicer Next from Anycubic's official .deb:
# an OSTree repo (for GitHub Pages), a single-file .flatpak bundle and the Pages site.
#
# Usage: scripts/build-flatpak.sh
#
# Environment:
#   DEB_URL, DEB_SHA256  .deb to package (default: query the apt repo via check-upstream.sh)
#   PAGES_URL            public URL of the Pages site (default: derived from $GITHUB_REPOSITORY)
#   FLATPAK_GPG_KEY      ASCII-armored private key to sign repo + summary (unsigned if empty)
#   FLATPAK_BRANCH       Flatpak branch (default: stable)
#   OUT_DIR              bundle output directory (default: ./dist)
#   WORK_DIR             scratch directory (default: ./build/flatpak)
#   SITE_DIR             Pages site output directory (default: ./build/site)
#
# Writes KEY=VALUE lines (app_version, bundle, site_dir, signed) to $GITHUB_OUTPUT when set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ID=com.anycubic.AnycubicSlicer
BRANCH="${FLATPAK_BRANCH:-stable}"
OUT_DIR="$(realpath -m "${OUT_DIR:-$ROOT/dist}")"
WORK_DIR="$(realpath -m "${WORK_DIR:-$ROOT/build/flatpak}")"
SITE_DIR="$(realpath -m "${SITE_DIR:-$ROOT/build/site}")"
GH_REPO="${GITHUB_REPOSITORY:-MineTech13/anycubic-slicer-next}"
GH_OWNER="${GH_REPO%%/*}"
PAGES_URL="${PAGES_URL:-https://${GH_OWNER,,}.github.io/${GH_REPO#*/}}"
PAGES_URL="${PAGES_URL%/}"
FLATHUB_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo

log() { printf '\n==> %s\n' "$*"; }

for tool in flatpak flatpak-builder; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required" >&2; exit 1; }
done

# --------------------------------------------------------------------------- source
if [ -z "${DEB_URL:-}" ] || [ -z "${DEB_SHA256:-}" ]; then
  log "Querying Anycubic apt repository"
  meta="$(GITHUB_OUTPUT="" "$ROOT/scripts/check-upstream.sh")"
  DEB_URL="$(sed -n 's/^deb_url=//p' <<<"$meta")"
  DEB_SHA256="$(sed -n 's/^deb_sha256=//p' <<<"$meta")"
fi
log "Packaging $DEB_URL ($DEB_SHA256)"

SRC="$WORK_DIR/src"
REPO="$WORK_DIR/repo"
rm -rf "$SRC" "$REPO" "$WORK_DIR/build-dir"
mkdir -p "$SRC" "$OUT_DIR"

sed -e "s|@DEB_URL@|$DEB_URL|g" -e "s|@DEB_SHA256@|$DEB_SHA256|g" \
  "$ROOT/flatpak/$APP_ID.yml.in" >"$SRC/$APP_ID.yml"
install -m755 "$ROOT/flatpak/anycubic-slicer.sh" "$SRC/anycubic-slicer.sh"
sed -e "s|^Icon=.*|Icon=$APP_ID|" -e "s|^Exec=.*|Exec=anycubic-slicer %U|" \
  "$ROOT/packaging/AnycubicSlicer.desktop" >"$SRC/$APP_ID.desktop"
# @VERSION@ stays: it is filled in from the package during the Flatpak build.
sed -e "s|@DATE@|$(date -u +%Y-%m-%d)|g" -e "s|@DESKTOP_ID@|$APP_ID.desktop|g" -e "s|@FORMAT@|Flatpak|g" \
  "$ROOT/packaging/appdata.xml.in" >"$SRC/$APP_ID.metainfo.xml.in"

# --------------------------------------------------------------------------- signing
sign_args=()
SIGNED=false
if [ -n "${FLATPAK_GPG_KEY:-}" ]; then
  log "Importing signing key"
  GNUPGHOME="$(mktemp -d)"
  export GNUPGHOME
  trap 'rm -rf "$GNUPGHOME"' EXIT
  gpg --batch --quiet --import <<<"$FLATPAK_GPG_KEY"
  KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
  [ -n "$KEY_ID" ] || { echo "FLATPAK_GPG_KEY contains no secret key" >&2; exit 1; }
  gpg --batch --export "$KEY_ID" >"$WORK_DIR/key.gpg"
  sign_args=(--gpg-sign="$KEY_ID" --gpg-homedir="$GNUPGHOME")
  SIGNED=true
  echo "Signing with $KEY_ID"
else
  echo "FLATPAK_GPG_KEY not set: building an UNSIGNED repo (fine for CI, not for publishing)"
  rm -f "$WORK_DIR/key.gpg"
fi

# --------------------------------------------------------------------------- build
log "Building with flatpak-builder"
flatpak remote-add --user --if-not-exists flathub "$FLATHUB_REPO"
flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse \
  --default-branch="$BRANCH" --force-clean \
  --state-dir="$WORK_DIR/.flatpak-builder" \
  --repo="$REPO" "${sign_args[@]}" \
  "$WORK_DIR/build-dir" "$SRC/$APP_ID.yml"

APP_VERSION="$(tr -d '[:space:]' <"$WORK_DIR/build-dir/files/resources/build-version.txt")"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "Bad app version: '$APP_VERSION'" >&2; exit 1; }
log "App version: $APP_VERSION"

flatpak build-update-repo "${sign_args[@]}" \
  --title="Anycubic Slicer Next (unofficial)" \
  --default-branch="$BRANCH" \
  "$REPO"

# --------------------------------------------------------------------------- bundle
BUNDLE="$OUT_DIR/AnycubicSlicer-$APP_VERSION-x86_64.flatpak"
log "Creating bundle $BUNDLE"
bundle_args=(--runtime-repo="$FLATHUB_REPO" --repo-url="$PAGES_URL/repo/")
if [ "$SIGNED" = true ]; then
  bundle_args+=(--gpg-keys="$WORK_DIR/key.gpg")
fi
flatpak build-bundle "${bundle_args[@]}" "$REPO" "$BUNDLE" "$APP_ID" "$BRANCH"
(cd "$OUT_DIR" && sha256sum "$(basename "$BUNDLE")" >"$BUNDLE.sha256")

# --------------------------------------------------------------------------- Pages site
log "Assembling Pages site in $SITE_DIR"
rm -rf "$SITE_DIR"
mkdir -p "$SITE_DIR"
cp -a "$REPO" "$SITE_DIR/repo"
install -m644 "$WORK_DIR/build-dir/files/share/icons/hicolor/256x256/apps/$APP_ID.png" "$SITE_DIR/icon.png"

gpg_line=""
if [ "$SIGNED" = true ]; then
  install -m644 "$WORK_DIR/key.gpg" "$SITE_DIR/key.gpg"
  gpg_line="GPGKey=$(base64 -w0 "$WORK_DIR/key.gpg")"
fi

cat >"$SITE_DIR/anycubic-slicer.flatpakrepo" <<EOF
[Flatpak Repo]
Title=Anycubic Slicer Next (unofficial)
Url=$PAGES_URL/repo/
Homepage=https://github.com/$GH_REPO
Comment=Unofficial Flatpak builds of Anycubic Slicer Next
Description=Automatically built from the official Anycubic Ubuntu package
Icon=$PAGES_URL/icon.png
$gpg_line
EOF

cat >"$SITE_DIR/$APP_ID.flatpakref" <<EOF
[Flatpak Ref]
Name=$APP_ID
Branch=$BRANCH
Title=Anycubic Slicer Next (unofficial)
Url=$PAGES_URL/repo/
SuggestRemoteName=anycubic-slicer
RuntimeRepo=$FLATHUB_REPO
IsRuntime=false
$gpg_line
EOF

sed -e "s|@PAGES_URL@|$PAGES_URL|g" -e "s|@GH_REPO@|$GH_REPO|g" -e "s|@VERSION@|$APP_VERSION|g" \
  -e "s|@APP_ID@|$APP_ID|g" "$ROOT/flatpak/site/index.html" >"$SITE_DIR/index.html"

du -sh "$SITE_DIR" "$BUNDLE"

out="app_version=$APP_VERSION
bundle=$BUNDLE
site_dir=$SITE_DIR
signed=$SIGNED"
echo "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "$out" >>"$GITHUB_OUTPUT"
fi
