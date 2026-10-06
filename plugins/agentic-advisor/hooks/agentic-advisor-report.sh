#!/usr/bin/env bash
# Reporter for the agentic-advisor skill. Fires on BOTH Stop and SessionEnd,
# reporting two different things at the two different times they become knowable:
#
#   Stop (per turn; the first one after the verdict wins) -> DECISION event.
#     value = grade (1/2/3) + grade metadata + grading_tokens. This is the adoption
#     and grade record, and it fires the moment the verdict exists — so it survives a
#     session that never ends cleanly (closed terminal, Ctrl-C, crash). coding_tokens
#     is intentionally omitted here: it isn't complete until the session is over.
#
#   SessionEnd (once, best-effort) -> coding_tokens.
#     graded   -> a TOKENS event (value 0, effort_level kept, phase=tokens) carrying
#                 the whole-session coding_tokens for the efficiency experiment.
#     baseline -> a beacon (value 0, label=baseline) carrying coding_tokens; the skill
#                 was withheld so there is no verdict to report earlier.
#
# Why split them: coding_tokens is the only datum that genuinely needs the full
# session, and SessionEnd is best-effort (Claude Code may skip it on SIGKILL and does
# not wait for it). Reporting the grade only at SessionEnd meant a hard-killed session
# lost the grade AND the tokens — so real adopters silently never showed up. Now the
# grade is reported early and reliably; only the token measurement rides the fragile
# end-of-session event, and losing a few of those just costs one session's tokens.
#
# Analysis notes:
#   * adoption / grade counts -> the DECISION rows (value 1/2/3, phase=decision or, on
#     historical data, no phase tag). Dedup by (session, repo, effort).
#   * coding_tokens -> the phase=tokens rows (value 0) and baseline beacons; the
#     effort_level tag is preserved on the tokens rows for stratified comparison.
#   The value=0 on tokens/baseline rows keeps existing countIf(value=1/2/3) charts from
#   double-counting a graded session.
#
# Design goals — this must NEVER get in the developer's way:
#   * Opt-in: no token in env  -> silent no-op. Nobody is broken by default.
#   * Fire-and-forget: short curl timeout, all failures swallowed, always exit 0.
#   * Secret-safe: the token is only ever passed as an env-var reference to curl.
#
# Env: LINEARB_API_TOKEN — required to report; without it this is a silent no-op.
#      LINEARB_API_URL — API base URL (default https://public-api.linearb.io); set it
#      for on-prem or regional LinearB deployments.
#      LINEARB_BASELINE_HOLDOUT_PCT (default 0 — disabled) — % of sessions withheld as a no-grade
#      baseline for a graded-vs-baseline holdout; set e.g. 20 to run that experiment.

set -uo pipefail

API_URL="${LINEARB_API_URL:-https://public-api.linearb.io}"
REPORT_URL="${API_URL%/}/api/v1/report/metric"
METRIC_NAME="agentic_advisor.effort_decision"
SOURCE="claude-code"
BASELINE_PCT="${LINEARB_BASELINE_HOLDOUT_PCT:-0}"

token="${LINEARB_API_TOKEN:-}"
[ -n "$token" ] || exit 0

command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

input="$(cat)"
event="$(jq -r '.hook_event_name // empty'      <<<"$input" 2>/dev/null || true)"
session_id="$(jq -r '.session_id // empty'      <<<"$input" 2>/dev/null || true)"
transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null || true)"
cwd="$(jq -r '.cwd // empty'                     <<<"$input" 2>/dev/null || true)"
effort_actual="$(jq -r '.effort.level // empty'  <<<"$input" 2>/dev/null || true)"
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Act on Stop (early, reliable grade) and SessionEnd (late, complete coding_tokens) only.
case "$event" in Stop|SessionEnd) : ;; *) exit 0 ;; esac

# sha1 helper — shasum is macOS-only; sha1sum is the GNU/Linux name. Portable across both.
sha1() { { shasum 2>/dev/null || sha1sum 2>/dev/null; } | cut -c1-16; }

# graded vs baseline: deterministic per session (stable, no RNG), ~BASELINE_PCT% baseline.
# If neither hash tool exists, bkt_hash is empty -> default to graded (never abort under set -u).
label="graded"
if [ -n "$session_id" ] && [ "${BASELINE_PCT:-0}" -gt 0 ] 2>/dev/null; then
  bkt_hash="$(printf '%s' "$session_id" | sha1 | cut -c1-8)"
  if [ -n "$bkt_hash" ]; then
    bkt=$(( 0x$bkt_hash % 100 ))
    [ "$bkt" -lt "$BASELINE_PCT" ] && label="baseline"
  fi
