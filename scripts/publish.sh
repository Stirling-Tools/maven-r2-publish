#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:?REPO_DIR is required}"
BUCKET="${BUCKET:?BUCKET is required}"
ENDPOINT="${ENDPOINT:?ENDPOINT is required}"
PREFIX="${PREFIX:-}"
METADATA="${METADATA:-true}"
OVERWRITE="${OVERWRITE:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$BUCKET" in s3://*) ;; *) BUCKET="s3://$BUCKET" ;; esac
BUCKET="${BUCKET%/}"
if [ -n "$PREFIX" ]; then
  PREFIX="${PREFIX#/}"
  PREFIX="${PREFIX%/}/"
fi

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

s3() { aws s3 "$@" --endpoint-url "$ENDPOINT" --no-progress --only-show-errors; }

cd "$REPO_DIR"
mapfile -t VERSION_DIRS < <(find . -name '*.pom' -exec dirname {} \; | sed 's#^\./##' | sort -u)
if [ "${#VERSION_DIRS[@]}" -eq 0 ]; then
  echo "ERROR: no .pom files under $REPO_DIR" >&2
  exit 1
fi

if [ "$OVERWRITE" != true ]; then
  bash "$SCRIPT_DIR/check-absent.sh" "$PREFIX" "${VERSION_DIRS[@]}"
fi

find . -name 'maven-metadata.xml*' -delete
s3 sync . "$BUCKET/$PREFIX"
echo "Uploaded ${#VERSION_DIRS[@]} publications to $BUCKET/$PREFIX"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "versions<<__VERSIONS__"
    printf '%s\n' "${VERSION_DIRS[@]}"
    echo "__VERSIONS__"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$METADATA" != true ]; then
  exit 0
fi

mapfile -t ARTIFACT_DIRS < <(printf '%s\n' "${VERSION_DIRS[@]}" | xargs -n1 dirname | sort -u)
for artifact in "${ARTIFACT_DIRS[@]}"; do
  live="$artifact/maven-metadata.live.xml"
  s3 cp "$BUCKET/$PREFIX$artifact/maven-metadata.xml" "$live" >/dev/null 2>&1 || rm -f "$live"
  mapfile -t new_versions < <(printf '%s\n' "${VERSION_DIRS[@]}" | grep "^$artifact/[^/]*$" | xargs -n1 basename)
  python3 -I "$SCRIPT_DIR/maven_metadata.py" "$artifact" "$live" "${new_versions[@]}"
  rm -f "$live"
  for f in "$artifact"/maven-metadata.xml*; do
    s3 cp "$f" "$BUCKET/$PREFIX$f"
  done
done
echo "Updated maven-metadata.xml for ${#ARTIFACT_DIRS[@]} artifacts under $BUCKET/$PREFIX"
