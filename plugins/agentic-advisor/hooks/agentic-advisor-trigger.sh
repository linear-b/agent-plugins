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
#                model keeps it in thinking): remind it once, without blocking, to print it.
#     BACKSTOP - a code edit or subagent spawn is starting and this repo wasn't graded yet this
#                session. Catches tasks that slipped past the prompt gate.
#
#   PostToolUse (matcher Bash)
#     SHOW     - a `printf` verdict (or stage 2) line ran: echo it as a systemMessage so the user sees it
#                even when the Bash call is collapsed.
#
# This NEVER does LinearB work itself and NEVER blocks. It only injects an
# additionalContext nudge and always exits 0 (exit 2 on UserPromptSubmit would
# erase the user's prompt).

set -uo pipefail

# Troubleshooting log (on by default, LINEARB_DEBUG=0 turns it off). A missing log.sh only loses the log.
# shellcheck disable=SC1091  # log.sh sits next to this script
. "$(dirname "${BASH_SOURCE[0]:-$0}")/log.sh" 2>/dev/null || dbg() { :; }

# Per-user off switch: LINEARB_AGENTIC_ADVISOR_ENABLED=false (or 0/off/no) stops the auto-trigger, so no nudge and no hold.
case "$(printf '%s' "${LINEARB_AGENTIC_ADVISOR_ENABLED:-1}" | tr '[:upper:]' '[:lower:]')" in 0|false|off|no) exit 0 ;; esac