fi

# The baseline beacon needs the whole-session coding_tokens and has no verdict to
# report early, so it only makes sense at SessionEnd. On Stop, a baseline session has
# nothing to say (the skill was withheld) -> bail early.
[ "$label" = "baseline" ] && [ "$event" != "SessionEnd" ] && exit 0

marker_dir="${TMPDIR:-/tmp}/agentic-advisor"
mkdir -p "$marker_dir" 2>/dev/null || true
state="$marker_dir/${session_id:-default}.reported"
touch "$state" 2>/dev/null || true

# Cheap fast-exits for the graded path, BEFORE the git + jq repo-resolution work — so a
# per-turn Stop that has nothing new to report costs only a grep or two, not a full
# transcript parse. (The whole graded path requires the skill to have actually run.)
if [ "$label" = "graded" ]; then
  grep -qE '"skill"[[:space:]]*:[[:space:]]*"[^"]*agentic-advisor[^"]*"' "$transcript" 2>/dev/null || exit 0
  if [ "$event" = "Stop" ]; then
    # Has the set of verdict lines changed since we last processed a Stop? SKILL.md
    # example lines are constant, so this count only rises on a real new verdict (incl.
    # a phase-2 re-emit). Unchanged -> nothing to do -> skip the O(n) scrape + resolution.
    vcount="$(grep -cE 'LinearB: .+ (LOW|MEDIUM|HIGH) effort' "$transcript" 2>/dev/null)"; vcount="${vcount:-0}"
    vseen="$marker_dir/${session_id:-default}.vseen"
    [ -f "$vseen" ] && [ "$(cat "$vseen" 2>/dev/null)" = "$vcount" ] && exit 0
    printf '%s' "$vcount" > "$vseen" 2>/dev/null || true
  fi
fi

# Resolve repo dir. At SessionEnd there's no tool_input, so start from cwd (the usual
# repo root); if cwd isn't a repo (Claude launched from a parent dir), fall back to the
# dir of the last edited file in the transcript. user.email is git GLOBAL; remote is per-repo.
git_dir="${cwd:-.}"
if ! git -C "$git_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  led="$(jq -r 'select(.message.role?=="assistant") | .message.content? // [] | .[]? | select(.type?=="tool_use" and (.name=="Edit" or .name=="Write")) | .input.file_path // empty' "$transcript" 2>/dev/null | tail -1)"
  [ -n "$led" ] && git_dir="$(dirname "$led")"
fi
email="$(git -C "$git_dir" config user.email 2>/dev/null || true)"
case "$email" in *@*) identity_source="git" ;; *) email=""; identity_source="none" ;; esac
# Fallback: the signed-in Claude Code account, for machines with no git identity.
# ~/.claude.json is an undocumented file, so a missing/odd one is simply skipped.
if [ -z "$email" ]; then
  email="$(jq -r '.oauthAccount.emailAddress // empty' "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" 2>/dev/null || true)"
  case "$email" in *@*) identity_source="claude_account" ;; *) email="" ;; esac
fi

raw_remote="$(git -C "$git_dir" config --get remote.origin.url 2>/dev/null || true)"
repo_url=""
case "$raw_remote" in
  https://*|http://*) repo_url="$raw_remote" ;;
  git@*:*)            repo_url="https://$(printf '%s' "${raw_remote#git@}" | sed 's#:#/#')" ;;
  ssh://git@*)        repo_url="https://$(printf '%s' "${raw_remote#ssh://git@}")" ;;
esac
case "$repo_url" in
  ""|*.git) : ;;
  *)        repo_url="${repo_url%/}.git" ;;
esac

# Branch — join key to the PR later opened from it. Detached HEAD -> skip.
branch="$(git -C "$git_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ "$branch" = "HEAD" ] && branch=""

# Ticket — Jira key parsed from the branch (e.g. ABC-1234-foo -> ABC-1234).
ticket=""
[[ "$branch" =~ ([A-Z][A-Z0-9]+-[0-9]+) ]] && ticket="${BASH_REMATCH[1]}"

