#!/usr/bin/env bash
# Print the body of a version's section in a plugin CHANGELOG (used for release notes and by version-guard).
# Usage: scripts/changelog-section.sh plugins/<plugin> <version>
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: changelog-section.sh <plugin-dir> <version>" >&2; exit 2; }

awk -v v="$2" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^(## \[|\[[^]]+\]: )/ { exit }
  on { print }
' "$1/CHANGELOG.md"
