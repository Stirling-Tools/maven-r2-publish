#!/usr/bin/env bash
set -euo pipefail

PREFIX="$1"
LOCAL_ROOT="$2"
shift 2
BUCKET="${BUCKET:?BUCKET is required}"
ENDPOINT="${ENDPOINT:?ENDPOINT is required}"
case "$BUCKET" in s3://*) ;; *) BUCKET="s3://$BUCKET" ;; esac
BUCKET="${BUCKET%/}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

taken=0
for dir in "$@"; do
  mapfile -t keys < <(aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "${BUCKET#s3://}" \
    --prefix "$PREFIX$dir/" --query 'Contents[].Key' --output text | tr '\t' '\n' | sed '/^None$/d;/^$/d')
  [ "${#keys[@]}" -eq 0 ] && continue
  differs=0
  for key in "${keys[@]}"; do
    rel="${key#"$PREFIX"}"
    if [ ! -f "$LOCAL_ROOT/$rel" ]; then
      echo "ERROR: $key exists but is not in this upload" >&2
      differs=1
      continue
    fi
    aws s3 cp "$BUCKET/$key" "$TMP/object" --endpoint-url "$ENDPOINT" --only-show-errors
    cmp -s "$TMP/object" "$LOCAL_ROOT/$rel" || { echo "ERROR: $key differs from this upload" >&2; differs=1; }
  done
  if [ "$differs" -eq 0 ]; then
    echo "Resuming $PREFIX$dir: its ${#keys[@]} existing files match this upload"
  else
    echo "ERROR: $PREFIX$dir already exists; published versions are immutable." >&2
    taken=1
  fi
done
exit "$taken"