# Session name — human-facing title (custom preferred, else AI title).
session_name="$(jq -r 'select(.type? == "custom-title") | .customTitle // empty' "$transcript" 2>/dev/null | tail -1)"
[ -z "$session_name" ] && session_name="$(jq -r 'select(.type? == "ai-title") | .aiTitle // empty' "$transcript" 2>/dev/null | tail -1)"

# Model — which model the session ran (latest assistant turn); pairs with tokens for cost.
model="$(jq -r 'select(.message.role? == "assistant") | .message.model? // empty' "$transcript" 2>/dev/null | grep -vx '<synthetic>' | tail -1)"

# Plugin version — which plugin version produced this decision (from plugin.json).
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}"
plugin_version="$(jq -r '.version // empty' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null || true)"

ts="$(( $(date +%s) * 1000 ))"

post() { # $1 = payload json
  [ -n "$1" ] || return 0
  # Detach: Claude Code does not wait for SessionEnd hooks before exiting, so run
  # curl in a fully backgrounded subshell (reparented to init) — the POST completes
  # even after the hook returns and the session process is gone.
  ( curl -sS -m 5 -X POST "$REPORT_URL" \
      -H "x-api-key: $token" -H "Content-Type: application/json" \
      -d "$1" >/dev/null 2>&1 & ) 2>/dev/null || true
}

# Transcript parse -> token windows + flags, in one pass. Run lazily (only once we know
# we're about to emit) so the per-turn Stop hook stays cheap when there's nothing new.
#   grading_tokens  = output tokens between the Skill invocation and the verdict.
#   coding_tokens   = output tokens after the verdict (graded) or from the first edit (baseline).
#   has_edit        = did a real Edit|Write appear (baseline needs a real code session).
parsed=""
grading_tokens=""; coding_tokens=""; grading_duration=""; has_edit="false"
# Extract a numeric field from $parsed as a string ("" if absent/non-numeric).
# Top-level (not nested in parse_tokens) so it never depends on call order.
numstr() { jq -r --arg k "$1" 'if (.[$k]|type)=="number" then (.[$k]|tostring) else "" end' <<<"$parsed" 2>/dev/null || true; }
parse_tokens() {
  [ -z "$parsed" ] || return 0   # parse at most once
  parsed='{}'
  if command -v python3 >/dev/null 2>&1; then
    parsed="$(python3 - "$transcript" <<'PY' 2>/dev/null || echo '{}'
import sys, json, re, datetime
def ep(t): return datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
skill = verdict = first_edit = None
turns = []  # (ts_epoch, output_tokens) for assistant turns
for line in open(sys.argv[1]):
    try: r = json.loads(line)
    except Exception: continue
    m = r.get("message") or {}
    tstamp = r.get("timestamp"); content = m.get("content"); role = m.get("role")
    if not tstamp: continue
    try: te = ep(tstamp)
    except Exception: continue
    if role == "assistant":
        u = m.get("usage") or r.get("usage") or {}
        ot = u.get("output_tokens")
        if isinstance(ot, int): turns.append((te, ot))
    if not isinstance(content, list): continue
    for x in content:
        if not isinstance(x, dict): continue
        typ = x.get("type")
        if typ == "tool_use" and x.get("name") == "Skill" \
           and "agentic-advisor" in str((x.get("input") or {}).get("skill", "")):
            if skill is None: skill = te
        elif typ == "tool_use" and x.get("name") in ("Edit", "Write") and first_edit is None:
            first_edit = te
        # verdict must be ASSISTANT-authored text AFTER the Skill call — not the
        # SKILL.md examples that load on invocation (they also match the pattern).
        elif typ == "text" and role == "assistant" and skill is not None and verdict is None \
             and re.search(r"LinearB: .+ (LOW|MEDIUM|HIGH) effort", x.get("text") or ""):
            verdict = te
out = {"grading_tokens": "", "coding_tokens": "", "grading_duration_s": "",
       "has_edit": first_edit is not None}
if skill is not None and verdict is not None and verdict >= skill:
    out["grading_tokens"] = sum(o for (te, o) in turns if skill <= te <= verdict)
    out["grading_duration_s"] = round(verdict - skill, 1)
if verdict is not None:
    out["coding_tokens"] = sum(o for (te, o) in turns if te > verdict)
elif first_edit is not None:
    out["coding_tokens"] = sum(o for (te, o) in turns if te >= first_edit)
print(json.dumps(out))
PY
)"
  fi
  [ -n "$parsed" ] || parsed='{}'
  grading_tokens="$(numstr grading_tokens)"
  coding_tokens="$(numstr coding_tokens)"
  grading_duration="$(numstr grading_duration_s)"
  has_edit="$(jq -r '.has_edit // false' <<<"$parsed" 2>/dev/null || echo false)"
}

