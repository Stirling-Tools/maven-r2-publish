#!/usr/bin/env bash
set -euo pipefail

GROUP="${GROUP:?group is required}"
ARTIFACT="${ARTIFACT:?artifact is required}"
MODULES="${MODULES:-$ARTIFACT}"
VERSIONS="${VERSIONS:-all}"
LATEST="${LATEST:-5}"
SOURCE="${SOURCE:?source is required}"
SOURCE="${SOURCE%/}"
PUBLIC_URL="${PUBLIC_URL:?public-url is required}"
PUBLIC_URL="${PUBLIC_URL%/}/"
DESTINATION="${DESTINATION:-}"
DRY_RUN="${DRY_RUN:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEST="${DESTINATION#/}"
case "$DEST" in
  *..*|*//*) echo "ERROR: destination '$DESTINATION' is not a plain prefix" >&2; exit 1 ;;
esac
[ -z "$DEST" ] || DEST="${DEST%/}/"
[[ "$LATEST" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: latest must be a positive number" >&2; exit 1; }
[[ "$GROUP" =~ ^[A-Za-z0-9_.-]+$ && "$ARTIFACT" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "ERROR: bad group or artifact" >&2; exit 1; }
GROUP_PATH="${GROUP//.//}"
URL="$PUBLIC_URL$DEST"
SRC="$SOURCE/$GROUP_PATH"

summary() { echo "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
get() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --max-time 300 "$@"; }

if [ "$VERSIONS" = all ]; then
  mapfile -t wanted < <(get "$SRC/$ARTIFACT/maven-metadata.xml" \
    | grep -o '<version>[^<]*</version>' | sed 's#</\{0,1\}version>##g' | sort -V | tail -n "$LATEST")
else
  mapfile -t wanted < <(echo "$VERSIONS" | tr -s ', ' '\n' | sed '/^$/d')
fi
[ "${#wanted[@]}" -gt 0 ] || { echo "ERROR: no versions to copy" >&2; exit 1; }

summary "### Copy $GROUP:$ARTIFACT from $SOURCE to $URL"
summary ""
summary "| Version | Action |"
summary "|---|---|"
copy=()
for v in "${wanted[@]}"; do
  [[ "$v" =~ ^[0-9A-Za-z.+-]+$ ]] || { echo "ERROR: bad version '$v'" >&2; exit 1; }
  if curl -fsS -r 0-0 -o /dev/null "$URL$GROUP_PATH/$ARTIFACT/$v/$ARTIFACT-$v.pom" 2>/dev/null; then
    action="already there, skipped"
  elif ! curl -fsS -r 0-0 -o /dev/null "$SRC/$ARTIFACT/$v/$ARTIFACT-$v.pom" 2>/dev/null; then
    echo "ERROR: $v is not in $SOURCE" >&2
    exit 1
  else
    action="copy"
    copy+=("$v")
  fi
  echo "$v: $action"
  summary "| $v | $action |"
done

{
  echo "versions=$(printf '%s\n' "${copy[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
  echo "url=$URL"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ "$DRY_RUN" = true ] || [ "${#copy[@]}" -eq 0 ]; then
  exit 0
fi

WORK="${RUNNER_TEMP:-/tmp}/maven-r2-mirror-${GITHUB_RUN_ID:-local}"
rm -rf "$WORK"
mkdir -p "$WORK"
mapfile -t modules < <(get "$SRC/" | grep -o 'href="[^"/]*/' | cut -d'"' -f2 | tr -d / \
  | while read -r m; do for p in $MODULES; do [[ "$m" == "$p"* ]] && { echo "$m"; break; }; done; done)
for v in "${copy[@]}"; do
  for m in "${modules[@]}"; do
    listing=$(curl -fsSL --retry 5 --retry-delay 5 "$SRC/$m/$v/" 2>/dev/null) || continue
    for f in $(echo "$listing" | grep -o 'href="[^"]*"' | cut -d'"' -f2 | grep -v '/' ); do
      get --create-dirs -o "$WORK/$GROUP_PATH/$m/$v/$f" "$SRC/$m/$v/$f"
    done
  done
  [ -f "$WORK/$GROUP_PATH/$ARTIFACT/$v/$ARTIFACT-$v.pom" ] || { echo "ERROR: nothing downloaded for $v" >&2; exit 1; }
  echo "$v: $(find "$WORK" -path "*/$v/*" -type f | wc -l | tr -d ' ') files"
done

bad=0
while IFS= read -r sum; do
  file="${sum%.sha1}"
  [ -f "$file" ] || continue
  [ "$(sha1sum "$file" | cut -d' ' -f1)" = "$(tr -d ' \n' < "$sum" | cut -c1-40)" ] || { echo "MISMATCH $file" >&2; bad=1; }
done < <(find "$WORK" -name '*.sha1')
[ "$bad" -eq 0 ] || exit 1
echo "Every downloaded file matches its source sha1"

GITHUB_OUTPUT='' REPO_DIR="$WORK" PREFIX="$DEST" METADATA=true OVERWRITE=false bash "$SCRIPT_DIR/publish.sh"
bash "$SCRIPT_DIR/check-served.sh" "$WORK" "$URL"
rm -rf "$WORK"
