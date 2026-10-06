---
description: Arm (or re-arm) the session-scoped Bitbucket PR watcher, or register a PR with it. Use when the user asks to watch a Bitbucket pull request, or if the auto-armed watcher was stopped and should be restarted.
---

# Session-scoped Bitbucket PR watcher

The watcher monitors only the PRs **this session registers** — not all of the user's open PRs. Events (new comments, approvals, CI/pipeline changes, merges/declines) arrive as notifications in this session. All Bitbucket access goes through the `twg` CLI (`twg bb ...`).

## Arming

1. If a Monitor running `watch-bb-pr-activity.sh` is already active in this session, don't arm another — just register PRs (below).
2. Check dependencies: `twg` (installed, authenticated against the user's Atlassian site) and `jq` on PATH. If missing, tell the user and stop.
3. Use the per-session watchlist path from the session-start hook context if present; otherwise create an empty file in your scratchpad.
4. Call the Monitor tool with:
   - `command`: `WATCH_LIST=<absolute watchlist path> bash "${CLAUDE_PLUGIN_ROOT}/scripts/watch-bb-pr-activity.sh"`
   - `description`: `PR activity on session-registered Bitbucket PRs`
   - `persistent`: `true`

## Registering PRs — be trigger-happy

Append a line (`workspace/repo#123` or the PR URL) to the watchlist whenever a specific pull request comes up:

- you open or update a PR
- the user links, mentions, or asks about one
- you review one, check its pipeline, or discuss it
- the current branch has an open PR

Example keys: `busie/fe-main#1443`, `https://bitbucket.org/busie/fe-main/pull-requests/1443`. The watcher re-reads the file every cycle: registration takes effect within one interval, duplicates are deduped, and merged/declined PRs are dropped automatically (a `WATCHING:` confirmation event fires once per new PR).

## Handling events

Triage agentically — surface and act on what matters, stay quiet on noise:

- **Always surface**: red CI (`CI: ... now failing`), merges and declines, human review comments (draft a reply where sensible), any comment addressed to Claude, and the user's own comments — people drive changes by reviewing their own PRs, so treat those as change requests, never skip them as self-noise. Before acting on a COMMENTS event, fetch the whole thread — event snippets are truncated and more may be in flight:
  `twg --output json --output-summary none bb prs comment query <id> -w <workspace> -r <repo> -n 50`
- **Say once**: `APPROVALS: ... — approved by X` (a reviewer signed off; one short line, then silence), and the first green run after a failing one.
- **Stay quiet on**: `Bitbucket Pipelines` / `app`-tagged automation posts (Claude review bots, CI link drops) unless they carry a finding nobody has dispositioned; re-runs and `pending`↔`passing` churn while the user is actively pushing; `no-build` when the repo simply has no pipeline on that commit.

## Tuning

Env vars: `WATCH_INTERVAL` (poll seconds, default 60), `WATCH_STATE_DIR` (pre-seeded state), `WATCH_MAX_CYCLES` and `WATCH_SINCE` (testing/backfill), `WATCH_TWG` (path to the binary), `WATCH_COMMENT_LIMIT` (comments fetched per PR per cycle). The comment stream is deliberately unfiltered — filtering is the consuming session's job.
