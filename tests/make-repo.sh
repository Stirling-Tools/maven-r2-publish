#!/usr/bin/env bash
set -euo pipefail

OUT="${1:?usage: make-repo.sh <dir> <version>...}"
shift
for v in "$@"; do
  for artifact in demo demo-extra; do
    dir="$OUT/com/example/$artifact/$v"
    mkdir -p "$dir"
    printf '<project><groupId>com.example</groupId><artifactId>%s</artifactId><version>%s</version></project>\n' "$artifact" "$v" > "$dir/$artifact-$v.pom"
    printf 'jar %s %s\n' "$artifact" "$v" > "$dir/$artifact-$v.jar"
    for f in "$dir"/*; do
      sha1sum "$f" | cut -d' ' -f1 > "$f.sha1"
    done
  done
  printf 'stale\n' > "$OUT/com/example/demo/maven-metadata.xml"
done
