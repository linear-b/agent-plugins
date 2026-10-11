#!/usr/bin/env bash
# Hook tests: pipe fixture hook payloads into the scripts with a stubbed curl on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS="$ROOT/plugins/agentic-advisor/hooks"
TRIGGER="$HOOKS/agentic-advisor-trigger.sh"
REPORT="$HOOKS/agentic-advisor-report.sh"

pass=0; fail=0
check() {
  local name=$1; shift
  if "$@"; then pass=$((pass+1)); printf 'ok   %s\n' "$name"; else fail=$((fail+1)); printf 'FAIL %s\n' "$name"; fi
}

# Fresh sandbox per test: private cache dir, a git repo with a remote, stub curl, empty transcript.
setup() {
  T="$(mktemp -d)"
  export HOME="$T/home" XDG_CACHE_HOME="$T/cache"
  mkdir -p "$HOME" "$T/bin" "$T/curl"
  REPO="$T/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email dev@example.com
  git -C "$REPO" remote add origin git@github.com:acme/widgets.git
  cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
  # Write then rename, so await_calls never sees a half-written payload.
  case "\$1" in --data-binary) tmp="\$(mktemp "$T/payload.XXXXXX")"; cat "\${2#@}" > "\$tmp"; mv "\$tmp" "$T/curl/call.\${tmp##*.}"; shift ;; esac
  shift
done
cat >/dev/null
STUB
  chmod +x "$T/bin/curl"
  export PATH="$T/bin:$PATH"
  TRANSCRIPT="$T/transcript.jsonl"
  : > "$TRANSCRIPT"
  export LINEARB_API_TOKEN="test-token"
  unset LINEARB_TELEMETRY LINEARB_BASELINE_HOLDOUT_PCT CLAUDE_PLUGIN_ROOT
}
teardown() { rm -rf "$T"; }

payload() { # $1 event, $2 extra json fields
  printf '{"hook_event_name":"%s","session_id":"s1","cwd":"%s","transcript_path":"%s"%s}' "$1" "$REPO" "$TRANSCRIPT" "${2:-}"
}
tool() { printf ',"tool_name":"%s","tool_input":{"file_path":"%s"}' "$1" "$REPO/$2"; }
prompt() { printf ',"prompt":"%s"' "$1"; }
run() { out="$(payload "$2" "${3:-}" | "$1")"; rc=$?; } # $1 script, $2 event, $3 extra fields

silent()  { [ "$rc" -eq 0 ] && [ -z "$out" ]; }
nudged()  { [ "$rc" -eq 0 ] && jq -e '.hookSpecificOutput.additionalContext | contains("agentic-advisor")' <<<"$out" >/dev/null; }
denied()  { [ "$rc" -eq 0 ] && jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null; }
add_skill()   { printf '%s\n' '{"timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","model":"m","usage":{"output_tokens":10},"content":[{"type":"tool_use","name":"Skill","input":{"skill":"agentic-advisor:agentic-advisor"}}]}}' >> "$TRANSCRIPT"; }
add_verdict() { printf '%s\n' '{"timestamp":"2026-01-01T00:00:05Z","message":{"role":"assistant","model":"m","usage":{"output_tokens":20},"content":[{"type":"text","text":"> LinearB: widgets — MEDIUM effort (rework 6.5%) — focused diff."}]}}' >> "$TRANSCRIPT"; }
# Reporter posts from a detached subshell; wait briefly for the stub to record calls.
ncalls() { find "$T/curl" -type f | wc -l | tr -d ' '; }
await_calls() { local _; for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(ncalls)" -ge "$1" ] && return; sleep 0.2; done; }
call_json() { cat "$T/curl"/call.* 2>/dev/null; }
no_calls()  { [ "$rc" -eq 0 ] && [ "$(ncalls)" = 0 ]; }
one_decision() {
  [ "$rc" -eq 0 ] && [ "$(ncalls)" = 1 ] && call_json | jq -e '.value == 2 and .tags.effort_level == "MEDIUM" and .tags.phase == "decision" and .entity.repo_url == "https://github.com/acme/widgets.git"' >/dev/null
}
backfilled() { call_json | jq -se 'any(.[]; .tags.phase == "decision" and .tags.backfill == "session_end")' >/dev/null; }

# --- trigger: UserPromptSubmit ---
setup
run "$TRIGGER" UserPromptSubmit "$(prompt 'fix the login bug LINBEE-123')"
check "trigger: ticket prompt nudges" nudged
run "$TRIGGER" UserPromptSubmit "$(prompt 'fix the login bug LINBEE-123')"
check "trigger: nudges once per session+repo" silent
teardown

setup
run "$TRIGGER" UserPromptSubmit "$(prompt 'what time is it?')"
check "trigger: non-code prompt is silent" silent
teardown

# --- trigger: PreToolUse grade-before-edit hold ---
setup
run "$TRIGGER" PreToolUse "$(tool Edit app.js)"
check "trigger: first source edit is held" denied
run "$TRIGGER" PreToolUse "$(tool Edit app.js)"
check "trigger: hold happens only once" silent
teardown

setup
run "$TRIGGER" PreToolUse "$(tool Edit README.md)"
check "trigger: docs edit is never held" silent
teardown

setup
add_skill
run "$TRIGGER" PreToolUse "$(tool Read app.js)"
check "trigger: skill ran without verdict -> hold for verdict" denied
teardown

setup
add_skill; add_verdict
run "$TRIGGER" PreToolUse "$(tool Edit app.js)"
check "trigger: verdict printed -> edit allowed" silent
teardown

# --- reporter ---
setup
add_skill; add_verdict
run "$REPORT" Stop
await_calls 1
check "report: Stop sends one DECISION" one_decision
run "$REPORT" Stop
sleep 0.5 # a wrong resend would arrive from a detached subshell
check "report: repeated Stop does not resend" one_decision
teardown

setup
add_skill; add_verdict
run "$REPORT" SessionEnd
await_calls 2 # decision + tokens, posted concurrently
check "report: SessionEnd backfills a missed DECISION" backfilled
teardown

# Both exit before any background post, so no wait is needed.
setup
add_skill; add_verdict
unset LINEARB_API_TOKEN
run "$REPORT" Stop
check "report: no token -> silent no-op" no_calls
teardown

setup
add_skill; add_verdict
LINEARB_TELEMETRY=0 run "$REPORT" Stop
check "report: LINEARB_TELEMETRY=0 opts out" no_calls
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
