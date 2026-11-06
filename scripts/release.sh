#!/usr/bin/env bash
set -euo pipefail

STEP="${STEP:?STEP is required}"
BUCKET="${BUCKET:?BUCKET is required}"
ENDPOINT="${ENDPOINT:?ENDPOINT is required}"
PUBLIC_URL="${PUBLIC_URL:?PUBLIC_URL is required}"
PUBLIC_URL="${PUBLIC_URL%/}/"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$BUCKET" in s3://*) ;; *) BUCKET="s3://$BUCKET" ;; esac
BUCKET="${BUCKET%/}"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

STAGING="staging/${GITHUB_REPOSITORY#*/}/${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}/"
STAGING_URL="$PUBLIC_URL$STAGING"
{
  echo "staging-prefix=$STAGING"
  echo "staging-url=$STAGING_URL"
} >> "${GITHUB_OUTPUT:-/dev/null}"

summary() { echo "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }

case "$STEP" in
  stage)
    REPO_DIR="${REPO_DIR:?repo-dir is required for stage}"
    mapfile -t versions < <(cd "$REPO_DIR" && find . -name '*.pom' -exec dirname {} \; | sed 's#^\./##' | sort -u)
    [ "${#versions[@]}" -gt 0 ] || { echo "ERROR: no .pom files under $REPO_DIR" >&2; exit 1; }
    bash "$SCRIPT_DIR/check-absent.sh" "" "${versions[@]}"
    GITHUB_OUTPUT='' REPO_DIR="$REPO_DIR" PREFIX="$STAGING" METADATA=false OVERWRITE=true bash "$SCRIPT_DIR/publish.sh"
    bash "$SCRIPT_DIR/check-served.sh" "$REPO_DIR" "$STAGING_URL"
    summary "### Staged ${#versions[@]} publications at $STAGING_URL"
    ;;
  promote)
    staged="${RUNNER_TEMP:-/tmp}/maven-r2-promote-$GITHUB_RUN_ID"
    rm -rf "$staged"
    mkdir -p "$staged"
    aws s3 sync "$BUCKET/$STAGING" "$staged" --endpoint-url "$ENDPOINT" --no-progress --only-show-errors
    if [ -z "$(find "$staged" -name '*.pom' -print -quit)" ]; then
      echo "ERROR: nothing staged at $BUCKET/$STAGING; run step: stage in this workflow run first" >&2
      exit 1
    fi
    GITHUB_OUTPUT='' REPO_DIR="$staged" PREFIX="" METADATA=true OVERWRITE=false bash "$SCRIPT_DIR/publish.sh"
    bash "$SCRIPT_DIR/check-served.sh" "$staged" "$PUBLIC_URL"
    summary "### Released to $PUBLIC_URL"
    summary ""
    while IFS= read -r v; do summary "- \`$v\`"; done < <(cd "$staged" && find . -name '*.pom' -exec dirname {} \; | sed 's#^\./##' | sort -u)
    rm -rf "$staged"
    ;;
  cleanup)
    aws s3 rm "$BUCKET/$STAGING" --recursive --endpoint-url "$ENDPOINT" --only-show-errors
    echo "Deleted $BUCKET/$STAGING"
    ;;
  *)
    echo "ERROR: step must be stage, promote or cleanup, not '$STEP'" >&2
    exit 2
    ;;
esac
