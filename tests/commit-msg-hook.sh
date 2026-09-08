#!/bin/sh
# Check accepted and rejected commit-message headers without creating commits.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
message=$(mktemp)
trap 'rm -f "$message"' EXIT HUP INT TERM
for header in 'feat: add menus' 'fix(navigation): visit adjacent rows' 'feat(api)!: change callback input' 'refactor!: simplify views'; do
  printf '%s\n' "$header" > "$message"
  "$repo/.githooks/commit-msg" "$message"
done
for header in '' 'Add menus' 'feat: ' 'feat(): invalid scope' 'unknown: invalid type'; do
  printf '%s\n' "$header" > "$message"
  if "$repo/.githooks/commit-msg" "$message" 2>/dev/null; then
    printf 'Unexpectedly accepted: %s\n' "$header" >&2
    exit 1
  fi
done
: > "$message"
if "$repo/.githooks/commit-msg" "$message" 2>/dev/null; then
  printf 'Unexpectedly accepted an empty message file.\n' >&2
  exit 1
fi
printf 'Commit-message hook checks passed.\n'
