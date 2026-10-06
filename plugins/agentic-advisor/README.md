# agentic-advisor

Sizes the agent's coding **effort** to how fragile the target is — before it writes code.

At the start of a code task, a bundled hook auto-invokes the `agentic-advisor` skill. It reads the repo's current health (LinearB rework %, unreviewed merges, recent incidents) plus local git history on the files being touched, then grades **LOW / MEDIUM / HIGH effort** and holds the agent to it: lean and token-efficient on calm repos, defensive (smallest change, guards, tests, clarifying questions) on fragile ones. It never blocks; if LinearB data is unavailable it defaults to MEDIUM.

## Install

```
/plugin marketplace add linear-b/agent-plugins
/plugin install agentic-advisor@linearb-ai
```

Then export `LINEARB_API_TOKEN` (see [Setup](#usage-telemetry-on-by-default)) and restart Claude Code — hooks load at startup.

## What you'll see

The agent prints a one-line verdict before writing code, e.g.:

> LinearB: api-service — LOW effort (healthy: rework 0.4%, 0 unreviewed merges, no incidents).

> LinearB: payments-service — HIGH effort (rework 9.5% NEEDS FOCUS; target PaymentForm.tsx: 3 fix/revert commits/90d) — smallest viable change, defensive validation, focused test.

## How it decides

- **Effort bands** match LinearB's own rework benchmark: ELITE <3% / STRONG 3–6% → **LOW**; FAIR 6–7% → **MEDIUM**; NEEDS FOCUS >7% → **HIGH**. Effort = the highest-firing signal (rework, unreviewed merges, or a recent serious incident).
- **Phase 2 (file-grained):** on non-trivial changes to a fragile/sensitive area, it also checks local git history on the exact files — how much existing code was rewritten over the last 90 days (the main signal) and who owns it — to target where to concentrate care. Commit messages saying "fix"/"revert" count only as a weak hint.
- **Stays lean:** trivial edits (comments, docs, formatting, pure renames) skip everything and cap at LOW; the repo-health part of the verdict is cached per repo for 24 hours; the task and file checks are never cached and are redone whenever the skill runs.

## Triggers

Auto-fires (once per repo, per session) on a Jira ticket in the prompt, code-task keywords (fix / implement / refactor…), or the first source-file edit in a git repo. Skips questions, doc/text edits, and files outside a git repo.

## Usage telemetry (on by default)

Bundled hooks can report each effort decision to LinearB's reported-metrics API as the custom metric **`agentic_advisor.effort_decision`** (`source: claude-code`), so adoption is visible in the platform (usage per developer / per repo / by effort level). **It's on by default** whenever `LINEARB_API_TOKEN` is set — the same token the skill needs for its reads. Turn it off with `export LINEARB_TELEMETRY=0`. It's fire-and-forget: failures never block or slow your turn.

**What it reports** — two kinds of event, distinguished by `tags.phase`:

| event | when | `value` | token tag |
| --- | --- | --- | --- |
| **decision** (`phase=decision`) | on `Stop`, right after the verdict — once per repo + effort level per session | `1` / `2` / `3` = LOW / MEDIUM / HIGH | `grading_tokens` — output tokens spent producing the verdict |
| **tokens** (`phase=tokens`) | on `SessionEnd`, best-effort | `0` (not a grade — exclude from grade aggregates) | `coding_tokens` — output tokens spent on the work after the verdict |

Count adoption and grades from **`phase=decision`** rows; use **`phase=tokens`** rows only for the coding-token measurement. (If you opt into the `LINEARB_BASELINE_HOLDOUT_PCT` experiment, held-out sessions also send a `value=0`, `label=baseline` event with `coding_tokens`; it's off by default.)

Fields on both events:

| field | value |
| --- | --- |
| `entity.contributor_email` | your `git config user.email`, or — if that's unset — the email of the Claude Code account you're signed in with (`~/.claude.json`); resolves to a contributor |
| `tags.identity_source` | where that email came from: `git`, `claude_account`, or `none` |
| `entity.repo_url` | your git remote → resolves to a repository |
| `tags.effort_level`, `tags.repo` | the verdict's level (`LOW`/`MEDIUM`/`HIGH`) and repo name |
| `tags.branch`, `tags.ticket` | current git branch (join key to the PR later opened from it) and a Jira-style key parsed from it |
| `tags.session_name`, `tags.model` | session title + model, for grouping |
| `tags.plugin_version` | the plugin version that produced the event |

Decision events also carry `tags.evidence` (the verdict's evidence snippet), `tags.grading_duration_s`, and `tags.actual_effort` (the session's reasoning-effort setting, when Claude Code exposes it).

All of this is sent **only to your own LinearB org** — the org your `LINEARB_API_TOKEN` belongs to — over HTTPS to your LinearB API (`public-api.linearb.io` unless you set `LINEARB_API_URL`); nothing goes anywhere else. It's the same data you can already see in your LinearB workspace, readable there by the metric name `agentic_advisor.effort_decision` (group by contributor / repo / effort level).

**Setup** — this plugin reads LinearB entirely through the **public API** (no MCP connector). Create an org-scoped API token (**LinearB → Settings → API Tokens → Create API Token**) and export it — the *same* token both reads health signals and reports telemetry:

```sh
export LINEARB_API_TOKEN="<your LinearB API token>"
# On-prem or regional LinearB? Point the plugin at your API (default https://public-api.linearb.io):
# export LINEARB_API_URL="https://<your-linearb-api-host>"
```

Then **launch Claude Code from a shell that has it exported** (hooks and the skill read the env at launch — a token added to an already-running session isn't seen until you restart; if you rely on `~/.zshrc`, start Claude from an interactive shell). The token is handed to `curl` on stdin, never as a command-line argument, and it is never printed or logged. **Without a token the skill degrades to MEDIUM effort** (it never blocks).

## Requirements

- **`LINEARB_API_TOKEN`** exported (see Setup) — used for both reading signals and reporting. Without it, the skill degrades to MEDIUM rather than failing.
- `jq`, `git`, and `curl` on PATH (used by the bundled hooks and the skill's API calls).
- No MCP connector required.

## Opting out

- **Telemetry:** `export LINEARB_TELEMETRY=0` (also accepts `false` / `off` / `no`) and relaunch Claude Code. The skill keeps working with your token; only reporting stops.
- **Everything:** disable the plugin (`/plugin`) to stop the auto-trigger. The hooks only inject a suggestion to run the skill and (optionally) report a metric — they never block your work.
