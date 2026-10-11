# Changelog

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
