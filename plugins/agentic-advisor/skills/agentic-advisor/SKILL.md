---
name: agentic-advisor
description: Pull LinearB health signals for a repository before and during code generation so the agent sizes its effort to the repo's current health — staying lean and token-efficient on healthy repos, getting more careful and defensive on fragile ones. Use automatically at the start of repo-scoped code-writing tasks such as adding a feature, fixing a bug, refactoring, implementing behavior, modifying files, writing functions, adding endpoints/components, reviewing a diff, or otherwise preparing code changes. This is writing-phase guidance, not a merge or deploy gate. Reads LinearB's public API directly via curl with a LINEARB_API_TOKEN (no MCP connector needed); degrades to MEDIUM effort when the token is missing or the API is unavailable.
---

# LinearB Agentic Advisor

> Before writing code, it grades how fragile the target is — from LinearB health signals and local git history — and holds the agent to a matching effort level (LOW/MEDIUM/HIGH): lean when the repo and files are calm, rigorous when the evidence says they're not.

Run this at the start of a code task to load the repo's current health signals, then let them set how much effort to spend writing the code. This is writing-phase guidance only — it does not gate merges, pushes, PRs, or deploys.

## Access (read first)

All signals come from LinearB's **public API** over `curl` — no MCP connector needed. The base URL defaults to `https://public-api.linearb.io`; on-prem or regional deployments override it with `LINEARB_API_URL`. Authentication is a single org-scoped token in the `LINEARB_API_TOKEN` environment variable (created in the LinearB UI: **Settings → API Tokens → Create API Token**). Set up shared values once (`Content-Type` is required even on GET):

```bash
LB="${LINEARB_API_URL:-https://public-api.linearb.io}"; LB="${LB%/}"
AUTH=(-H "x-api-key: ${LINEARB_API_TOKEN}" -H "Content-Type: application/json")
```

**Token gate:** if `LINEARB_API_TOKEN` is empty, do **not** call — grade **MEDIUM** (signals unavailable), print the verdict, and continue. Never block the task. The same token authenticates both these reads and the optional reporter hook. On any timeout or non-2xx, treat that one signal as unavailable rather than failing the task.

## Before Gathering Signals (cheap exits)

Two checks that prevent wasted work — do them before any LinearB call:

