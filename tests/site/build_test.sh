#!/usr/bin/env bash
# Changelog site: builds from the real CHANGELOGs, every release shows up, markup is escaped.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0; fail=0
check() {
  local name=$1; shift
  if "$@"; then pass=$((pass+1)); printf 'ok   %s\n' "$name"; else fail=$((fail+1)); printf 'FAIL %s\n' "$name"; fi
}

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
"$ROOT/scripts/build-changelog-site.py" "$W/site" >/dev/null
check "index.html built" test -s "$W/site/index.html"
check "feed.xml is valid XML" python3 -c "import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$W/site/feed.xml"

for cl in "$ROOT"/plugins/*/CHANGELOG.md; do
  name="$(basename "$(dirname "$cl")")"
  while read -r v; do
    check "$name $v on the page" grep -qF "id=\"$name-v${v//./-}\"" "$W/site/index.html"
  done < <(sed -n 's/^## \[\([^]]*\)\].*/\1/p' "$cl")
done

# Inline rendering: code and links render, raw HTML in an entry is escaped, non-http links stay text.
cat > "$W/inline.py" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("b", sys.argv[1]); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
print(b.inline("use `<x>` and <script>alert(1)</script> ([#7](https://github.com/o/r/pull/7)) [bad](javascript:alert(1))"))
PY
out="$(python3 "$W/inline.py" "$ROOT/scripts/build-changelog-site.py")"
has() { grep -qF -- "$1" <<<"$out"; }
lacks() { ! has "$1"; }
check "code span escaped" has '<code>&lt;x&gt;</code>'
check "raw html escaped" lacks '<script>'
check "PR link becomes a pill without parens" has '<a class="pr" href="https://github.com/o/r/pull/7">#7</a>'
check "javascript: link not linked" lacks 'href="javascript'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
