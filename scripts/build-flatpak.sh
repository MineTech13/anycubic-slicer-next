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
# shellcheck source=packaging/app.env
source "$ROOT/packaging/app.env"
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

REPO="$WORK_DIR/repo"
rm -rf "$WORK_DIR/src" "$WORK_DIR/legacy" "$REPO" "$WORK_DIR/build-dir"
mkdir -p "$OUT_DIR"

# render_sources APP_ID DIR [DESKTOP-EXTRA-LINE]: write the manifest and its local files.
render_sources() {
  local id="$1" dir="$2" extra="${3:-}"
  mkdir -p "$dir"
  sed -e "s|@APP_ID@|$id|g" -e "s|@DEB_URL@|$DEB_URL|g" -e "s|@DEB_SHA256@|$DEB_SHA256|g" \
    "$ROOT/flatpak/manifest.yml.in" >"$dir/$id.yml"
  install -m755 "$ROOT/flatpak/anycubic-slicer.sh" "$dir/anycubic-slicer.sh"
  sed -e "s|^Icon=.*|Icon=$id|" -e "s|^Exec=.*|Exec=anycubic-slicer %U|" \
    "$ROOT/packaging/AnycubicSlicer.desktop" >"$dir/$id.desktop"
  if [ -n "$extra" ]; then echo "$extra" >>"$dir/$id.desktop"; fi
  # @VERSION@ stays: it is filled in from the package during the Flatpak build.
  sed -e "s|@APP_ID@|$id|g" -e "s|@DATE@|$(date -u +%Y-%m-%d)|g" -e "s|@DESKTOP_ID@|$id.desktop|g" \
    -e "s|@FORMAT@|Flatpak|g" "$ROOT/packaging/appdata.xml.in" >"$dir/$id.metainfo.xml.in"
}

# build_app MANIFEST BUILD_DIR REPO [extra flatpak-builder args...]
build_app() {
  local manifest="$1" build_dir="$2" repo="$3"; shift 3
  flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse \
    --default-branch="$BRANCH" --force-clean \
    --state-dir="$WORK_DIR/.flatpak-builder" \
    --repo="$repo" "$@" "$build_dir" "$manifest"
}

# Keeps pinned launchers working for users migrated from the legacy ID.
render_sources "$APP_ID" "$WORK_DIR/src" "${LEGACY_APP_ID:+X-Flatpak-RenamedFrom=$LEGACY_APP_ID.desktop;}"

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
build_app "$WORK_DIR/src/$APP_ID.yml" "$WORK_DIR/build-dir" "$REPO" "${sign_args[@]}"

APP_VERSION="$(tr -d '[:space:]' <"$WORK_DIR/build-dir/files/resources/build-version.txt")"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]] || { echo "Bad app version: '$APP_VERSION'" >&2; exit 1; }
log "App version: $APP_VERSION"

# --------------------------------------------------------------------------- legacy ID
# The same app is also committed under the legacy ID, marked end-of-life with a rebase
# to APP_ID: `flatpak update` then replaces old installs with the new ID and migrates
# their data (~/.var/app). Identical files are stored only once in the repo.
if [ -n "${LEGACY_APP_ID:-}" ]; then
  log "Committing $LEGACY_APP_ID as end-of-life, rebased to $APP_ID"
  render_sources "$LEGACY_APP_ID" "$WORK_DIR/legacy/src"
  build_app "$WORK_DIR/legacy/src/$LEGACY_APP_ID.yml" "$WORK_DIR/legacy/build-dir" "$WORK_DIR/legacy/repo"
  mapfile -t legacy_refs < <(cd "$WORK_DIR/legacy/repo/refs/heads" && find . -type f -path "*/$LEGACY_APP_ID*" | sed 's|^\./||')
  [ "${#legacy_refs[@]}" -gt 0 ] || { echo "No legacy refs were built" >&2; exit 1; }
  printf '  %s\n' "${legacy_refs[@]}"
  flatpak build-commit-from --no-update-summary "${sign_args[@]}" \
    --src-repo="$WORK_DIR/legacy/repo" \
    --end-of-life-rebase="$LEGACY_APP_ID=$APP_ID" \
    "$REPO" "${legacy_refs[@]}"
fi

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
  -e "s|@APP_ID@|$APP_ID|g" -e "s|@LEGACY_APP_ID@|${LEGACY_APP_ID:-}|g" \
  "$ROOT/flatpak/site/index.html" >"$SITE_DIR/index.html"

du -sh "$SITE_DIR" "$BUNDLE"

out="app_version=$APP_VERSION
bundle=$BUNDLE
site_dir=$SITE_DIR
signed=$SIGNED"
echo "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "$out" >>"$GITHUB_OUTPUT"
fi