# jq parses the hook payload; without it, no-op.
command -v jq >/dev/null 2>&1 || { dbg "trigger: skip: jq not found, the skill is never nudged"; exit 0; }

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
read_ran() { # the agent read the skill's SKILL.md (the fallback when the Skill tool lists no skill)
  [ -n "$(jq -r --arg re '/skills/[^/]*agentic-advisor[^/]*/SKILL\.md$' 'select(.message.role? == "assistant") | .message.content? // [] | .[]?
      | select(.type? == "tool_use" and .name? == "Read" and ((.input.file_path? // "") | tostring | test($re))) | "y"' \
      "$transcript" 2>/dev/null | head -n 1)" ]
}
skill_ran() {
  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  grep -qE '"skill"[[:space:]]*:[[:space:]]*"[^"]*agentic-advisor[^"]*"' "$transcript" 2>/dev/null \
    || read_ran
}

# Is the LATEST advisor Skill call still missing its verdict (assistant text, or the
# hold's `printf` Bash call)? Prints "pending" or "ok"; prints nothing on parse failure.
VERDICT_RE='LinearB: .+ (((Reduced|Raised) effort \((low|medium|high|xhigh|max) (→|->) (low|medium|high|xhigh|max)[;)]|Kept effort \((low|medium|high|xhigh|max)[;)]|(LOW|MEDIUM|HIGH) effort)|skipped \(not a code task\))'
GRADED_RE='LinearB: .+ ((Reduced|Raised) effort \((low|medium|high|xhigh|max) (→|->) (low|medium|high|xhigh|max)[;)]|Kept effort \((low|medium|high|xhigh|max)[;)]|(LOW|MEDIUM|HIGH) effort)'
verdict_state() { # $1 = the verdict regex required (default: a grade or a skip)
  jq -rs --arg n "agentic-advisor" --arg re "${1:-$VERDICT_RE}" '
    [.[] | select(.message.role? == "assistant") | .message.content? // [] | .[]?] as $c
    | [$c | to_entries[] | select(.value.type? == "tool_use" and .value.name? == "Skill"
        and ((.value.input.skill? // "") | tostring | contains($n))) | .key] as $calls
    | [$c | to_entries[] | select(.value.type? == "tool_use" and .value.name? == "Read"
        and ((.value.input.file_path? // "") | tostring | test("/skills/[^/]*" + $n + "[^/]*/SKILL\\.md$"))) | .key] as $reads
    | (if ($calls | length) > 0 then $calls else $reads[0:1] end) as $sk
    | if ($sk | length) == 0 then "ok"
      elif ($c[($sk[-1] + 1):] | any(
          (.type? == "text" and ((.text? // "") | test($re)))
          or (.type? == "tool_use" and .name? == "Bash"
              and ((.input.command? // "") | test("(^|\\n|;|&&)\\s*printf\\s[^\\n]*" + $re)))))
      then "ok" else "pending" end' "$transcript" 2>/dev/null
}

# One pass over the assistant's lines (text, and `printf` Bash calls) for the latest verdict naming this repo
# ($1 = its names, one per line; none = any repo). Prints pending|skipped|graded, or stage2 when that verdict
# is medium+ with no target file, followed by the "LinearB phase 2 —" lines printed after it. Nothing on parse failure.
repo_state() {
  jq -rs --arg any "$VERDICT_RE" --arg re "$GRADED_RE" --arg names "${1:-}" '
    [.[] | select(.message.role? == "assistant") | .message.content? // [] | .[]?
      | if .type? == "text" then (.text? // "") | split("\n")[]
        elif (.type? == "tool_use" and .name? == "Bash") then (.input.command? // "") | split("\n")[]
          | select(test("(^|;|&&)\\s*printf\\s")) else empty end] as $t
    | [$names | split("\n")[] | select(length > 0)] as $ns
    | [$t | to_entries[] | select((.value | test($any)) and (.value as $l | ($ns | length) == 0 or any($ns[];
        . as $n | $l | contains("LinearB: " + $n + " ") or (test("LinearB: [^ ]+/") and contains("/" + $n + " ")))))] as $v
    | if ($v | length) == 0 then "pending"
      else $v[-1] as $l
        | if ($l.value | test($re) | not) then "skipped"
          elif ($l.value | test("target ")) or ($l.value | test("(→|->) low[;)]|Kept effort \\(low[;)]")) then "graded"
          else "stage2", ($t[($l.key + 1):][] | select(test("LinearB phase 2 — ")))
          end
      end' "$transcript" 2>/dev/null
}

# Does a phase-2 line ($1) name the edited file, this repo, or a file in it? Uses $file_path, $names and $root.
p2_here() {
  local toks t n
  t="${1#*LinearB phase 2 — }"
  read -ra toks <<<"$(printf '%s' "${t%%: *}" | tr ',+&`' '    ')"
  for t in ${toks[@]+"${toks[@]}"}; do
    [ "$t" = "$(basename "$file_path")" ] || [ -e "$root/$t" ] && return 0
    while IFS= read -r n; do [ -n "$n" ] && case "$t" in "$n"|"$n"/*) return 0 ;; esac; done <<<"$names"
    [ -n "$(git -C "$root" ls-files -- ":(glob)**/$t" 2>/dev/null | head -n 1)" ] && return 0
  done
  return 1
}

note() { # $1 = context for the model; the tool call still runs (no red error in the UI)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' "$(printf '%s' "$1" | jq -Rs .)"
  exit 0
}

deny() { # $1 = reason fed back to the model
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | jq -Rs .)"
  exit 0
}

# Per-user state dir (not shared /tmp): another local user can't plant or read markers.
[ -n "${XDG_CACHE_HOME:-}${HOME:-}" ] || exit 0   # no cache root -> nothing to remember, fail open
marker_dir="${XDG_CACHE_HOME:-${HOME:-}/.cache}/agentic-advisor"
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
skill_file="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/skills/agentic-advisor/SKILL.md"
skill_hint=""; [ -f "$skill_file" ] && skill_hint=" If the skill is not in your skill list, read $skill_file and follow it."
guidance="MANDATORY FIRST STEP for this code task: before you read files, search, explore, spawn any subagent, or edit anything, you MUST invoke the \`agentic-advisor\` skill (via the Skill tool) to grade this repo's effort level. Do not start the task, do not touch code, until you have run it and printed its verdict line verbatim in this shape: > LinearB: <repo> — <Raised|Reduced> effort (<current> → <new level>; <evidence>) — <plan>, or > LinearB: <repo> — Kept effort (<current>; <evidence>) — <plan> (a hook parses that line; a prose summary is not recorded). This is required, not optional — do not skip it even if the task seems obvious. Invoke it directly (no need to ask the user or announce it). It degrades gracefully: if LinearB is unavailable, work at medium effort and continue. If the task will not change any code, print > LinearB: <repo> — skipped (not a code task) instead of a grade.$skill_hint"

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
    if [ "$bkt" -lt "$BASELINE_PCT" ]; then   # baseline: silent, no nudge
      [ "$event" = "UserPromptSubmit" ] && dbg "UserPromptSubmit: skip: baseline (holdout) session, no nudge"
      exit 0
    fi
  fi
fi

case "$event" in
  PostToolUse)
    cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null || true)"
    case "$cmd" in *printf*"LinearB"*) ;; *) exit 0 ;; esac
    # Read the printed line, not the shell source, so quoting (e.g. an apostrophe) can't cut it short.
    out="$(jq -r '.tool_response.stdout // empty' <<<"$input" 2>/dev/null || true)"
    line="$(printf '%s\n' "$out" | grep -m 1 -E "^> (${GRADED_RE}|LinearB phase 2 — .+)" || true)"
    [ -n "$line" ] || exit 0
    jq -cn --arg m "$line" '{systemMessage: $m}'
    dbg "PostToolUse: showed the verdict line to the user"
    ;;

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
    elif printf '%s' "$prompt" | sed -E 's/[Aa][Uu][Tt][Oo][- ]?[Ff][Ii][Xx]//g' | grep -qiE '\b(fix|fixes|fixing|fixed|implement|implementing|refactor|refactoring|hotfix|bug ?fix|debug|patch|endpoint|migration)\b'; then
      # Tier 2: code-task keywords (fallback for ad-hoc work).
      msg="This looks like a code-writing task. ${guidance}"
    fi
    [ -z "$msg" ] && exit 0

    set_marker "${cwd:-.}"
    [ -f "$marker" ] && exit 0
    emit "UserPromptSubmit" "$msg"
    why="code-task keywords"; [ -n "$ticket" ] && why="ticket key"   # the key itself came from the prompt
    dbg "UserPromptSubmit: nudged the agent to run the skill ($why)"
    ;;

  PreToolUse)
    tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null || true)"
    # Verdict reminder: once per advisor run, if a read comes before that run's verdict line, attach a
    # note asking for it (the call still runs). Edits and spawns skip it: the hold below blocks them
    # until the line exists. Keyed by the run count so a second repo's run is checked too.
    case "$tool" in Read|Grep|Glob) is_read=1 ;; *) is_read=0 ;; esac
    if [ "$is_read" = 1 ] && skill_ran; then
      # Count only assistant Skill calls (same thing verdict_state indexes), not echoes elsewhere.
      runs="$(grep '"role":"assistant"' "$transcript" 2>/dev/null | grep -cE '"skill"[[:space:]]*:[[:space:]]*"[^"]*'"agentic-advisor"'[^"]*"|"name"[[:space:]]*:[[:space:]]*"Read".*/skills/[^"/]*'"agentic-advisor"'[^"/]*/SKILL\.md"')"
      vdone="$marker_dir/${session_id:-default}.${runs:-0}.vdone"
      if [ ! -f "$vdone" ]; then
        state="$(verdict_state)"
        if [ -n "$state" ] && : > "$vdone" 2>/dev/null && [ "$state" = "pending" ]; then
          dbg "PreToolUse: reminded the agent to print the verdict line"
          note "LinearB: your effort grade isn't recorded yet. It's only recorded from the verdict line, not from thinking, so print it now (a prose summary doesn't count): > LinearB: <repo> — <Raised|Reduced> effort (<current> → <new level>; <evidence>) — <plan>, or > LinearB: <repo> — Kept effort (<current>; <evidence>) — <plan>. If you aren't writing text, run: printf '%s\\n' '> LinearB: <repo> — <that verdict>'. If no code will change, print > LinearB: <repo> — skipped (not a code task) instead."
        fi
      fi
    fi
    case "$tool" in
      Read|Grep|Glob) exit 0 ;;
      Task|Agent)
        # Delegated work can write code too, so grade before the first spawn. Read-only agent types can't edit.
        case "$(jq -r '.tool_input.subagent_type // empty' <<<"$input" 2>/dev/null)" in
          Explore|Plan|claude-code-guide|statusline-setup) exit 0 ;;
        esac
        what="spawning a subagent"
        dir="${cwd:-.}"
        ;;
      *)
        what="this edit"
        file_path="$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null || true)"
        [ -z "$file_path" ] && exit 0
        dir="$(dirname "$file_path")"
        # A Write can target a folder that doesn't exist yet: check the nearest existing parent.
        while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do dir="$(dirname "$dir")"; done
        ext="$(printf '%s' "${file_path##*.}" | tr '[:upper:]' '[:lower:]')"
        case "$ext" in
          md|markdown|mdx|txt|rst|adoc|log) exit 0 ;;   # docs/text edits are never held
        esac
        ;;
    esac

    # GRADE-before-work HOLD: a source edit or subagent spawn in a repo with no verdict line this session
    # is denied (permissionDecision:deny) until one exists, at most 3 times per repo/session (its own .held
    # counter, not the nudge's .done marker), so prose or a file switch can't skip the grade and a broken
    # setup never walls. Scoped to a git repo; fails OPEN on any uncertainty.
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

    # Graded only by a verdict or "skipped (not a code task)" line naming THIS repo (the remote's or the folder's
    # name: clones and worktrees can differ), so one repo's run can't hold or release another.
    # "pending" only when parsed and no grade yet; a parse failure prints nothing and fails open.
    root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
    url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null)"; url="${url%.git}"
    names="$(printf '%s\n' "${url##*[/:]}" "${root:+$(basename "$root")}" | grep -v '^$')"
    gate="pending"
    if skill_ran; then
      rs="$(repo_state "$names")"; gate="${rs%%$'\n'*}"
      # No name to match: the latest skill run must also be graded, as before.
      [ -n "$names" ] || [ "$(verdict_state "$GRADED_RE")" != "pending" ] || gate="pending"
    fi
    if [ "$gate" != "pending" ]; then
      set_marker "$dir"
      # A grade naming this repo marks it handled so later prompts here aren't nudged.
      case "$gate" in graded|stage2) [ -n "$names" ] && { : > "$marker" 2>/dev/null || true; } ;; esac
      # Stage 2 counts only a phase-2 line printed after this repo's verdict that names its file(s).
      if [ "$gate" = "stage2" ] && [ "$what" = "this edit" ]; then
        while IFS= read -r p2; do [ -n "$p2" ] && p2_here "$p2" && { gate="graded"; break; }; done <<<"$(printf '%s\n' "$rs" | tail -n +2)"
      fi
      # Stage 2: on a medium+ grade, edits wait for the file-level line, held at most twice per repo/session (never a wall).
      s2="${marker%.done}.s2"; k="$(cat "$s2" 2>/dev/null)"; case "$k" in ''|*[!0-9]*) k=0 ;; esac
      if [ "$what" = "this edit" ] && [ "$k" -lt 2 ] && [ "$gate" = "stage2" ] && printf '%s' "$((k + 1))" > "$s2" 2>/dev/null; then
        dbg "PreToolUse: held $tool for the stage 2 (change-area) line"
        deny "Stage 2 first: before editing $(basename "$file_path"), run the change-area probe on the file(s) you'll change and print the result with one Bash call: printf '%s\\n' '> LinearB phase 2 — <file>: ~N lines rewritten/90d over M commits — <concentrate guards + tests here | clean, standard care>'. If it changes the effort, print the full verdict line again instead. Then make the same call again."
      fi
      exit 0
    fi
    # Can't read the transcript -> can't confirm skill status -> fail open (allow).
    [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

    # Dedicated hold marker, distinct from the nudge (.done) marker so a prior
    # UserPromptSubmit nudge can't satisfy this check and bypass the hold.
    set_marker "$dir"
    held="${marker%.done}.held"
    n="$(cat "$held" 2>/dev/null)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge 3 ] && exit 0   # held 3 times this repo/session -> allow (never wall)

    # Source edit or spawn here + no verdict line yet -> HOLD it via permissionDecision:deny (shows
    # just the reason and feeds it to the model). FAIL OPEN if we can't record the count (don't wedge).
    printf '%s' "$((n + 1))" > "$held" 2>/dev/null || exit 0
    dbg "PreToolUse: held $tool until a verdict line exists (hold $((n + 1)))"
    if skill_ran; then
      reason="Your effort grade isn't recorded yet (thinking and prose summaries don't count). Run this Bash call now with your grade filled in, then make the same call again: printf '%s\\n' '> LinearB: <repo> — <Raised|Reduced> effort (<current> → <new level>; <evidence>) — <plan>' (or '> LinearB: <repo> — Kept effort (<current>; <evidence>) — <plan>')."
    else
      reason="One quick first step before ${what}: run the \`agentic-advisor\` skill to grade this repo's effort.$skill_hint Print its verdict line (> LinearB: <repo> — <Raised|Reduced> effort (<current> → <new level>; <evidence>) — <plan>, or > LinearB: <repo> — Kept effort (<current>; <evidence>) — <plan>), then make the same call again; this hold repeats until it's printed. If LinearB isn't available it just works at medium effort."
    fi
    [ "$what" = "this edit" ] || reason="$reason Tell the subagent the effort level in its prompt, so the delegated work follows it."
    deny "$reason"
    ;;
esac

exit 0