# ---- baseline path (SessionEnd only): coding_tokens beacon, no grade ----
if [ "$label" = "baseline" ]; then
  parse_tokens
  [ "$has_edit" = "true" ] || exit 0        # only real code sessions
  [ -n "$repo_url" ] || exit 0
  key="$(printf 'baseline|%s' "$repo_url" | sha1)"
  [ -n "$key" ] && grep -q "$key" "$state" 2>/dev/null && exit 0
  repo="$(basename "$repo_url" .git 2>/dev/null || true)"
  # Contamination check: in a baseline session the trigger stays silent, so the skill
  # should never run. If it ran anyway (grep finds a real Skill invocation), flag it —
  # a contaminated baseline must be excluded from the control arm.
  contaminated="false"
  grep -qE '"skill"[[:space:]]*:[[:space:]]*"[^"]*agentic-advisor[^"]*"' "$transcript" 2>/dev/null && contaminated="true"
  payload="$(jq -n \
    --arg m "$METRIC_NAME" --arg src "$SOURCE" --argjson ts "$ts" \
    --arg repo "$repo" --arg email "$email" --arg repourl "$repo_url" --arg branch "$branch" \
    --arg ticket "$ticket" --arg sname "$session_name" --arg model "$model" \
    --arg ctok "$coding_tokens" --arg contam "$contaminated" --arg pver "$plugin_version" --arg idsrc "$identity_source" '
    {
      metric_name: $m, source: $src, timestamp: $ts, value: 0,
      entity: (
        (if $email   != "" then {contributor_email: $email} else {} end) +
        (if $repourl != "" then {repo_url: $repourl}         else {} end)
      ),
      tags: (
        {label: "baseline", identity_source: $idsrc} +
        (if $repo   != "" then {repo: $repo}                 else {} end) +
        (if $branch != "" then {branch: $branch}             else {} end) +
        (if $ticket != "" then {ticket: $ticket}             else {} end) +
        (if $sname  != "" then {session_name: $sname}        else {} end) +
        (if $model  != "" then {model: $model}               else {} end) +
        (if $ctok   != "" then {coding_tokens: $ctok}        else {} end) +
        (if $pver   != "" then {plugin_version: $pver}       else {} end) +
        (if $contam == "true" then {contaminated: "true"}    else {} end)
      )
    }' 2>/dev/null)"
  post "$payload"
  printf '%s\n' "$key" >> "$state" 2>/dev/null || true
  exit 0
fi

# ---- graded path ----
# (GATE 1 — skill actually ran — was already checked in the cheap fast-exit block above.)
# Don't lock in a repo-less event (needs repo_url to join to the PR).
[ -n "$repo_url" ] || exit 0

# GATE 2 — a real assistant-authored verdict line exists (grep, not python, so the
# decision can still be reported when python3 is unavailable).
verdicts="$(jq -r 'select(.message.role? == "assistant") | .message.content? // [] | .[]? | select(.type? == "text") | .text? // empty' "$transcript" 2>/dev/null \
  | grep -E 'LinearB: .+ (LOW|MEDIUM|HIGH) effort' || true)"
[ -n "$verdicts" ] || exit 0

re='LinearB: (.+) (LOW|MEDIUM|HIGH) effort'
er='\(([^\)]*)\)'

# Parse a verdict line into repo/effort/evidence globals.
parse_verdict() { # $1 = line
  vrepo=""; veffort=""; vev=""
  [[ "$1" =~ $re ]] || return 1
  vrepo="${BASH_REMATCH[1]}"; veffort="${BASH_REMATCH[2]}"
  vrepo="${vrepo%% —}"; vrepo="${vrepo%%—}"; vrepo="${vrepo%"${vrepo##*[![:space:]]}"}"
  [[ "$1" =~ $er ]] && vev="${BASH_REMATCH[1]}"
  return 0
}
effort_val() { case "$1" in LOW) echo 1 ;; MEDIUM) echo 2 ;; HIGH) echo 3 ;; *) echo 0 ;; esac; }

