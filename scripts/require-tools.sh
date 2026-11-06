#!/usr/bin/env bash
set -euo pipefail

missing=0
for tool in aws python3 curl sha1sum; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is not on PATH" >&2; missing=1; }
done
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: bash 4 or newer is required; use a Linux runner" >&2
  missing=1
fi
exit "$missing"
