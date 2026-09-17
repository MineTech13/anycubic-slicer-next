#!/usr/bin/env bash
# Query Anycubic's apt repository for the current AnycubicSlicerNext .deb.
#
# Prints KEY=VALUE lines (and appends them to $GITHUB_OUTPUT when set):
#   deb_url, deb_filename, deb_version, deb_sha256, deb_size, hint_version
set -euo pipefail

REGION="${REGION:-global}"
case "$REGION" in
  global) REPO_URL="https://cdn-universe-slicer.anycubic.com/prod" ;;
  china)  REPO_URL="https://cdn-platform-slicer.anycubicloud.com/prod" ;;
  *) echo "Unknown REGION: $REGION (use global or china)" >&2; exit 1 ;;
esac
PACKAGES_URL="$REPO_URL/dists/noble/main/binary-amd64/Packages"
PACKAGE_NAME="anycubicslicernext"

packages="$(curl -fsSL --retry 5 --retry-delay 5 "$PACKAGES_URL")"

# Pick the stanza for our package; if there are several, take the highest version.
stanza="$(awk -v pkg="$PACKAGE_NAME" '
  BEGIN { RS = ""; FS = "\n" }
  $0 ~ "(^|\n)Package: " pkg "(\n|$)" { print; print "" }
' <<<"$packages")"

if [ -z "$stanza" ]; then
  echo "Package $PACKAGE_NAME not found in $PACKAGES_URL" >&2
  exit 1
fi

field() { awk -v f="$1" 'BEGIN{RS="";FS="\n"} {for(i=1;i<=NF;i++) if (index($i, f": ")==1) print substr($i, length(f)+3)}' <<<"$stanza"; }

best_version="$(field Version | sort -V | tail -1)"
stanza="$(awk -v v="$best_version" 'BEGIN{RS="";FS="\n"} $0 ~ "(^|\n)Version: " v "(\n|$)" {print; exit}' <<<"$stanza")"

deb_filename="$(field Filename)"
deb_sha256="$(field SHA256)"
deb_size="$(field Size)"
deb_version="$(field Version)"

for v in deb_filename deb_sha256 deb_size deb_version; do
  if [ -z "${!v}" ]; then
    echo "Missing field for $v in Packages stanza" >&2
    exit 1
  fi
done

# Best-effort guess of the real app version from the filename (e.g. ..._linux-v2.0.0.5-2026...).
# The authoritative version is read from the extracted package during the build.
hint_version="$(grep -oE 'v[0-9]+(\.[0-9]+){2,3}' <<<"$(basename "$deb_filename")" | head -1 | tr -d v || true)"

out="deb_url=$REPO_URL/$deb_filename
deb_filename=$(basename "$deb_filename")
deb_version=$deb_version
deb_sha256=$deb_sha256
deb_size=$deb_size
hint_version=$hint_version"

echo "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "$out" >>"$GITHUB_OUTPUT"
fi
