#!/usr/bin/env bash
# Troubleshooting log tests (on by default, LINEARB_DEBUG=0 off): pipe hook payloads into the hooks
# with a stubbed curl and check report.log.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT="$ROOT/plugins/agentic-advisor/hooks/agentic-advisor-report.sh"

pass=0; fail=0
check() {
  local name=$1; shift
  if "$@"; then pass=$((pass+1)); printf 'ok   %s\n' "$name"; else fail=$((fail+1)); printf 'FAIL %s\n' "$name"; fi
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }   # GNU first: on Linux `stat -f` means filesystem info

# Shared fixtures: a git repo with a remote, a stub curl that prints $STUB_CODE for -w, a transcript
# with a skill run, a verdict and a code edit.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat > "$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
w=0; o=""; while [ $# -gt 0 ]; do case "$1" in -w) w=1; shift ;; -o) o="$2"; shift ;; esac; shift; done
cat >/dev/null
if [ -n "$o" ] && [ "$o" != /dev/null ]; then
  printf '%s' "${STUB_BODY:-}" > "$o"
  # Record the modes of the response file and the redirected stderr file.
  if [ -n "${STUB_PERMS:-}" ]; then
    for x in "$o" "${o%.out}.err"; do stat -c %a "$x" 2>/dev/null || stat -f %Lp "$x"; done > "$STUB_PERMS"
  fi
fi
if [ -n "${STUB_ERR:-}" ]; then printf '%s\n' "$STUB_ERR" >&2; fi
[ "$w" = 1 ] && printf '%s' "${STUB_CODE:-200}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$W/bin/curl"
REPO="$W/repo"
git init -q "$REPO"
git -C "$REPO" config user.email secret.person@example.com
git -C "$REPO" remote add origin git@github.com:acme/widgets.git
TRANSCRIPT="$W/transcript.jsonl"
line() { jq -nc --arg t "$1" --argjson c "$2" --argjson o "$3" '{timestamp:$t,message:{role:"assistant",model:"m",content:$c,usage:{output_tokens:$o}}}'; }
{
  line 2026-10-11T10:00:00.000Z '[{"type":"tool_use","name":"Skill","input":{"skill":"agentic-advisor"}}]' 50
  line 2026-10-11T10:00:30.000Z '[{"type":"text","text":"> LinearB: widgets — HIGH effort (rework 8%) — careful."}]' 400
  line 2026-10-11T10:02:00.000Z "$(jq -nc --arg f "$REPO/a.py" '[{type:"tool_use",name:"Edit",input:{file_path:$f}}]')" 1200
} > "$TRANSCRIPT"

# run <home> <event> [VAR=value ...] — isolated home/cache, no inherited LinearB env.
run() {
  local h=$1 ev=$2; shift 2
  mkdir -p "$h"
  printf '{"hook_event_name":"%s","session_id":"s-%s","transcript_path":"%s","cwd":"%s"}' \
    "$ev" "$(basename "$h")" "$TRANSCRIPT" "$REPO" \
  | env -u LINEARB_API_TOKEN -u LINEARB_DEBUG -u LINEARB_TELEMETRY -u LB_PLUGIN_REPORT_METRICS_TOKEN \
      HOME="$h" XDG_CACHE_HOME="$h/.cache" XDG_CONFIG_HOME="$h" GIT_CONFIG_NOSYSTEM=1 PATH="$W/bin:$PATH" \
      "$@" bash "$REPORT" 2>"$h/stderr"
  for _ in $(seq 20); do grep -q 'HTTP' "$h/.cache/agentic-advisor/report.log" 2>/dev/null && break; [ "$ev" = Stop ] || break; sleep 0.2; done
  sleep 0.5   # detached post() writes its line after the hook returns
}
LOG() { cat "$1/.cache/agentic-advisor/report.log" 2>/dev/null; }
has() { LOG "$1" | grep -qF -- "$2"; }

H="$W/default"; run "$H" Stop LINEARB_API_TOKEN=test-token
check "log on by default" has "$H" "Stop: sent decision HIGH (widgets) -> HTTP 200"
check "lines carry the plugin version" bash -c "grep -qE ' v[0-9]+\.[0-9]+\.[0-9]+ ' '$H/.cache/agentic-advisor/report.log'"

for v in 0 off false; do
  H="$W/off-$v"; run "$H" Stop LINEARB_API_TOKEN=test-token "LINEARB_DEBUG=$v"
  check "LINEARB_DEBUG=$v: no log" test ! -e "$H/.cache/agentic-advisor/report.log"
done

H="$W/neterr"; run "$H" Stop LINEARB_API_TOKEN=test-token STUB_CODE=000 STUB_RC=6 "STUB_ERR=curl: (6) Could not resolve host: public-api.linearb.io"
check "network error: curl exit and reason logged" has "$H" "HTTP 000 to https://public-api.linearb.io (curl exit 6: curl: (6) Could not resolve host"

H="$W/reject"; run "$H" Stop LINEARB_API_TOKEN=test-token STUB_CODE=422 'STUB_BODY={"error":"bad contributor_email someone@corp.com"}'
check "4xx: server reason logged" has "$H" 'HTTP 422 to https://public-api.linearb.io (response: {"error":"bad contributor_email <email>"})'
check "4xx: email in the response redacted" bash -c "! grep -q 'someone@corp.com' '$H/.cache/agentic-advisor/report.log'"
H="$W/perms"; (umask 022; run "$H" Stop LINEARB_API_TOKEN=test-token "STUB_PERMS=$W/perms.txt")
check "curl response and error files are private (0600)" test "$(sort -u "$W/perms.txt" 2>/dev/null)" = 600
check "temp files cleaned up" bash -c "! ls '$H/.cache/agentic-advisor/' | grep -q payload"

H="$W/notoken"; run "$H" Stop
check "no token: reason logged" has "$H" "skip: LINEARB_API_TOKEN not set"

H="$W/telemetryoff"; run "$H" Stop  LINEARB_API_TOKEN=test-token LINEARB_TELEMETRY=0
check "telemetry off: reason logged" has "$H" "skip: LINEARB_TELEMETRY is off"

H="$W/sent"; run "$H" Stop  LINEARB_API_TOKEN=test-token
run "$H" Stop  LINEARB_API_TOKEN=test-token
run "$H" SessionEnd  LINEARB_API_TOKEN=test-token
check "decision sent: HTTP 200 logged" has "$H" "Stop: sent decision HIGH (widgets) -> HTTP 200"
check "repeat Stop: 'no new verdict' logged" has "$H" "skip: no new verdict since last report"
check "tokens sent at SessionEnd: HTTP 200 logged" has "$H" "SessionEnd: sent tokens HIGH (widgets) -> HTTP 200"
check "log never has the token" bash -c "! grep -q test-token '$H/.cache/agentic-advisor/report.log'"
check "log never has the email" bash -c "! grep -q secret.person '$H/.cache/agentic-advisor/report.log'"
check "log never has the session folder path" bash -c "! grep -qF '$REPO' '$H/.cache/agentic-advisor/report.log'"
check "log file is 0600" test "$(mode "$H/.cache/agentic-advisor/report.log")" = 600

H="$W/rejected"; run "$H" SessionEnd  LINEARB_API_TOKEN=test-token STUB_CODE=401
check "rejected token: HTTP 401 logged (backfilled decision)" has "$H" "SessionEnd: sent decision HIGH (widgets) backfill -> HTTP 401"

H="$W/rotate"; mkdir -p "$H/.cache/agentic-advisor"
(umask 077; head -c 1100000 /dev/zero | tr '\0' x > "$H/.cache/agentic-advisor/report.log")
run "$H" Stop  LINEARB_API_TOKEN=test-token
check "log rotates past 1 MB (old kept)" test -f "$H/.cache/agentic-advisor/report.log.old"
check "log rotates past 1 MB (new is small)" test "$(wc -c < "$H/.cache/agentic-advisor/report.log")" -lt 1000

H="$W/quiet"; run "$H" Stop
check "first debug write prints nothing to stderr" test ! -s "$H/stderr"

H="$W/loose"; mkdir -p "$H/.cache/agentic-advisor"; chmod 755 "$H/.cache/agentic-advisor"
: > "$H/.cache/agentic-advisor/report.log"; chmod 644 "$H/.cache/agentic-advisor/report.log"
run "$H" Stop
check "existing 0644 log tightened to 0600" test "$(mode "$H/.cache/agentic-advisor/report.log")" = 600
check "existing 0755 dir tightened to 0700" test "$(mode "$H/.cache/agentic-advisor")" = 700

H="$W/bigloose"; mkdir -p "$H/.cache/agentic-advisor"
head -c 1100000 /dev/zero | tr '\0' x > "$H/.cache/agentic-advisor/report.log"; chmod 644 "$H/.cache/agentic-advisor/report.log"
run "$H" Stop
check "oversized 0644 log is rotated to a 0600 .old" test "$(mode "$H/.cache/agentic-advisor/report.log.old")" = 600

H="$W/oldlink"; mkdir -p "$H/.cache/agentic-advisor" "$W/planted"
(umask 077; head -c 1100000 /dev/zero | tr '\0' x > "$H/.cache/agentic-advisor/report.log")
ln -s "$W/planted" "$H/.cache/agentic-advisor/report.log.old"
run "$H" Stop
check "rotation never moves the log through a symlinked .old" test -z "$(ls -A "$W/planted")"
check "symlinked .old is replaced by a regular file" test -f "$H/.cache/agentic-advisor/report.log.old"
check "rotated .old is no longer a symlink" test ! -L "$H/.cache/agentic-advisor/report.log.old"

H="$W/olddir"; mkdir -p "$H/.cache/agentic-advisor/report.log.old"
(umask 077; head -c 1100000 /dev/zero | tr '\0' x > "$H/.cache/agentic-advisor/report.log")
run "$H" Stop
check "rotation skipped when .old is a directory (nothing moved into it)" test -z "$(ls -A "$H/.cache/agentic-advisor/report.log.old")"

H="$W/symlink"; mkdir -p "$H/.cache/agentic-advisor"; : > "$W/elsewhere"
ln -s "$W/elsewhere" "$H/.cache/agentic-advisor/report.log"
run "$H" Stop
check "symlinked log is not written through" test ! -s "$W/elsewhere"

# Every-turn noise stays out: no "skill never ran" line on Stop, one at SessionEnd.
NOSKILL="$W/noskill.jsonl"; line 2026-10-11T10:00:00.000Z '[{"type":"text","text":"hello"}]' 5 > "$NOSKILL"
H="$W/noskill"; mkdir -p "$H"
for ev in Stop SessionEnd; do
  printf '{"hook_event_name":"%s","session_id":"ns","transcript_path":"%s","cwd":"%s"}' "$ev" "$NOSKILL" "$REPO" \
    | env -u LINEARB_DEBUG HOME="$H" XDG_CACHE_HOME="$H/.cache" PATH="$W/bin:$PATH" LINEARB_API_TOKEN=test-token bash "$REPORT" 2>/dev/null
  [ "$ev" = Stop ] && check "no 'skill never ran' line on Stop" bash -c "! grep -q 'skill never ran' '$H/.cache/agentic-advisor/report.log' 2>/dev/null"
done
check "'skill never ran' logged at SessionEnd" has "$H" "SessionEnd: skip: skill never ran in this session"

# Without jq the trigger still logs why it stopped, with the plugin version (read without jq).
NOJQ="$W/nojq"; mkdir -p "$NOJQ"
for t in bash sed head date mkdir chmod wc mv rm tr dirname cat printf; do p="$(command -v "$t")" && ln -s "$p" "$NOJQ/$t"; done
H="$W/nojqhome"; mkdir -p "$H"
printf '{"hook_event_name":"UserPromptSubmit"}' | env -u LINEARB_DEBUG HOME="$H" XDG_CACHE_HOME="$H/.cache" PATH="$NOJQ" \
  "$NOJQ/bash" "$ROOT/plugins/agentic-advisor/hooks/agentic-advisor-trigger.sh" >/dev/null 2>&1
check "jq missing: logged with the plugin version" bash -c "grep -qE ' v[0-9]+\.[0-9]+\.[0-9]+ trigger: skip: jq not found' '$H/.cache/agentic-advisor/report.log'"

# The trigger logs its nudges too (ticket key only, never the prompt).
H="$W/trig"; mkdir -p "$H"
printf '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"%s","prompt":"fix ABC-12 secret-words"}' "$REPO" \
  | env -u LINEARB_DEBUG HOME="$H" XDG_CACHE_HOME="$H/.cache" bash "$ROOT/plugins/agentic-advisor/hooks/agentic-advisor-trigger.sh" >/dev/null 2>&1
check "trigger nudge logged" has "$H" "UserPromptSubmit: nudged the agent to run the skill (ticket ABC-12)"
check "trigger never logs the prompt" bash -c "! grep -q 'secret-words' '$H/.cache/agentic-advisor/report.log'"

printf '{"hook_event_name":"Stop","session_id":"nohome","transcript_path":"%s","cwd":"%s"}' "$TRANSCRIPT" "$REPO" \
  | env -u HOME -u XDG_CACHE_HOME -u LINEARB_API_TOKEN -u LB_PLUGIN_REPORT_METRICS_TOKEN  bash "$REPORT" 2>/dev/null
check "HOME and XDG_CACHE_HOME unset: hook still exits 0" test $? -eq 0

printf '{"hook_event_name":"UserPromptSubmit","session_id":"nohome","cwd":"%s","prompt":"fix ABC-1"}' "$REPO" \
  | env -u HOME -u XDG_CACHE_HOME bash "$ROOT/plugins/agentic-advisor/hooks/agentic-advisor-trigger.sh" >/dev/null 2>&1
check "trigger with HOME and XDG_CACHE_HOME unset: exits 0" test $? -eq 0

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
