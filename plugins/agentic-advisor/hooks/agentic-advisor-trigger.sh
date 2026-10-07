#!/usr/bin/env bash
# Trigger the `agentic-advisor` skill at the start of a repo-scoped code
# task, so the agent loads the repo's LinearB health signals before writing code.
#
# One script, two gates. Fires AT MOST ONCE per (session, repo root) — so a
# second repo in the same session is still evaluated, and repeat edits to the
# same repo don't re-nudge. The skill itself caches the effort verdict per repo.
#
#   UserPromptSubmit
#     1. PRIMARY  - a Jira ticket reference in the prompt (e.g. ABC-1234).
#                   High precision: a ticket almost always means "starting work".
#     2. FALLBACK - code-task keywords, for ad-hoc fixes with no ticket.
#
#   PreToolUse (matcher Edit|Write|Read|Grep|Glob|Task|Agent)
#     VERDICT  - the skill ran but no verdict line was printed yet (at low effort the
#                model keeps it in thinking): hold the next tool once so it prints it.
#     BACKSTOP - a code edit is starting and this repo wasn't nudged yet this
#                session. Catches tasks that slipped past the prompt gate.
#
# This NEVER does LinearB work itself and NEVER blocks. It only injects an
# additionalContext nudge and always exits 0 (exit 2 on UserPromptSubmit would
# erase the user's prompt).

set -uo pipefail

# jq parses the hook payload; without it, no-op silently.
command -v jq >/dev/null 2>&1 || exit 0

# sha1 helper — shasum is macOS-only; sha1sum is the GNU/Linux name. Portable across both.
sha1() { if command -v shasum >/dev/null 2>&1; then shasum; elif command -v sha1sum >/dev/null 2>&1; then sha1sum; fi | cut -c1-16; }

input="$(cat)"
event="$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null || true)"
session_id="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null || true)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null || true)"

# Has the agentic-advisor skill ACTUALLY run in this session? (a real Skill
# tool_use in the transcript, not just text that quotes it). Used to hard-gate
# the first source edit so the effort grade is computed BEFORE code is written.
skill_ran() {
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  grep -qE '"skill"[[:space:]]*:[[:space:]]*"[^"]*agentic-advisor[^"]*"' "$transcript" 2>/dev/null
}

# Has an assistant message printed the verdict line the reporter parses?
verdict_printed() {
  grep -qE '"role":"assistant".*LinearB: [^"]* (LOW|MEDIUM|HIGH) effort' "$transcript" 2>/dev/null
}

deny() { # $1 = reason fed back to the model
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | jq -Rs .)"
  exit 0
}

# Per-user state dir (not shared /tmp): another local user can't plant or read markers.
marker_dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentic-advisor"
(umask 077; mkdir -p "$marker_dir") 2>/dev/null || true
[ -O "$marker_dir" ] || exit 0   # not ours / not creatable -> fail open

# Stable per-repo key from a directory's git root (falls back to a session-only
# key outside a git repo). Sets the global `marker` used by emit().
set_marker() { # $1 = a directory inside the repo
  local root key
  root="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$root" ]; then
    key="$(printf '%s' "$root" | sha1 | cut -c1-12)"
  fi
  marker="$marker_dir/${session_id:-default}__${key:-norepo}.done"
}

# Imperative, silent guidance — no permission question, no announcement.
guidance="MANDATORY FIRST STEP for this code task: before you read files, search, explore, spawn any subagent, or edit anything, you MUST invoke the \`agentic-advisor\` skill (via the Skill tool) to grade this repo's effort level. Do not start the task, do not touch code, until you have run it and printed its verdict line verbatim in this shape: > LinearB: <repo> — <LOW|MEDIUM|HIGH> effort (<evidence>) — <plan> (a hook parses that line; a prose summary is not recorded). This is required, not optional — do not skip it even if the task seems obvious. Invoke it directly (no need to ask the user or announce it). It degrades gracefully: if LinearB is unavailable, default to MEDIUM effort and continue."

# Mark handled (this session+repo) and emit additionalContext for the event.
emit() { # $1 = hookEventName, $2 = context text
  : > "$marker" 2>/dev/null || true
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' \
    "$1" "$(printf '%s' "$2" | jq -Rs .)"
}

# Measurement holdout (OFF by default): a deterministic ~LINEARB_BASELINE_HOLDOUT_PCT% of sessions are "baseline"
# and get NO nudge at all (no prompt nudge, no grade-before-edit hold) so the agent
# behaves as an untreated control. The reporter emits a baseline beacon for them.
# Stable per session (session-id hash, no RNG); default 0 = holdout off (set e.g. 20 to run it).
BASELINE_PCT="${LINEARB_BASELINE_HOLDOUT_PCT:-0}"
if [ -n "$session_id" ] && [ "${BASELINE_PCT:-0}" -gt 0 ] 2>/dev/null; then
  bkt_hash="$(printf '%s' "$session_id" | sha1 | cut -c1-8)"
  if [ -n "$bkt_hash" ]; then
    bkt=$(( 0x$bkt_hash % 100 ))
    [ "$bkt" -lt "$BASELINE_PCT" ] && exit 0   # baseline: silent, no nudge
  fi
