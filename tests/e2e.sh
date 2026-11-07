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
REPO_DIR="$WORK/c" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null || fail "identical re-upload"
ok "re-uploading identical bytes is a no-op"
echo changed >> "$WORK/c/com/example/demo/1.0.0/demo-1.0.0.jar"
if REPO_DIR="$WORK/c" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null 2>&1; then fail "overwrite allowed"; fi
ok "an existing version with different bytes is refused"
REPO_DIR="$WORK/c" PREFIX="$RUN/raw" OVERWRITE=true bash "$S/publish.sh" >/dev/null
bash "$S/check-served.sh" "$WORK/c" "$PUBLIC_URL$RUN/raw/" >/dev/null && ok "overwrite=true replaces it" || fail "overwrite"

bash "$ROOT/tests/make-repo.sh" "$WORK/d" 2.0.0
REPO_DIR="$WORK/d" PREFIX="$RUN/nometa" METADATA=false bash "$S/publish.sh" >/dev/null
if curl -fsS -r 0-0 -o /dev/null "$PUBLIC_URL$RUN/nometa/com/example/demo/maven-metadata.xml" 2>/dev/null; then fail "metadata written"; fi
ok "metadata=false writes no metadata"

if bash "$S/check-served.sh" "$WORK/a" "$PUBLIC_URL$RUN/nometa/" >/dev/null 2>&1; then fail "served check passed on missing files"; fi
ok "the served check fails when files are missing"

bash "$ROOT/tests/make-repo.sh" "$WORK/q" 1.0.1-rc1
REPO_DIR="$WORK/q" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null
meta=$(curl -fsSL "$PUBLIC_URL$RUN/raw/com/example/demo/maven-metadata.xml")
grep -q '<release>1.0.1</release>' <<<"$meta" && grep -q '<latest>1.0.1</latest>' <<<"$meta" || fail "pre-release outranked the release: $meta"
ok "a later pre-release does not become latest or release"

bash "$ROOT/tests/make-repo.sh" "$WORK/p" 4.0.0
aws s3 cp "$WORK/p/com/example/demo/4.0.0/demo-4.0.0.pom" "s3://${BUCKET#s3://}/$RUN/raw/com/example/demo/4.0.0/demo-4.0.0.pom" --endpoint-url "$ENDPOINT" --only-show-errors
REPO_DIR="$WORK/p" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null
bash "$S/check-served.sh" "$WORK/p" "$PUBLIC_URL$RUN/raw/" >/dev/null || fail "resume"
ok "an interrupted upload resumes when the files already there match"

bash "$ROOT/tests/make-repo.sh" "$WORK/x" 5.0.0
echo other > "$WORK/x.pom"
aws s3 cp "$WORK/x.pom" "s3://${BUCKET#s3://}/$RUN/raw/com/example/demo/5.0.0/demo-5.0.0.pom" --endpoint-url "$ENDPOINT" --only-show-errors
if REPO_DIR="$WORK/x" PREFIX="$RUN/raw" bash "$S/publish.sh" >/dev/null 2>&1; then fail "conflicting partial accepted"; fi
ok "a partial version with different bytes is refused"

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
STEP=promote PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null || fail "re-promote"
ok "re-running a finished promote is a no-op"
echo rebuilt >> "$WORK/r/com/example/demo/3.0.0/demo-3.0.0.jar"
if STEP=stage REPO_DIR="$WORK/r" PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=other bash "$S/release.sh" >/dev/null 2>&1; then fail "stage of released version"; fi
left=$( (aws s3 ls "s3://${BUCKET#s3://}/staging/e2e/other/" --recursive --endpoint-url "$ENDPOINT" || true) | wc -l | tr -d ' ')
[ "$left" = 0 ] || fail "rejected stage uploaded $left files"
ok "staging a rebuild of a released version fails before uploading"

bash "$ROOT/tests/make-repo.sh" "$WORK/s" 6.0.0
STEP=stage REPO_DIR="$WORK/s" PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=resume bash "$S/release.sh" >/dev/null
aws s3 cp "$WORK/s/com/example/demo/6.0.0/demo-6.0.0.jar" "s3://${BUCKET#s3://}/com/example/demo/6.0.0/demo-6.0.0.jar" --endpoint-url "$ENDPOINT" --only-show-errors
STEP=promote PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=resume bash "$S/release.sh" >/dev/null || fail "promote resume"
curl -fsSL "${PUBLIC_URL}com/example/demo/maven-metadata.xml" | grep -q '<version>6.0.0</version>' || fail "resume metadata"
STEP=cleanup PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=resume bash "$S/release.sh" >/dev/null
ok "a promote interrupted after uploading some files resumes on re-run"

STEP=cleanup PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null
left=$( (aws s3 ls "s3://${BUCKET#s3://}/staging/e2e/$GITHUB_RUN_ID/" --recursive --endpoint-url "$ENDPOINT" || true) | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "cleanup deletes the staging copy" || fail "cleanup left $left"
if STEP=promote PUBLIC_URL="$PUBLIC_URL" GITHUB_RUN_ID=nothing bash "$S/release.sh" >/dev/null 2>&1; then fail "promote with nothing staged"; fi
ok "promote without a stage fails"
if STEP=bogus PUBLIC_URL="$PUBLIC_URL" bash "$S/release.sh" >/dev/null 2>&1; then fail "bogus step"; fi
ok "an unknown step is rejected"

SRCDIR="$WORK/src"
bash "$ROOT/tests/make-repo.sh" "$SRCDIR" 7.0.0 7.1.0-rc1 7.1.0
rm -rf "$SRCDIR/com/example/demo-extra/7.1.0"
printf '<metadata><versioning><versions><version>7.0.0</version><version>7.1.0-rc1</version><version>7.1.0</version></versions></versioning></metadata>\n' > "$SRCDIR/com/example/demo/maven-metadata.xml"
python3 -m http.server 9876 --bind 127.0.0.1 --directory "$SRCDIR" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 20); do curl -fs http://127.0.0.1:9876/ >/dev/null && break; sleep 0.5; done
: > "$GITHUB_OUTPUT"
GROUP=com.example ARTIFACT=demo VERSIONS=all LATEST=1 SOURCE=http://127.0.0.1:9876 DESTINATION="$RUN/localmirror" PUBLIC_URL="$PUBLIC_URL" bash "$S/mirror.sh" >/dev/null
kill "$SRV"
grep -q '^versions=\["7.1.0"\]$' "$GITHUB_OUTPUT" || fail "latest by Maven order: $(cat "$GITHUB_OUTPUT")"
curl -fsS "$PUBLIC_URL$RUN/localmirror/com/example/demo/7.1.0/demo-7.1.0.jar" >/dev/null || fail "local mirror copy"
if curl -fsS -r 0-0 -o /dev/null "$PUBLIC_URL$RUN/localmirror/com/example/demo-extra/7.1.0/demo-extra-7.1.0.pom" 2>/dev/null; then fail "absent module copied"; fi
ok "mirror picks the latest by Maven order and skips a module the version does not have"

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
