#!/usr/bin/env bash
set -euo pipefail

PREFIX="$1"
shift
BUCKET="${BUCKET:?BUCKET is required}"
ENDPOINT="${ENDPOINT:?ENDPOINT is required}"
case "$BUCKET" in s3://*) ;; *) BUCKET="s3://$BUCKET" ;; esac
BUCKET="${BUCKET%/}"

taken=0
for dir in "$@"; do
  count=$(aws s3api list-objects-v2 --endpoint-url "$ENDPOINT" --bucket "${BUCKET#s3://}" \
    --prefix "$PREFIX$dir/" --max-items 1 --query 'KeyCount' --output text)
  if [ "$count" != "0" ] && [ "$count" != "None" ]; then
    echo "ERROR: $PREFIX$dir already exists; published versions are immutable." >&2
    taken=1
  fi
done
exit "$taken"