- **Trivial edit → skip everything.** If the task changes **no code behavior** (comments, docs, formatting/whitespace, a pure rename), skip signal gathering entirely: effort is **LOW**, add no defensive guards (there's no logic to protect), and don't call LinearB at all — this holds **even on a fragile repo**. Anything that changes behavior is **not** trivial and warrants the sweep below — note that a **constant-value change counts as behavioral** (e.g. a timeout, retry count, or feature-flag default), as does any conditional or logic edit.
- **Already graded recently → reuse (persistent 24h cache).** The repo-level verdict is daily-stable, so compute it at most **once per repo per ~24h**, not once per task/session — this is the main token/time saver. Cache file, keyed by repo root:

  ```text
  # repo-hash = first 12 chars of the repo root's sha1 (shasum on macOS, sha1sum on Linux)
  root="$(git -C "<cwd>" rev-parse --show-toplevel)"; h="$(printf '%s' "$root" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)"
  f="${TMPDIR:-/tmp}/agentic-advisor/verdicts/$h.json"
  cat "$f" 2>/dev/null   # read BEFORE any LinearB call
  ```
  - **On a hit** (file exists AND `computed_at` is within the last 24h — or the file's mtime is <24h old): **skip ALL LinearB API calls** (repo list, measurements, incidents/search) and reuse `repo_effort`/`repo_evidence` **as the repo-health axis only**. You MUST still grade **task-complexity and change-area (files) fresh for the current task**, then combine — the cache replaces the phase-1 *data*, NOT the final verdict. Note it — **keep the standard `… <EFFORT> effort (…)` shape** (with the literal word `effort`) so the reporter still captures the decision: `LinearB: <repo> — <EFFORT> effort (repo-health cached <N>h ago; task + files fresh)`.
  - **On a miss/stale:** compute the repo-health verdict fresh, then **write the cache atomically** (temp file then `mv` — atomic on the same filesystem, so concurrent sessions can't read a half-written file):
    ```text
    mkdir -p "${TMPDIR:-/tmp}/agentic-advisor/verdicts"
    printf '%s' '{"repo":"<name>","repo_id":<id>,"repo_effort":"<LOW|MEDIUM|HIGH>","repo_evidence":"<real figures>","computed_at":"<ISO-8601 UTC>"}' > "$f.tmp" && mv -f "$f.tmp" "$f"
    ```
  - **Recompute (ignore cache) if:** it's older than 24h, you just merged/deployed to this repo, or a serious incident may have landed.
  - **⚠️ The cache stores ONLY the repo-health verdict (phase 1: rework / incidents / unreviewed merges) — daily-stable and task-independent. It does NOT store the final combined effort.** Both **change-area (file fix/revert + ownership)** and **task-complexity** are per-task and are **NEVER cached** — recompute them every task and combine `max(cached repo-health, fresh task-complexity, fresh change-area)`. So a **different task on the same repo within 24h** reuses only the cheap repo-health part and still re-grades the task-specific axes → correct effort for the new task. A cached-calm repo can still surface a HIGH task or file finding.
  - (Within a single session you may also just reuse the verdict from earlier in the conversation without re-reading the file — same 24h logic applies.)

## Repo Resolution

Infer the repo from the user's message, current working directory, or git remote. The public API has no server-side name filter, so fetch the repository list once and match **locally** — prefer the local git remote URL (exact) over the name:

```bash
raw="$(git -C "<cwd>" config --get remote.origin.url 2>/dev/null)"
case "$raw" in
  git@*:*)     url="https://$(printf '%s' "${raw#git@}" | sed 's#:#/#')" ;;
  ssh://git@*) url="https://${raw#ssh://git@}" ;;
  *)           url="$raw" ;;
esac
case "$url" in *.git) : ;; *) url="${url%/}.git" ;; esac

curl -sS -m 20 "${AUTH[@]}" "$LB/api/v1/repositories" \
  | jq -r --arg u "$url" --arg n "<repo-name>" '
      ( map(select((.http_url // "" | ascii_downcase) == ($u | ascii_downcase))) | .[0] )
      // ( map(select(.name == $n)) | .[0] )
      | if . == null then empty else {id, name, http_url} end'
```

Store `repo_id` (`.id`). **Empty output = not found** → fall back to org-level incidents only; don't block. (This list is not reliably paginated — `limit` works but `offset`/`page` may hang — so on a very large org a repo could be missing from the response; treat a miss as "resolution failed", not "healthy".)

## Signal Gathering

Run both reads (repo health + incidents) and feed the results into the **Effort Level** logic below.

**Repo health / rework (`POST /api/v2/measurements`).** Compute a 30-day window (portable across macOS/Linux); `time_ranges` is **required**:

```bash
before="$(date -u +%F)"; after="$(date -u -v-30d +%F 2>/dev/null || date -u -d '30 days ago' +%F)"
# `repository_ids` below is REQUIRED and already solves the pagination cap — it fetches THIS
# repo directly. Do NOT drop it, and do NOT "rediscover" the cap with limit/page_size/offset;
# that path is a known dead end (querystring `limit` is ignored). Just send this payload as-is.
curl -sS -m 25 "${AUTH[@]}" -X POST "$LB/api/v2/measurements" -d '{
  "group_by": "repository",
  "repository_ids": [<repo_id>],
  "requested_metrics": [
    {"name": "commit.activity.rework.rate"},
    {"name": "pr.merged.without.review.count"}
  ],
  "time_ranges": [{"after": "'"$after"'", "before": "'"$before"'"}]
}' | jq --argjson id <repo_id> '.[0].metrics[] | select(.repository_id == $id)'
```

- **Scope the request with the top-level `repository_ids: [<repo_id>]` — this is REQUIRED, not optional.** Without it the API returns only a **capped page (~25 repos)**; any repo outside that page comes back with **no matching row**, which the skill would misread as "signals unavailable → MEDIUM" and **silently under-grade a genuinely HIGH repo**. (The *nested* `filters.repository_ids` is the field that's ignored — use the **top-level** `repository_ids`. Keep the client-side `select(.repository_id == $id)` as a guard.) **If the filtered result is empty, the repo genuinely has no activity in the window** (dormant) — treat rework as absent and lean LOW on the repo axis; do **not** go hunting through pagination/`limit`, `repository_ids` is authoritative.
- `commit.activity.rework.rate` **is the rework percentage already** (server-side `rework.count / total_changes * 100`) — use it directly, do not divide again; if `null`, skip the rework signal.
- `pr.merged.without.review.count > 0` = unreviewed-merge risk signal.
- An **unknown metric name returns `0`, not an error** (a metric that's `0` across every repo means the name is wrong).

**Incidents — org-level (`POST /api/v1/incidents/search`).** Incidents are org-scoped and usually untagged to a repo (PM/Jira-derived ones carry no repository), so a repo-filtered search typically returns nothing — query org-level and judge relevance from titles:

```bash
curl -sS -m 25 "${AUTH[@]}" -X POST "$LB/api/v1/incidents/search" -d '{
  "limit": 50, "sort_by": "issued_at", "sort_dir": "desc"
}' | jq '.items[] | {title, issued_at, ended_at, status}'
```

`limit=50` returns them all for a typical org (including old-but-open ones, `ended_at: null`). This endpoint can be slow → **retry once** on timeout. Only pass `repository_urls` (a JSON array) with the exact stored `.git` URL — a mismatch can error rather than return empty.

## Effort Level

The signals pick **one effort level** — LOW / MEDIUM / HIGH — that the agent **must genuinely apply** to the work. It is not a mechanical/reasoning-budget setting on the model; it's a binding directive on how much care to put into the change — diff size, tests, guards, edge-case handling, and how carefully you reason before editing. Treat it as binding, not advisory: actually work at the level the skill assigns (lighter on LOW, more thorough on HIGH). This is the only scale; "risk" is just the evidence behind it. Apply judgment across the combined signals. Incidents are org-level; weight a recent serious org incident even if it can't be tied to the repo.

| Effort | Signals (repo health) |
| --- | --- |
| **LOW** | Healthy: no open incidents, rework under 6%, no unreviewed merges, no recent serious incidents |
| **MEDIUM** | Mild concern OR signals unavailable: rework 6-7%, a few unreviewed merges/bug PRs, 1-2 recent incidents — or LinearB data is missing/errored (default when we can't tell) |
| **HIGH** | Fragile: rework above 7%, recent serious incident, many unreviewed merges, 5+ bug PRs, or a known incident in this repo's area |

The rework bands match **LinearB's own benchmark** (ELITE <3% and STRONG 3-6% → LOW; FAIR 6-7% → MEDIUM; NEEDS FOCUS >7% → HIGH) — not arbitrary cutoffs. Effort = the **highest-firing signal**: e.g. rework 8% alone is HIGH even with no incidents, and one serious open incident is HIGH even if rework is tiny.

LOW effort is the reward for *confirmed* health — it requires positive evidence the repo is calm. When signals are missing or a tool errors, do **not** assume healthy: fall back to **MEDIUM** and continue (never block the task).

## Task Complexity (a third effort axis)

Repo health + file history tell you how **fragile the ground** is — not how **hard the task** is. A calm repo (LOW health signals) can still host a demanding change, and that change deserves care *regardless* of how healthy the repo is. Grading purely from repo signals **under-invests on big tasks in calm repos** — the agent goes light and the human ends up fixing the output.

So also grade the **task itself** — free, from the prompt + your plan, no tool calls:
- **Scope/size** — one-line tweak vs a multi-file feature; how much *new* logic.
- **Breadth** — one module vs many; **multiple repos/services** (cross-repo work is inherently higher: coordination + consistency across boundaries).
- **Logic difficulty** — algorithms, concurrency, shared state, data migrations, auth, money — error-prone by nature.
- **Ambiguity/constraints** — vague requirements, many edge cases, backward-compat / performance / security constraints.
- **Blast radius** — touching shared/foundational code many things depend on.

Same LOW/MEDIUM/HIGH scale: **LOW** = small, localized, well-specified, little logic; **MEDIUM** = a normal feature/fix (several files, real logic, a few edge cases); **HIGH** = large, cross-cutting, multi-repo, tricky, ambiguous, or high blast-radius.

**Combine all axes: `effort = max(repo-health, change-area, task-complexity)`** — any one being high raises the bar, and **name which axis drove it** (e.g. `MEDIUM effort (repo calm — rework 1%, no incidents — but the task spans 3 components with shared state)`). This keeps the token win — a *routine* change to a calm repo still grades LOW — while stopping the under-investment on demanding tasks in calm repos.

**Re-assess as the task unfolds:** if it turns out to touch more repos/files or more logic than first expected, **bump the effort mid-task and say so** — effort tracks the real task, not the first impression.

## Change-Area Signals (phase 2, file-grained)

Repo-level signals miss a **hot file in a calm repo** (one churny module in an otherwise-quiet repo). This phase sharpens the verdict using **local git history on the exact paths you're about to touch** — free (no network), fast, and at the file resolution LinearB can't give (the measurements API has no file filter).

Two-phase by design: the repo-health sweep above runs at task start; **this runs later, once you know which files the change will touch** (during planning, before editing).

**Gate (keep it lean — skip otherwise):** run this only when the edit is **non-trivial** AND either the repo already graded **MEDIUM/HIGH**, or the target paths hit the **sensitive surface** (auth, payments/billing, DB migrations, concurrency/locking, public API, security/crypto). A routine edit to a healthy repo skips phase 2 entirely.

**Probes — count-only, scoped to the paths you'll edit:**

```text
# rewritten-code churn (PRIMARY, message-independent): how much EXISTING code was
# reworked in these files over 90d. New work is mostly ADDED lines; rework rewrites/
# deletes existing lines, so DELETED lines are the fragility shape — a local proxy of
# LinearB's own rework metric, which the repo API can't give per-file.
git log --since=90.days --numstat --pretty=format: -- <paths> \
  | awk 'NF>=2 && $1!="-" {a+=$1; d+=$2} END{printf "added=%d deleted=%d\n", a, d}'
# commit count touching these files in 90d (churn CONTEXT, not fragility on its own)
git log --oneline --since=90.days -- <paths> | wc -l
# fix/revert-WORDED commits (WEAK corroborating hint only — greps commit MESSAGES, so it
# misses "update"/"wip"/"address comments" and over-matches substrings like prefix/suffix):
git log --oneline --since=90.days -i --grep=revert --grep=hotfix --grep=rollback --grep=fix -- <paths> | wc -l
# ownership + MY familiarity (mimics gitstream "code experts", scored locally) — run on the PRIMARY target file:
#   knowledge = who owns the lines (blame);  activity = who maintains it now (recent commits);
#   familiarity = is any of that ME? (my own git identity vs the owners/authors)
#   SKIP for a NEW / uncommitted file (not yet in HEAD): `git blame` errors and there's no
#   history to read — ownership is simply N/A for a file you're creating, so omit this signal.
git blame -w -M --line-porcelain HEAD -- <file> | grep '^author ' | sed 's/^author //' | sort | uniq -c | sort -rn | head   # top line-owners (by name)
git log --no-merges --since='52 weeks ago' --format='%an' -- <file> | sort | uniq -c | sort -rn | head                       # recent authors (52wk)
# my familiarity (me = my git email): my share of current lines, and my commits on it in 52wk
me="$(git config user.email)"
git blame -w -M --line-porcelain HEAD -- <file> | awk -v me="<$me>" '/^author-mail /{t++; if($2==me)m++} END{printf "mine=%d total=%d\n", m, t}'
git log --no-merges --since='52 weeks ago' --format='%ae' -- <file> | grep -Fxc "$me"   # my commits on it in 52wk
```

**Emit only the counts** into your reasoning — never read or paste the raw logs (wasteful and unnecessary; the integers are the signal).

**Read — rewritten-code churn is the fragility signal; raw churn is context; fix/revert wording is only a weak hint.**
- **Rewritten/deleted lines = primary signal.** A file where lots of **existing** code keeps being deleted/rewritten over 90d is being reworked = genuinely fragile → raise change-area effort. Judge by **absolute deleted lines** (with the commit count), **not ratio alone**: a high delete-ratio on tiny absolute churn (version bumps in `setup.py`/`package.json`, formatting) is noise, not rework. Pure growth (mostly **added** lines, few deletions) is healthy feature work, not fragility.
- **Raw commit count = context only, not auto-HIGH.** High churn means "active area — coordinate, expect in-flight changes"; it *amplifies* when paired with heavy rewritten-line churn or repo rework, but by itself does **not** force HIGH (busy ≠ fragile).
- **fix/revert-worded commits = weak corroboration only.** It greps commit **messages**, so it **misses** fragility when devs don't write "fix"/"revert" (they write "update", "wip", "address comments") and **over-counts** on substrings/PR-body text. Never raise effort on it alone — use it only to corroborate the rewritten-line signal. (Empirically: files heavily rewritten often show 0 fix/revert words, while a low-churn file can show several.)

**Read — ownership tells you whose code this is (amplifier), and whether it's *yours* (the code-experts raiser).** From the ownership probes, for the primary target file:
- **Familiarity (mine)** = my blame line-share (`mine/total` from the awk) + my 52wk commit count — am *I* an owner/maintainer of this file, or a stranger to it?
- **Concentration** = the top blame author's share of lines (one author owning most of it = few people understand it — bus-factor-ish).
- **Owner-maintenance coupling** = is that top line-owner *also* in the 52-week recent-activity list?
- **Diffusion** = count of distinct recent authors.

How to use it:
- **Familiarity → the one raiser here (unfamiliar only).** If my share is negligible (~0) **and** I have no 52wk commits on the file, I'm **editing someone else's code** → raise change-area effort **one notch** (LOW→MEDIUM, MEDIUM→HIGH — not an automatic jump to HIGH) and name the owner in the verdict: `not your code — primary owner A (~X% of lines)`. If ownership is instead **diffuse with no dominant owner** and it isn't mine either → same one-notch raise (no expert to lean on). **One-directional:** if it *is* mine (I own a share, or have recent commits), that **never lowers** the grade — it just doesn't raise.
- **Concentrated + top owner NOT in the recent-activity list** → the concentrated knowledge isn't being actively maintained *on this file*. Treat as a caution factor **only when paired with fragility** (fix/revert density or repo rework) — on its own it's ambiguous (could just be settled, stable code, exactly like high churn). When it does apply: lean additive, add tests, and ask before a broad refactor.
- **High diffusion** (many recent hands) → coordination surface → slight caution up.
- **⚠️ Wording is non-negotiable:** "not recently active *on this file*" is **NOT** "left the company." git (and gitstream) cannot see employment status, and there is no cheap local active-employee source — so **never state or imply that an owner departed**. Report only what git shows: e.g. `owner: A ~90% of lines, not active on this file in 52wk`. Do not name a person as "gone."

(Co-change coupling is still intentionally left out — add only if it proves its keep. This ownership signal mimics gitstream's "code experts" git extraction — `git blame --line-porcelain` for knowledge + `git log --since=52.weeks` for activity — but scores locally with a simple heuristic, and is recency-bounded + framed as above so a lone author who's simply moved on doesn't get mislabeled.)

**Combine:** `effort = max(repo-health effort, change-area effort)` — the conservative choice for a safety gate: the riskier axis wins so a genuinely fragile file can't be washed out by a calm repo. But `max` is **lossy** (LOW-repo+HIGH-file and HIGH-repo+HIGH-file both collapse to HIGH) and the two axes aren't on the same underlying scale, so **always surface which axis drove the verdict** — e.g. `HIGH effort (repo calm — rework 0.4% — but target file has 9 fix/revert commits in 90d)`.

**When the repo is already HIGH, still run and report phase 2.** It can't raise the level, but the file-level finding is *targeting context* — it tells you which specific files in a fragile repo are the fix/revert hotspots, so you concentrate the defensive guards and tests there instead of spreading effort evenly. The severity says "be careful"; the file data says "be careful *here*."

### Prefer running phase 2 *with* phase 1 (one verdict)

Phase 2 was only ever deferred because it needs the target file paths. So:

- **If the target file(s) are already known at task start** — named in the prompt, or unambiguous from cwd — run the phase-2 probe **together with the repo sweep** and fold both into **one combined verdict line** (no separate follow-up):
  ```text
  > LinearB: <repo> — <EFFORT> effort (rework X% <tier>; target <file>: ~N lines rewritten/90d) — <what you'll do>.
  ```
  This is the reliable path: it's part of the same up-front measurement, not a "remember later" step.
- **Only if the file cannot be known without exploring** (vague prompt) — emit the repo verdict first, explore to find the files, then before your first `Edit`/`Write` report phase 2. **Which line you print depends on whether phase 2 changes the effort** (recall `effort = max(repo-health, change-area, task)`, so a fix/revert hotspot can raise it above the repo level):
  - **If phase 2 CHANGES the combined effort** — re-emit the **full verdict line** with the new level, so it stands as the corrected decision (this is the line that gets recorded; without it, telemetry keeps the stale phase-1 level):
    ```text
    > LinearB: <repo> — <NEW EFFORT> effort (repo rework X% — but target <file>: ~N lines rewritten/90d) — <what you'll do>.
    ```
  - **If phase 2 does NOT change the level** — it's pure targeting context; print the short follow-up:
    ```text
    > LinearB phase 2 — <file>: ~N lines rewritten/90d — <concentrate guards + tests here | clean, standard care>.
    ```

**HARD RULE either way:** on a phase-2-gated task, the file-level finding must be printed **before the first `Edit`/`Write` to a target file** — combined into the phase-1 verdict when the file is known, or as the follow-up line when it isn't. Measure and report first, edit second. Skip only for trivial edits.

## Coding Posture

Use the effort level to guide the implementation silently. The aim is to **spend effort proportional to repo health** — go light (saving tokens and time) on calm repos, dig in on fragile ones. Don't waste effort.

LOW effort — repo confirmed healthy, go light and token-efficient (an active repo can still be LOW — busy ≠ risky):

- Implement the minimal change that satisfies the task; match existing repo conventions.
- Don't gold-plate: no speculative abstractions, defensive scaffolding, or drive-by refactors.
- Keep output concise — minimal narration, no exhaustive write-ups.
- Test new logic that could break; skip tests for trivial or obvious code. Correctness is still required.

MEDIUM effort — regular coding (also the default when signals are unavailable):

- Standard implementation: focused diff, match conventions.
- Add tests for new logic and branches as you normally would.
- Handle the obvious edge cases (null, empty, boundary) where relevant.
- Briefly note any material assumptions in the final summary.

HIGH effort — repo looks fragile, be careful:

- Make the smallest viable change.
- Add defensive guards, input validation, and error handling around new code paths.
- Test new logic and failure modes.
- Prefer additive changes over in-place edits to hot or churn-heavy code.
- Ask 1-2 clarifying questions before editing if the task is ambiguous.
- Note in the final summary that the repo has elevated churn or recent incidents and the change was kept minimal.

## Human-Facing Note

The moment the **repo sweep** returns — and **before any other tool call, and before spawning any Explore/subagent, reading, searching, `ls`/`find`, or editing code** — your next output MUST be this exact verdict line, **formatted as a markdown blockquote** (start it with `> ` so the terminal renders it with the left bar / emphasis and it stands out). Emit it as assistant text — do NOT wrap it in an `echo`/shell command or code fence (that hides it in a collapsed tool block). Do not paraphrase it into prose like "LOW effort signals confirmed". This is the **repo-level verdict**; it is fully knowable from the sweep alone, so nothing else may happen first. Format:

```text
> LinearB: <repo> — <LOW|MEDIUM|HIGH> effort (<evidence>) — <what you will do differently>
```

Rules:
- The line begins with `> ` (blockquote), then literally `LinearB: `, the real repo name, the CAPS effort level, and the word `effort`.
- `<evidence>` = the actual figures (rework %, unreviewed merges, incident note), not a summary.
- The `— <what you will do differently>` clause is required for MEDIUM/HIGH, optional for LOW.
- Emit it once, as the first line, before any exploration.
- **Fold phase 2 into this line when the target file is already known** (named in the prompt or obvious from cwd): run its probe alongside the sweep and include the file finding in this same verdict, e.g. `… HIGH effort (rework 9.5% NEEDS FOCUS; target PaymentForm.tsx: ~140 lines rewritten/90d over 6 commits) — …`. See "Prefer running phase 2 with phase 1" above. Only when the file can't be known without exploring do you emit this repo-level line first and add the phase-2 line after exploration (before the first edit). Never delay this repo-level verdict to wait on exploration.

Concrete examples (fill in the real repo name and actual figures):

```text
> LinearB: api-service — LOW effort (healthy: rework 0.4%, no incidents, 0 unreviewed merges).
> LinearB: payments-service — MEDIUM effort (rework 2.2%, prod OOM incident ~3wk ago, resolved) — keeping the change focused with edge-case tests.
> LinearB: data-pipeline — HIGH effort (rework 7.9%, NEEDS FOCUS tier) — smallest viable change, defensive guards + failure-mode tests.
> LinearB: <repo> — MEDIUM effort (signals unavailable) — defaulting to regular coding.
```

Keep this skill lightweight. Do not print a full report unless the user asks for one.

## Error Handling

- **No `LINEARB_API_TOKEN`** → grade MEDIUM (signals unavailable), print the verdict, continue. Never block.
- If the repositories list call times out or the repo isn't found → run org-level incidents only; don't block.
- `POST /api/v1/incidents/search` can be slow → **retry once** before marking incidents unknown.
- Only pass `repository_urls` with the exact `.git` URL — a mismatch can error rather than return empty.
- If measurements errors or returns nulls → skip the rework/quality signals and lean on incidents.
- A metric that is `0` across **every** repo in the response usually means a wrong metric name, not a healthy org — recheck the name.
- Never block, throw, or refuse the code task because LinearB signals are unavailable.
