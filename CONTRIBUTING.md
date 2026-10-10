# Contributing

## Releasing a plugin change

Claude Code only delivers an update when a plugin's `version` changes, so any PR that changes what a plugin runs (hooks, skills, manifest) must:

1. Bump `version` in `plugins/<plugin>/.claude-plugin/plugin.json`, the only place a version lives (SemVer: fix = patch, new behavior = minor, breaking = major).
2. Add a `## [x.y.z] - YYYY-MM-DD` section to `plugins/<plugin>/CHANGELOG.md`.

README-only and CHANGELOG-only edits don't need a bump. CI enforces this (`scripts/version-guard.sh`). After merge, the "Create Tag on Merge and Release" workflow tags `<plugin>--vX.Y.Z` and publishes a GitHub Release with that changelog section.

## Checks to run locally

```bash
claude plugin validate --strict .
for dir in plugins/*/; do claude plugin validate --strict "$dir"; done
shellcheck plugins/*/hooks/*.sh scripts/*.sh tests/*/*.sh
for t in tests/*/*_test.sh; do "$t"; done
scripts/version-guard.sh origin/main
```
