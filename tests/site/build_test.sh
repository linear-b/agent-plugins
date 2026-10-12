#!/usr/bin/env bash
# Site: builds from the real repo, every plugin gets a page and every release shows up, a new plugin
# is picked up with no code change, and markup in READMEs/CHANGELOGs is escaped.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$ROOT/scripts/build-site.py"
pass=0; fail=0
check() {
  local name=$1; shift
  if "$@"; then pass=$((pass+1)); printf 'ok   %s\n' "$name"; else fail=$((fail+1)); printf 'FAIL %s\n' "$name"; fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! has "$1" "$2"; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# The real repo.
"$BUILD" "$W/site" >/dev/null
for f in index.html changelog/index.html feed.xml assets/linearb-logo.svg .nojekyll; do
  check "built $f" test -e "$W/site/$f"
done
check "feed.xml is valid XML" python3 -c "import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$W/site/feed.xml"
for src in $(jq -r '.plugins[].source' "$ROOT/.claude-plugin/marketplace.json"); do
  d="$ROOT/${src#./}"; name="$(basename "$d")"
  check "$name has a page" test -s "$W/site/$name/index.html"
  check "$name is on the home page" has "$W/site/index.html" "href=\"$name/\""
  check "$name managed settings enable it" has "$W/site/$name/index.html" "&quot;$name@linearb-ai&quot;: true"
  while read -r v; do
    check "$name $v in the changelog" has "$W/site/changelog/index.html" "id=\"$name-v${v//./-}\""
  done < <(sed -n 's/^## \[\([^]]*\)\].*/\1/p' "$d/CHANGELOG.md")
done
check "README diagram rendered as a diagram" has "$W/site/agentic-advisor/index.html" '<pre class="mermaid">'
check "README #anchors kept" has "$W/site/agentic-advisor/index.html" 'id="usage-telemetry-on-by-default"'

# A plugin added to the marketplace appears with no code change; one without a CHANGELOG still builds;
# a folder the marketplace doesn't publish gets no page (its install command wouldn't work).
F="$W/repo"; mkdir -p "$F"
cp -R "$ROOT/.claude-plugin" "$ROOT/plugins" "$ROOT/site" "$F/"
mkdir -p "$F/plugins/demo-tool/.claude-plugin" "$F/plugins/bare/.claude-plugin"
printf '{"name":"demo-tool","version":"0.3.0","description":"Demo plugin."}\n' > "$F/plugins/demo-tool/.claude-plugin/plugin.json"
cat > "$F/plugins/demo-tool/README.md" <<'MD'
# demo-tool

Does a demo thing <script>alert(1)</script>.

## Setup

Run `demo <x>` and see [docs](docs/guide.md), [shared](../shared.md), [root](/SECURITY.md) or [bad](javascript:alert(1)).

## Setup

Literal {{CSS}} stays text.

| a | b |
| --- | --- |
| 1 | <img src=x onerror=alert(1)> |
MD
printf '# Changelog\n\n## [0.3.0] - 2026-10-01\n\n### Added\n\n- First release ([#1](https://github.com/o/r/pull/1))\n' > "$F/plugins/demo-tool/CHANGELOG.md"
printf '{"name":"bare","version":"0.0.1"}\n' > "$F/plugins/bare/.claude-plugin/plugin.json"
mkdir -p "$F/plugins/unlisted/.claude-plugin"
printf '{"name":"unlisted","version":"9.9.9"}\n' > "$F/plugins/unlisted/.claude-plugin/plugin.json"
jq '.plugins += [{"name":"demo-tool","source":"./plugins/demo-tool"},{"name":"bare","source":"./plugins/bare"}]' \
  "$ROOT/.claude-plugin/marketplace.json" > "$F/.claude-plugin/marketplace.json"
"$BUILD" "$W/site2" "$F" >/dev/null
P="$W/site2/demo-tool/index.html"
check "new plugin gets a page" test -s "$P"
check "new plugin on the home page" has "$W/site2/index.html" 'href="demo-tool/"'
check "new plugin in the changelog" has "$W/site2/changelog/index.html" 'id="demo-tool-v0-3-0"'
check "new plugin in home managed settings" has "$W/site2/index.html" '&quot;demo-tool@linearb-ai&quot;: true'
check "plugin without README/CHANGELOG still builds" test -s "$W/site2/bare/index.html"
check "README raw html escaped" lacks "$P" '<script>alert'
check "table cell html escaped" lacks "$P" '<img src=x'
check "code span escaped" has "$P" '<code>demo &lt;x&gt;</code>'
check "relative link points at the repo" has "$P" 'href="https://github.com/linear-b/agent-plugins/blob/main/plugins/demo-tool/docs/guide.md"'
check "javascript: link not linked" lacks "$P" 'href="javascript'
check "../ link keeps its parent path" has "$P" 'href="https://github.com/linear-b/agent-plugins/blob/main/plugins/shared.md"'
check "/ link is repo-root relative" has "$P" 'href="https://github.com/linear-b/agent-plugins/blob/main/SECURITY.md"'
check "duplicate headings get unique ids" has "$P" 'id="setup-1"'
check "literal {{CSS}} in a README not substituted" has "$P" 'Literal {{CSS}} stays text'
check "unpublished plugin folder gets no page" test ! -e "$W/site2/unlisted/index.html"
check "unpublished plugin not on the home page" lacks "$W/site2/index.html" 'unlisted@linearb-ai'
check "PR link becomes a pill without parens" has "$W/site2/changelog/index.html" '<a class="pr" href="https://github.com/o/r/pull/1">#1</a>'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
