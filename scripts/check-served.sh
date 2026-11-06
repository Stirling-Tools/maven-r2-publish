#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${1:?usage: check-served.sh <repo-dir> <base-url>}"
BASE_URL="${2:?usage: check-served.sh <repo-dir> <base-url>}"
BASE_URL="${BASE_URL%/}/"

cd "$REPO_DIR"
bad=0
ok=0
n=0
while IFS= read -r f; do
  f="${f#./}"
  served=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 "$BASE_URL$f" | sha1sum | cut -d' ' -f1) || served=missing
  if [ "$served" = "$(sha1sum "$f" | cut -d' ' -f1)" ]; then
    ok=$((ok + 1))
  else
    echo "MISMATCH $BASE_URL$f" >&2
    bad=1
  fi
  n=$((n + 1))
done < <(find . -type f ! -name 'maven-metadata.xml*')
echo "$ok of $n files served unchanged from $BASE_URL"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "$ok of $n files served unchanged from $BASE_URL" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$bad"