if [ "$event" = "Stop" ]; then
  # DECISION event(s): report the grade the moment it exists — reliable, per turn,
  # once per (repo|effort). No coding_tokens (not complete until the session ends).
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    parse_verdict "$line" || continue
    key="$(printf 'decision|%s|%s' "$vrepo" "$veffort" | sha1)"
    [ -n "$key" ] && grep -q "$key" "$state" 2>/dev/null && continue
    parse_tokens   # only now (something new to report) — keeps quiet turns cheap
    val="$(effort_val "$veffort")"
    payload="$(jq -n \
      --arg m "$METRIC_NAME" --arg src "$SOURCE" --argjson ts "$ts" --argjson val "$val" \
      --arg effort "$veffort" --arg repo "$vrepo" --arg ev "$vev" \
      --arg email "$email" --arg repourl "$repo_url" --arg branch "$branch" \
      --arg actual "$effort_actual" --arg ticket "$ticket" --arg sname "$session_name" \
      --arg gdur "$grading_duration" --arg model "$model" --arg gtok "$grading_tokens" --arg pver "$plugin_version" --arg idsrc "$identity_source" '
      {
        metric_name: $m, source: $src, timestamp: $ts, value: $val,
        entity: (
          (if $email   != "" then {contributor_email: $email} else {} end) +
          (if $repourl != "" then {repo_url: $repourl}         else {} end)
        ),
        tags: (
          {effort_level: $effort, repo: $repo, label: "graded", phase: "decision", identity_source: $idsrc} +
          (if $ev     != "" then {evidence: $ev}                else {} end) +
          (if $branch != "" then {branch: $branch}              else {} end) +
          (if $actual != "" then {actual_effort: $actual}       else {} end) +
          (if $ticket != "" then {ticket: $ticket}              else {} end) +
          (if $sname  != "" then {session_name: $sname}         else {} end) +
          (if $gdur   != "" then {grading_duration_s: $gdur}    else {} end) +
          (if $model  != "" then {model: $model}                else {} end) +
          (if $gtok   != "" then {grading_tokens: $gtok}        else {} end) +
          (if $pver   != "" then {plugin_version: $pver}        else {} end)
        )
      }' 2>/dev/null)"
    [ -n "$payload" ] || continue
    post "$payload"
    printf '%s\n' "$key" >> "$state" 2>/dev/null || true
  done <<< "$verdicts"
  exit 0
fi

# event == SessionEnd, graded: TOKENS event — the whole-session coding_tokens, attributed
# to the final (last) verdict. value 0 so it doesn't double-count on grade charts; the
# effort_level tag is kept for stratified coding_tokens comparison.
last_verdict="$(printf '%s\n' "$verdicts" | grep -E 'LinearB: .+ (LOW|MEDIUM|HIGH) effort' | tail -1)"
[ -n "$last_verdict" ] || exit 0
parse_verdict "$last_verdict" || exit 0
key="$(printf 'tokens|%s|%s' "$vrepo" "$veffort" | sha1)"
[ -n "$key" ] && grep -q "$key" "$state" 2>/dev/null && exit 0
parse_tokens
[ -n "$coding_tokens" ] || exit 0   # nothing to add without the measurement
payload="$(jq -n \
  --arg m "$METRIC_NAME" --arg src "$SOURCE" --argjson ts "$ts" \
  --arg effort "$veffort" --arg repo "$vrepo" \
  --arg email "$email" --arg repourl "$repo_url" --arg branch "$branch" \
  --arg ticket "$ticket" --arg sname "$session_name" --arg model "$model" \
  --arg ctok "$coding_tokens" --arg pver "$plugin_version" --arg idsrc "$identity_source" '
  {
    metric_name: $m, source: $src, timestamp: $ts, value: 0,
    entity: (
      (if $email   != "" then {contributor_email: $email} else {} end) +
      (if $repourl != "" then {repo_url: $repourl}         else {} end)
    ),
    tags: (
      {effort_level: $effort, repo: $repo, label: "graded", phase: "tokens", identity_source: $idsrc} +
      (if $branch != "" then {branch: $branch}      else {} end) +
      (if $ticket != "" then {ticket: $ticket}      else {} end) +
      (if $sname  != "" then {session_name: $sname} else {} end) +
      (if $model  != "" then {model: $model}        else {} end) +
      (if $ctok   != "" then {coding_tokens: $ctok} else {} end) +
      (if $pver   != "" then {plugin_version: $pver} else {} end)
    )
  }' 2>/dev/null)"
[ -n "$payload" ] || exit 0
post "$payload"
printf '%s\n' "$key" >> "$state" 2>/dev/null || true
exit 0
