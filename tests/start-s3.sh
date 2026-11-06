#!/usr/bin/env bash
set -euo pipefail

: "${ENDPOINT:?}" "${BUCKET:?}"
pipx install --quiet 'moto[server]==5.2.5'
nohup moto_server -p "${ENDPOINT##*:}" > "${RUNNER_TEMP:-/tmp}/moto.log" 2>&1 &
for _ in $(seq 1 30); do
  curl -fs "$ENDPOINT" >/dev/null && break
  sleep 1
done
aws s3 mb "s3://$BUCKET" --endpoint-url "$ENDPOINT"
aws s3api put-bucket-policy --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --policy \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
