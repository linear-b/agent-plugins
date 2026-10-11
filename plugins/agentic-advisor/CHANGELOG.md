# Changelog

## [1.1.2] - 2026-10-11

### Added

- Opt-in troubleshooting log: `LINEARB_DEBUG=1` writes each report's outcome (skip reason or HTTP status) to `${XDG_CACHE_HOME:-~/.cache}/agentic-advisor/report.log`, rotated at 1 MB. Lines for sent events include the grade and repo name; no line contains the token, email, prompt or payload. The log stays private (folder 0700, file 0600, symlinked logs refused). ([#9](https://github.com/linear-b/agent-plugins/pull/9))

### Changed

- With no `LINEARB_API_TOKEN`, the verdict now says `LINEARB_API_TOKEN not set` and tells the user how to set it, instead of a generic "signals unavailable" that looked like a working setup. ([#9](https://github.com/linear-b/agent-plugins/pull/9))

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