fi

case "$event" in
  UserPromptSubmit)
    prompt="$(jq -r '.prompt // .user_input // empty' <<<"$input" 2>/dev/null || true)"
    [ -z "$prompt" ] && exit 0

    # Decide whether this prompt looks like a code task, and build the nudge.
    msg=""
    ticket=""
    if [[ "$prompt" =~ ([A-Z][A-Z0-9]+-[0-9]+) ]]; then
      ticket="${BASH_REMATCH[1]}"
    fi
    if [ -n "$ticket" ]; then
      # Tier 1: Jira ticket (primary).
      msg="This looks like the start of a repo-scoped code task (Jira ticket ${ticket} referenced). ${guidance}"
    elif printf '%s' "$prompt" | grep -qiE '\b(fix|fixes|fixing|fixed|implement|implementing|refactor|refactoring|hotfix|bug ?fix|debug|patch|endpoint|migration)\b'; then
      # Tier 2: code-task keywords (fallback for ad-hoc work).
      msg="This looks like a code-writing task. ${guidance}"
    fi
    [ -z "$msg" ] && exit 0

    set_marker "${cwd:-.}"
    [ -f "$marker" ] && exit 0
    emit "UserPromptSubmit" "$msg"
    ;;

  PreToolUse)
    # Verdict gate: once per session, hold the first non-shell tool after the skill ran
    # until the verdict line is visible (telemetry and the user both need it).
    if skill_ran && ! verdict_printed; then
      vheld="$marker_dir/${session_id:-default}.vheld"
      [ ! -f "$vheld" ] && : > "$vheld" 2>/dev/null && deny "Before continuing, record the effort verdict with one Bash call, exactly: printf '%s\\n' '> LinearB: <repo> — <LOW|MEDIUM|HIGH> effort (<evidence>) — <plan>' (a hook records that line; thinking alone is not recorded). Then retry this same call."
    fi
    tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null || true)"
    case "$tool" in Read|Grep|Glob|Task|Agent) exit 0 ;; esac

    # Edit|Write only from here. ONE-TIME grade-before-edit
    # HOLD: the FIRST source edit in a repo this session is denied (permissionDecision:deny) so the
    # skill grades before code is written. Held at most ONCE per repo/session (via
    # its own dedicated .held marker — NOT the UserPromptSubmit nudge (.done) marker,
    # so a prior prompt-nudge can't satisfy the check and bypass the hold); after
    # that one hold, edits proceed even if the skill still hasn't run (we don't wall).
    # Scoped to real source edits in a git repo; fails OPEN on any uncertainty
    # (missing file path, non-git, missing transcript, or marker write failure).
    file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null || true)"
    [ -z "$file_path" ] && exit 0
    dir="$(dirname "$file_path")"
    # A Write can target a folder that doesn't exist yet: check the nearest existing parent.
    while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do dir="$(dirname "$dir")"; done

    # Only gate real source edits inside a git repo (skip docs/text, skip non-git).
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    ext="$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
      md|markdown|mdx|txt|rst|adoc|log) exit 0 ;;
    esac

    # Skill already ran this session -> allow the edit.
    skill_ran && exit 0
    # Can't read the transcript -> can't confirm skill status -> fail open (allow).
    [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

    # Dedicated hold marker, distinct from the nudge (.done) marker so a prior
    # UserPromptSubmit nudge can't satisfy this check and bypass the hold.
    set_marker "$dir"
    held="${marker%.done}.held"
    [ -f "$held" ] && exit 0   # already held once this repo/session -> allow

    # First source edit here + skill hasn't run -> HOLD it once, via a structured
    # permissionDecision:deny. Same one-time block as before, but a much cleaner UI
    # than `exit 2`: it shows just the reason (no "PreToolUse hook error: [path]"
    # prefix) and feeds that reason to the model. FAIL OPEN if we can't record the
    # marker (don't wedge).
    : > "$held" 2>/dev/null || exit 0
    reason="One quick first step before this edit: run the \`agentic-advisor\` skill to grade this repo's effort (just this once per repo, this session). Print its verdict line (> LinearB: <repo> — <LOW|MEDIUM|HIGH> effort (…) — …), then make the same edit again — it'll go right through, and later edits won't pause. If LinearB isn't available it just defaults to MEDIUM."
    deny "$reason"
    ;;
esac

exit 0
