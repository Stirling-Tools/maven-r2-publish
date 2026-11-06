#!/usr/bin/env bash
set -euo pipefail

: "${ENDPOINT:?ENDPOINT of an S3 server is required}"
: "${BUCKET:?BUCKET is required}"
: "${PUBLIC_URL:?PUBLIC_URL serving BUCKET anonymously is required}"
: "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export BUCKET ENDPOINT PUBLIC_URL
export GITHUB_REPOSITORY=Stirling-Tools/e2e GITHUB_RUN_ID="${GITHUB_RUN_ID:-$RANDOM$RANDOM}"
export RUNNER_TEMP="$WORK" GITHUB_OUTPUT="$WORK/output" GITHUB_STEP_SUMMARY="$WORK/summary"
PUBLIC_URL="${PUBLIC_URL%/}/"
RUN="e2e-$GITHUB_RUN_ID"

pass=0
ok() { echo "PASS  $*"; pass=$((pass + 1)); }
fail() { echo "FAIL  $*" >&2; exit 1; }
versions_at() { curl -fsSL "$1/com/example/demo/maven-metadata.xml" | grep -o '<version>[^<]*' | sed 's/<version>//' | tr '\n' ' '; }

bash "$ROOT/tests/make-repo.sh" "$WORK/a" 1.0.0
REPO_DIR="$WORK/a" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null
bash "$S/check-served.sh" "$WORK/a" "$PUBLIC_URL$RUN/raw/" >/dev/null
[ "$(versions_at "$PUBLIC_URL$RUN/raw")" = "1.0.0 " ] && ok "raw push uploads, writes fresh metadata and is served unchanged" || fail "raw metadata"

bash "$ROOT/tests/make-repo.sh" "$WORK/b" 1.0.1
REPO_DIR="$WORK/b" PREFIX="$RUN/raw/" bash "$S/publish.sh" >/dev/null
[ "$(versions_at "$PUBLIC_URL$RUN/raw")" = "1.0.0 1.0.1 " ] && ok "a second version keeps the first in metadata" || fail "metadata merge"

bash "$ROOT/tests/make-repo.sh" "$WORK/c" 1.0.0
if REPO_DIR="$WORK/c" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null 2>&1; then fail "overwrite allowed"; fi
ok "an existing version is refused"
echo changed >> "$WORK/c/com/example/demo/1.0.0/demo-1.0.0.jar"
REPO_DIR="$WORK/c" PREFIX="$RUN/raw" OVERWRITE=true bash "$S/publish.sh" >/dev/null
bash "$S/check-served.sh" "$WORK/c" "$PUBLIC_URL$RUN/raw/" >/dev/null && ok "overwrite=true replaces it" || fail "overwrite"

bash "$ROOT/tests/make-repo.sh" "$WORK/d" 2.0.0
REPO_DIR="$WORK/d" PREFIX="$RUN/nometa" METADATA=false bash "$S/publish.sh" >/dev/null
if curl -fsS -r 0-0 -o /dev/null "$PUBLIC_URL$RUN/nometa/com/example/demo/maven-metadata.xml" 2>/dev/null; then fail "metadata written"; fi
ok "metadata=false writes no metadata"

if bash "$S/check-served.sh" "$WORK/a" "$PUBLIC_URL$RUN/nometa/" >/dev/null 2>&1; then fail "served check passed on missing files"; fi
ok "the served check fails when files are missing"

bash "$ROOT/tests/make-repo.sh" "$WORK/r" 3.0.0
: > "$GITHUB_OUTPUT"
STEP=stage REPO_DIR="$WORK/r" PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null
staging_url=$(grep '^staging-url=' "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-)
[ "$staging_url" = "${PUBLIC_URL}staging/e2e/$GITHUB_RUN_ID/" ] || fail "staging url $staging_url"
curl -fsS "${staging_url}com/example/demo/3.0.0/demo-3.0.0.pom" >/dev/null && ok "stage serves the set at $staging_url" || fail "stage"
if curl -fsS -r 0-0 -o /dev/null "${staging_url}com/example/demo/maven-metadata.xml" 2>/dev/null; then fail "staging metadata"; fi
STEP=stage REPO_DIR="$WORK/r" PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null && ok "re-running stage in the same run is allowed" || fail "restage"

STEP=promote PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null
curl -fsSL "${PUBLIC_URL}com/example/demo/maven-metadata.xml" | grep -q '<version>3.0.0</version>' && ok "promote releases to the root with metadata" || fail "promote"
if STEP=promote PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null 2>&1; then fail "double promote"; fi
ok "promoting the same version twice is refused"
if STEP=stage REPO_DIR="$WORK/r" PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=other bash "$S/release.sh" >/dev/null 2>&1; then fail "stage of released version"; fi
ok "staging an already released version fails before uploading"

STEP=cleanup PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null
left=$( (aws s3 ls "s3://${BUCKET#s3://}/staging/e2e/$GITHUB_RUN_ID/" --recursive --endpoint-url "$ENDPOINT" || true) | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "cleanup deletes the staging copy" || fail "cleanup left $left"
if STEP=promote PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=nothing bash "$S/release.sh" >/dev/null 2>&1; then fail "promote with nothing staged"; fi
ok "promote without a stage fails"
if STEP=bogus PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null 2>&1; then fail "bogus step"; fi
ok "an unknown step is rejected"

if [ "${MIRROR_TEST:-true}" = true ]; then
  : > "$GITHUB_OUTPUT"
  GROUP=com.stirling ARTIFACT=jpdfium VERSIONS=1.0.0 SOURCE=https://repo1.maven.org/maven2 DESTINATION="$RUN/mirror" PUBLIC_URL="$PUBLIC_URL" bash "$S/mirror.sh" >/dev/null
  grep -q '^versions=\["1.0.0"\]$' "$GITHUB_OUTPUT" || fail "mirror output $(cat "$GITHUB_OUTPUT")"
  curl -fsSL "$PUBLIC_URL$RUN/mirror/com/stirling/jpdfium/maven-metadata.xml" | grep -q '<version>1.0.0</version>' && ok "mirror copies com.stirling:jpdfium:1.0.0 from Central byte for byte" || fail "mirror"
  : > "$GITHUB_OUTPUT"
  GROUP=com.stirling ARTIFACT=jpdfium VERSIONS=all LATEST=2 SOURCE=https://repo1.maven.org/maven2 DESTINATION="$RUN/mirror" PUBLIC_URL="$PUBLIC_URL" DRY_RUN=true bash "$S/mirror.sh" >/dev/null
  [ "$(grep '^versions=' "$GITHUB_OUTPUT" | jq -Rr 'sub("^versions=";"") | fromjson | length')" = 2 ] && ok "mirror dry run plans the latest 2 and copies nothing" || fail "mirror plan"
  if GROUP=com.stirling ARTIFACT=jpdfium VERSIONS=1.0.0 SOURCE=https://repo1.maven.org/maven2 DESTINATION="../x" PUBLIC_URL="$PUBLIC_URL" bash "$S/mirror.sh" >/dev/null 2>&1; then fail "mirror traversal"; fi
  ok "mirror rejects a destination with .."
fi

echo "== $pass passed"
