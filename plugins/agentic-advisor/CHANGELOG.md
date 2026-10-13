# Changelog

## [1.4.0] - 2026-10-13

### Added

- Per-user off switch: `AGENTIC_ADVISOR_ENABLED=false` (or `0` / `off` / `no`) stops the skill from auto-running, so there's no nudge, no hold and nothing reported. Set it in your shell or in `~/.claude/settings.json` under `env`; it works even when the plugin is installed through managed settings. The skill still runs when asked for by name.

## [1.3.1] - 2026-10-13

### Fixed

- The grade now happens before work is handed to a subagent. The first subagent spawn in a repo is held once until the skill runs, like the first edit, and the agent is asked to pass the effort level on in the subagent's prompt. Before, a task that delegated its edits (common in scheduled tasks) was only graded at the main agent's first own edit, after the work was done. Read-only agents (Explore, Plan) are never held.
- Troubleshooting-log fixes from the 1.3.0 review that missed the release: curl's response and error files are now private (0600), emails are redacted before a server response is cut to length, the log no longer records the ticket key from the prompt, and the version prefix no longer needs jq.

## [1.3.0] - 2026-10-12

### Changed

- The troubleshooting log is now on by default, so a missing event can be diagnosed without asking the user to re-run anything. Turn it off with `LINEARB_DEBUG=0`. It stays local and private (0600), rotates at 1 MB, and never contains the token, prompt or payload.
- The log now covers the trigger hook too: when it nudged the agent to run the skill, and when it held a tool call for the grade or the verdict line.
- Every line starts with the plugin version.

### Added

- Errors are logged with their reason: network failures with curl's exit code and message, and rejected events (4xx/5xx) with the server's response, emails redacted.

## [1.2.0] - 2026-10-11

### Added

- Ticket context: when the prompt or branch names a ticket (e.g. `ABC-123`), the skill fetches its type, priority, estimate and labels from LinearB (one call, same token) and uses them to raise the task-complexity grade, e.g. a Highest-priority bug. Skipped silently when there's no key or no PM integration. ([#10](https://github.com/linear-b/agent-plugins/pull/10))

## [1.1.2] - 2026-10-11

### Added

- Opt-in troubleshooting log: `LINEARB_DEBUG=1` writes each report's outcome (skip reason or HTTP status) to `${XDG_CACHE_HOME:-~/.cache}/agentic-advisor/report.log`, rotated at 1 MB. Lines for sent events include the grade and repo name; no line contains the token, email, prompt or payload. The log stays private (folder 0700, file 0600, symlinked logs and rotation targets refused). ([#9](https://github.com/linear-b/agent-plugins/pull/9))

### Changed

- With no `LINEARB_API_TOKEN`, the verdict now says `LINEARB_API_TOKEN not set` and tells the user how to set it, instead of a generic "signals unavailable" that looked like a working setup. ([#9](https://github.com/linear-b/agent-plugins/pull/9))
- Hooks no longer fail under `set -u` when `HOME` and `XDG_CACHE_HOME` are both unset. ([#9](https://github.com/linear-b/agent-plugins/pull/9))

## [1.1.1] - 2026-10-08

### Fixed

- Send effort grades from interrupted turns at `SessionEnd` (tagged `backfill: session_end`). ([#4](https://github.com/linear-b/agent-plugins/pull/4))
- Retry a grade whose `Stop` fired before the repo was resolved. ([#4](https://github.com/linear-b/agent-plugins/pull/4))

## [1.1.0] - 2026-10-07

### Added

- Hold the next tool call once until the verdict line is printed, so grades kept in thinking are still recorded. ([#3](https://github.com/linear-b/agent-plugins/pull/3))
- Verdict line format documented in `SKILL.md`, with a `printf` fallback. ([#3](https://github.com/linear-b/agent-plugins/pull/3))

### Fixed

- Reporter reads the verdict from the `printf` call, not only from text. ([#3](https://github.com/linear-b/agent-plugins/pull/3))

## [1.0.0] - 2026-10-06

### Added

- `agentic-advisor` skill: grades LOW / MEDIUM / HIGH effort from LinearB signals and local git history. ([#1](https://github.com/linear-b/agent-plugins/pull/1))
- Trigger hook that runs the skill before the first code change in a repo. ([#1](https://github.com/linear-b/agent-plugins/pull/1))
- Opt-out usage telemetry to your own LinearB org (`LINEARB_TELEMETRY=0`). ([#1](https://github.com/linear-b/agent-plugins/pull/1))
