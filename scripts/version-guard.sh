#!/usr/bin/env bash
# Fail if a plugin's shipped files changed vs <base-ref> without a version bump and a CHANGELOG entry.
# Usage: scripts/version-guard.sh origin/main
set -euo pipefail

base="${1:?usage: version-guard.sh <base-ref>}"
cd "$(git rev-parse --show-toplevel)"
# An unknown base would make every diff below empty and pass silently.
git rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "::error::unknown base ref '$base' (fetch it first)"; exit 2; }
status=0

for dir in plugins/*/; do
  dir="${dir%/}"
  name="$(basename "$dir")"
  # README/CHANGELOG edits don't change what users run, so they don't need a release.
  # Process substitution, not a pipe: grep -q exiting early can't fail the check under pipefail.
  grep -qvE "^$dir/(README|CHANGELOG)\.md$" < <(git diff --name-only "$base"...HEAD -- "$dir") || continue

  new="$(jq -r .version "$dir/.claude-plugin/plugin.json")"
  old="$(git show "$base:$dir/.claude-plugin/plugin.json" 2>/dev/null | jq -r .version 2>/dev/null || true)"

  # sort -VCu succeeds only when old < new.
  if [ -n "$old" ] && ! printf '%s\n%s\n' "$old" "$new" | sort -VCu; then
    echo "::error file=$dir/.claude-plugin/plugin.json::$name changed but version was not bumped ($old -> $new)."
    status=1; continue
  fi
  if [ -z "$(scripts/changelog-section.sh "$dir" "$new" | tr -d '[:space:]')" ]; then
    echo "::error file=$dir/CHANGELOG.md::$name $new needs a non-empty '## [$new]' section in CHANGELOG.md."
    status=1; continue
  fi
  echo "$name: ${old:-new} -> $new ok"
done

exit "$status"
